import Foundation

/// Owns the on-disk representation of Chrono's state.
///
/// Saves are **debounced**: the engine ticks every second and writes a heartbeat, and there is
/// no reason to hit the disk that often. Calls coalesce into one write per `debounce` window,
/// with `flush()` available for the moments that must be durable immediately — quitting,
/// sleeping, and stopping a timer.
public final class StateStore: @unchecked Sendable {
    public static let stateFilename = "state.json"
    public static let settingsFilename = "settings.json"

    /// Segments older than this move out of `state.json` into monthly archives.
    public static let hotWindowDays = 45

    public let fileStore: FileStore
    private let queue = DispatchQueue(label: "in.chrono.statestore", qos: .utility)
    private let lock = NSLock()
    private let debounce: TimeInterval

    /// The most recent state handed to `save`, waiting to be written.
    private var pendingState: PersistedState?
    private var pendingSettings: Settings?
    private var writeScheduled = false

    public init(fileStore: FileStore, debounce: TimeInterval = 2.0) {
        self.fileStore = fileStore
        self.debounce = debounce
    }

    public static func standard() throws -> StateStore {
        let store = try FileStore.applicationSupport()
        try store.ensureDirectoryExists()
        return StateStore(fileStore: store)
    }

    // MARK: - Load

    /// `recovered` is true when the file had to be salvaged, so the UI can mention it once.
    public func loadState() -> (state: PersistedState, recovered: Bool) {
        let result = fileStore.loadMerging(defaults: PersistedState(), from: Self.stateFilename)
        return (sanitize(result.value), result.recovered)
    }

    public func loadSettings() -> (settings: Settings, recovered: Bool) {
        let result = fileStore.loadMerging(defaults: Settings(), from: Self.settingsFilename)
        return (result.value, result.recovered)
    }

    /// Repairs anything structurally impossible in a loaded state, so the rest of the app can
    /// assume its invariants hold.
    private func sanitize(_ input: PersistedState) -> PersistedState {
        var state = input

        // A running timer needs all three of target, start and segment id. If any is missing
        // the record is incoherent, so drop back to idle rather than guess.
        if state.runningSince != nil && (state.activeTarget == nil || state.openSegmentID == nil) {
            state.runningSince = nil
            state.openSegmentID = nil
        }
        if state.activeTarget == nil {
            state.runningSince = nil
            state.openSegmentID = nil
            state.pausedAt = nil
        }
        // Closed segments must actually be closed and non-negative.
        state.segments = state.segments
            .filter { $0.end != nil }
            .map { segment in
                guard let end = segment.end, end < segment.start else { return segment }
                return segment.closing(at: segment.start)
            }
            .sorted { $0.start < $1.start }
        state.recentIssues = Self.dedupe(state.recentIssues)
        state.pinnedIssues = Self.dedupe(state.pinnedIssues)
        return state
    }

    static func dedupe(_ issues: [IssueRef]) -> [IssueRef] {
        var seen = Set<String>()
        return issues.filter { seen.insert($0.key).inserted }
    }

    // MARK: - Save

    /// Queues a debounced write.
    public func save(_ state: PersistedState) {
        lock.lock()
        pendingState = state
        let alreadyScheduled = writeScheduled
        writeScheduled = true
        lock.unlock()

        guard !alreadyScheduled else { return }
        queue.asyncAfter(deadline: .now() + debounce) { [weak self] in
            self?.drain()
        }
    }

    public func saveSettings(_ settings: Settings) {
        lock.lock()
        pendingSettings = settings
        let alreadyScheduled = writeScheduled
        writeScheduled = true
        lock.unlock()

        guard !alreadyScheduled else { return }
        queue.asyncAfter(deadline: .now() + debounce) { [weak self] in
            self?.drain()
        }
    }

    /// Writes anything outstanding right now and waits for it. Called on quit, on sleep, and
    /// whenever losing the write would lose real work.
    public func flush() {
        queue.sync { self.drain() }
    }

    private func drain() {
        lock.lock()
        let state = pendingState
        let settings = pendingSettings
        pendingState = nil
        pendingSettings = nil
        writeScheduled = false
        lock.unlock()

        if let state {
            do {
                try fileStore.save(state, to: Self.stateFilename)
            } catch {
                ChronoLog.error("Could not write state: \(error.localizedDescription)")
            }
        }
        if let settings {
            do {
                try fileStore.save(settings, to: Self.settingsFilename)
            } catch {
                ChronoLog.error("Could not write settings: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Archiving

    /// Moves segments older than the hot window into per-month archive files.
    ///
    /// Returns the trimmed state. Archive writes are additive and merge with whatever is
    /// already on disk for that month, so running this twice is harmless.
    public func retireOldSegments(
        in state: PersistedState,
        asOf now: Date,
        calendar: Calendar = .current
    ) -> PersistedState {
        let cutoff = calendar.date(byAdding: .day, value: -Self.hotWindowDays, to: now)
            ?? now.addingTimeInterval(-Double(Self.hotWindowDays) * 86_400)

        let (cold, hot) = state.segments.reduce(into: ([WorkSegment](), [WorkSegment]())) { acc, segment in
            if let end = segment.end, end < cutoff { acc.0.append(segment) } else { acc.1.append(segment) }
        }
        guard !cold.isEmpty else { return state }

        let grouped = Dictionary(grouping: cold) { SegmentArchive.monthKey(for: $0.start, calendar: calendar) }
        for (month, segments) in grouped {
            appendToArchive(month: month, segments: segments)
        }

        var trimmed = state
        trimmed.segments = hot
        return trimmed
    }

    private func appendToArchive(month: String, segments: [WorkSegment]) {
        let name = SegmentArchive.filename(month: month)
        let existing = fileStore.loadOptional(SegmentArchive.self, from: name)
            ?? SegmentArchive(month: month, segments: [])

        // De-duplicate by id, so a repeated retire pass cannot double-count history.
        var byID = Dictionary(existing.segments.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for segment in segments { byID[segment.id] = segment }

        let merged = SegmentArchive(
            month: month,
            segments: byID.values.sorted { $0.start < $1.start }
        )
        do {
            try fileStore.save(merged, to: name)
        } catch {
            ChronoLog.error("Could not write archive \(name): \(error.localizedDescription)")
        }
    }

    public func loadArchive(month: String) -> [WorkSegment] {
        fileStore.loadOptional(SegmentArchive.self, from: SegmentArchive.filename(month: month))?.segments ?? []
    }

    public func availableArchiveMonths() -> [String] {
        fileStore.listFiles(withPrefix: SegmentArchive.filenamePrefix)
            .compactMap { name in
                name.replacingOccurrences(of: SegmentArchive.filenamePrefix, with: "")
                    .replacingOccurrences(of: ".json", with: "")
            }
            .sorted(by: >)
    }

    /// Loads whatever history is needed to cover a date range, pulling in archives as required.
    public func segments(covering range: DateInterval, hotSegments: [WorkSegment], calendar: Calendar = .current) -> [WorkSegment] {
        var months = Set<String>()
        var cursor = calendar.startOfDay(for: range.start)
        while cursor <= range.end {
            months.insert(SegmentArchive.monthKey(for: cursor, calendar: calendar))
            guard let next = calendar.date(byAdding: .month, value: 1, to: cursor) else { break }
            cursor = next
        }

        let archived = months.flatMap { loadArchive(month: $0) }
        var byID = Dictionary(archived.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for segment in hotSegments { byID[segment.id] = segment }

        return byID.values
            .filter { segment in
                let end = segment.end ?? range.end
                return end >= range.start && segment.start <= range.end
            }
            .sorted { $0.start < $1.start }
    }
}
