import Foundation
import Observation

/// The state machine every other part of the app drives.
///
/// Three states, and the shape of `PersistedState` makes them unambiguous:
///
/// | state   | `activeTarget` | `runningSince` |
/// |---------|----------------|----------------|
/// | idle    | `nil`          | `nil`          |
/// | running | set            | set            |
/// | paused  | set            | `nil`          |
///
/// The engine performs no I/O of its own beyond handing state to `StateStore`, owns no timers,
/// and reads the current time only through its `Clock`. Everything time-dependent is therefore
/// reproducible in a test, which matters because the interesting bugs in a time tracker are all
/// about clocks going backwards, laptops sleeping and days rolling over.
@MainActor
@Observable
public final class TrackingEngine {

    // MARK: - Observable state

    public private(set) var state: PersistedState
    public private(set) var settings: Settings
    /// Refreshed by `tick()`. Views read this so they re-render once a second while running,
    /// rather than each view scheduling its own timer.
    public private(set) var now: Date
    /// Set when the app was killed with a timer running and the user has not yet decided
    /// what to do about it.
    public private(set) var pendingRecovery: RecoveryProposal?
    /// Surfaced in the panel when the state file had to be salvaged.
    public private(set) var didRecoverCorruptState = false

    // MARK: - Collaborators

    private let store: StateStore
    private let clock: any Clock

    /// Fired for anything the rest of the app may want to react to (notifications, the phone
    /// remote, sounds). Deliberately a single sink rather than a delegate protocol, so adding
    /// an event does not break conformances.
    public var eventHandler: ((EngineEvent) -> Void)?

    // MARK: - Init

    public init(store: StateStore, clock: any Clock = SystemClock()) {
        self.store = store
        self.clock = clock
        self.now = clock.now

        let loadedSettings = store.loadSettings()
        let loadedState = store.loadState()
        self.settings = loadedSettings.settings
        self.state = loadedState.state
        self.didRecoverCorruptState = loadedState.recovered || loadedSettings.recovered

        // Retire old history out of the hot file before anything else touches it.
        self.state = store.retireOldSegments(in: self.state, asOf: clock.now)

        detectInterruptedSession()
        persist()
    }

    // MARK: - Derived state

    public var status: TrackingStatus {
        guard let target = state.activeTarget else { return .idle }
        if let since = state.runningSince { return .running(target: target, since: since) }
        return .paused(target: target, pausedAt: state.pausedAt)
    }

    public var activeTarget: TrackingTarget? { state.activeTarget }
    public var isRunning: Bool { state.isRunning }
    public var isPaused: Bool { state.isPaused }

    /// Time on the currently open segment. Zero when paused or idle.
    public var currentSegmentElapsed: TimeInterval {
        guard let since = state.runningSince else { return 0 }
        return max(0, now.timeIntervalSince(since))
    }

    /// Total time on the active target today, including the open segment. This is the number
    /// the menu bar shows: "how long have I been on this today", not "since I last resumed",
    /// because the latter resets every time you glance at Slack.
    public var activeTargetTodayElapsed: TimeInterval {
        guard let target = state.activeTarget else { return 0 }
        return todayRollup.totals.first { $0.target.id == target.id }?.seconds ?? 0
    }

    public var todayRollup: DayRollup {
        DayRollup.build(segments: state.allSegments(), day: now, calendar: .current, asOf: now)
    }

    public func rollup(for day: Date) -> DayRollup {
        DayRollup.build(segments: state.allSegments(), day: day, calendar: .current, asOf: now)
    }

    /// Segments already claimed by a draft, in any state. Deleting a draft releases them.
    public var coveredSegmentIDs: Set<UUID> {
        Set(state.drafts.flatMap(\.segmentIDs))
    }

    /// Closed, loggable segments not yet claimed by a draft — the "unsubmitted" pile.
    public var unsettledSeconds: TimeInterval {
        let covered = coveredSegmentIDs
        return state.segments
            .filter { $0.target.isLoggable && !covered.contains($0.id) }
            .reduce(0) { $0 + $1.closedDuration }
    }

    /// Time tracked today that has no Jira issue behind it yet.
    public var unfiledSecondsToday: TimeInterval { todayRollup.unloggableSeconds }

    /// Where state is written. Surfaced so the UI can show the user their own data.
    public var storageDirectory: URL? { store.fileStore.directory }

    // MARK: - Clock

    /// Advances the engine's notion of "now". Called once a second by the app while anything
    /// is running, and on demand when a panel opens.
    public func tick() {
        now = clock.now
        guard state.isRunning else { return }

        // Heartbeat is what makes crash recovery honest; see `detectInterruptedSession`.
        let shouldWrite = state.lastHeartbeat.map { now.timeIntervalSince($0) >= 5 } ?? true
        if shouldWrite {
            state.lastHeartbeat = now
            persist()
        }
    }

    // MARK: - Commands

    /// Starts (or resumes, or switches to) tracking `target`.
    @discardableResult
    public func start(
        _ target: TrackingTarget,
        source: SegmentSource = .manual,
        note: String? = nil
    ) -> TrackingStatus {
        let timestamp = clock.now
        now = timestamp

        if let active = state.activeTarget {
            if active.id == target.id {
                // Same target: either already running (nothing to do) or paused (resume).
                if state.isRunning { return status }
                resume(source: source)
                return status
            }
            let previous = active
            closeOpenSegment(at: timestamp)
            openSegment(target: target, at: timestamp, source: source, note: note)
            emit(.switched(from: previous, to: target))
            noteRecentUse(of: target, at: timestamp)
            persist()
            return status
        }

        openSegment(target: target, at: timestamp, source: source, note: note)
        emit(.started(target))
        noteRecentUse(of: target, at: timestamp)
        persist()
        return status
    }

    /// Pauses without giving up the selection, so resuming is one click.
    @discardableResult
    public func pause(reason: PauseReason = .user) -> TrackingStatus {
        let timestamp = clock.now
        now = timestamp
        guard state.isRunning, let target = state.activeTarget else { return status }

        closeOpenSegment(at: timestamp)
        state.pausedAt = timestamp
        emit(.paused(target, reason))
        persist(flush: reason.isUrgent)
        return status
    }

    @discardableResult
    public func resume(source: SegmentSource = .manual) -> TrackingStatus {
        let timestamp = clock.now
        now = timestamp
        guard let target = state.activeTarget, !state.isRunning else { return status }

        openSegment(
            target: target,
            at: timestamp,
            source: source,
            note: state.openSegmentNote
        )
        state.pausedAt = nil
        emit(.resumed(target))
        persist()
        return status
    }

    /// Stops tracking and settles everything unsubmitted into drafts.
    ///
    /// Settling *all* uncovered segments rather than only the stopped target's is deliberate:
    /// after an afternoon of A → B → A, one stop should leave nothing stranded.
    @discardableResult
    public func stop() -> [WorklogDraft] {
        let timestamp = clock.now
        now = timestamp
        let target = state.activeTarget
        let elapsed = currentSegmentElapsed

        if state.isRunning { closeOpenSegment(at: timestamp) }
        state.activeTarget = nil
        state.runningSince = nil
        state.openSegmentID = nil
        state.openSegmentNote = nil
        state.pausedAt = nil

        let drafts = settle(at: timestamp)
        if let target { emit(.stopped(target, seconds: elapsed)) }
        persist(flush: true)
        return drafts
    }

    /// Throws away the open segment entirely — the "I started the wrong timer" escape hatch.
    public func discardOpenSegment() {
        let timestamp = clock.now
        now = timestamp
        guard state.isRunning, let target = state.activeTarget else { return }

        state.runningSince = nil
        state.openSegmentID = nil
        state.pausedAt = timestamp
        emit(.discarded(target))
        persist()
    }

    /// Attaches a note to the running segment, which becomes the Jira worklog comment.
    public func setNote(_ text: String?) {
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        state.openSegmentNote = (trimmed?.isEmpty ?? true) ? nil : trimmed
        persist()
    }

    /// Backdates the start of the running segment — "I actually began ten minutes ago".
    ///
    /// Refuses to move the start before the end of the previous segment, which would create
    /// overlapping time.
    @discardableResult
    public func backdateStart(by seconds: TimeInterval) -> Bool {
        guard seconds > 0, let since = state.runningSince else { return false }
        let proposed = since.addingTimeInterval(-seconds)
        let previousEnd = state.segments.compactMap(\.end).max()
        if let previousEnd, proposed < previousEnd { return false }
        state.runningSince = proposed
        persist()
        return true
    }

    // MARK: - Idle resolution

    /// Applies the user's answer to "you were away for a while".
    ///
    /// `idleSeconds` is trimmed off the *end* of the open segment, because that is where the
    /// idle time actually sits.
    public func resolveIdle(_ resolution: IdleResolution, idleSeconds: TimeInterval) {
        let timestamp = clock.now
        now = timestamp
        guard let target = state.activeTarget else { return }

        switch resolution {
        case .keep:
            emit(.idleResolved(resolution, seconds: idleSeconds))

        case .discard, .discardAndPause, .discardAndStop:
            let idleStart = max(state.runningSince ?? timestamp, timestamp.addingTimeInterval(-idleSeconds))

            if state.isRunning {
                // Close the segment where the user actually stopped working…
                closeOpenSegment(at: idleStart, trimmedIdle: timestamp.timeIntervalSince(idleStart))
            }

            switch resolution {
            case .discard:
                // …and start a fresh one now, so the timer keeps running.
                openSegment(target: target, at: timestamp, source: .automatic, note: state.openSegmentNote)
            case .discardAndPause:
                state.pausedAt = idleStart
                emit(.paused(target, .idle))
            case .discardAndStop:
                state.activeTarget = nil
                state.pausedAt = nil
                _ = settle(at: timestamp)
                emit(.stopped(target, seconds: 0))
            case .keep:
                break
            }
            emit(.idleResolved(resolution, seconds: idleSeconds))
        }
        persist(flush: true)
    }

    // MARK: - Drafts

    /// Builds drafts for everything closed, loggable and unclaimed.
    @discardableResult
    public func settle(at timestamp: Date? = nil) -> [WorklogDraft] {
        let reference = timestamp ?? clock.now
        let drafts = WorklogBuilder.buildDrafts(
            from: state.segments,
            settings: settings,
            coveredSegmentIDs: coveredSegmentIDs,
            calendar: .current,
            now: reference
        )
        guard !drafts.isEmpty else { return [] }
        state.drafts.append(contentsOf: drafts)
        emit(.draftsEnqueued(drafts))
        persist(flush: true)
        return drafts
    }

    /// Replaces a draft, e.g. after the user edits its duration or comment in the timesheet.
    public func replaceDraft(_ draft: WorklogDraft) {
        guard let index = state.drafts.firstIndex(where: { $0.id == draft.id }) else { return }
        state.drafts[index] = draft
        persist()
    }

    /// Deletes a draft and releases its segments, so they can be drafted again.
    public func releaseDraft(id: UUID) {
        state.drafts.removeAll { $0.id == id }
        persist()
    }

    /// Marks a draft as deliberately not logged. Its segments stay claimed so it does not
    /// come back.
    public func discardDraft(id: UUID) {
        guard let index = state.drafts.firstIndex(where: { $0.id == id }) else { return }
        state.drafts[index] = state.drafts[index].marking(.discarded, at: clock.now)
        persist()
    }

    /// Applies whatever the sync queue managed to do. Kept as a bulk replace so the queue can
    /// work on a snapshot off the main actor and hand results back in one hop.
    public func applyDraftUpdates(_ updated: [WorklogDraft]) {
        var byID = Dictionary(uniqueKeysWithValues: state.drafts.map { ($0.id, $0) })
        for draft in updated { byID[draft.id] = draft }
        state.drafts = state.drafts.compactMap { byID[$0.id] }
        persist()
    }

    /// Forgets long-settled drafts so `state.json` does not grow without bound.
    public func pruneDrafts(olderThan days: Int = 30) {
        let cutoff = clock.now.addingTimeInterval(-Double(days) * 86_400)
        state.drafts.removeAll { draft in
            draft.isTerminal && (draft.submittedAt ?? draft.createdAt) < cutoff
        }
        persist()
    }

    // MARK: - Reconciling unfiled time

    /// Retargets every segment of an ad-hoc bucket onto a real Jira issue.
    ///
    /// This is how the "random work" problem gets solved without demanding that the user pick
    /// a ticket in the moment: capture it as ad-hoc now, attach it to an issue later, and the
    /// timestamps are still exactly right.
    @discardableResult
    public func assign(adhocID: UUID, to issue: IssueRef, limitedTo day: Date? = nil) -> Int {
        let calendar = Calendar.current
        var changed = 0

        state.segments = state.segments.map { segment in
            guard segment.target.adhoc?.id == adhocID else { return segment }
            if let day, !calendar.isDate(segment.start, inSameDayAs: day) { return segment }
            var copy = segment
            copy.target = .issue(issue)
            changed += 1
            return copy
        }

        // If the running timer is on that bucket, retarget it too.
        if state.activeTarget?.adhoc?.id == adhocID, day == nil {
            state.activeTarget = .issue(issue)
            changed += 1
        }

        if changed > 0 {
            noteRecentUse(of: .issue(issue), at: clock.now)
            emit(.adhocReassigned(count: changed, issue: issue))
            persist(flush: true)
        }
        return changed
    }

    /// Retargets a single segment — used by the timesheet's per-row "assign to issue" action.
    public func retarget(segmentID: UUID, to target: TrackingTarget) {
        guard let index = state.segments.firstIndex(where: { $0.id == segmentID }) else { return }
        // A segment already inside a draft must not be silently moved; release the draft first.
        if let draft = state.drafts.first(where: { $0.segmentIDs.contains(segmentID) && !$0.isTerminal }) {
            releaseDraft(id: draft.id)
        }
        state.segments[index].target = target
        persist()
    }

    /// Hand-entered time, for the meeting you forgot to track at all.
    @discardableResult
    public func backfill(
        target: TrackingTarget,
        start: Date,
        end: Date,
        note: String? = nil
    ) -> WorkSegment? {
        guard end > start else { return nil }
        let segment = WorkSegment(
            target: target,
            start: start,
            end: end,
            note: note,
            source: .backfilled
        )
        state.segments.append(segment)
        state.segments.sort { $0.start < $1.start }
        noteRecentUse(of: target, at: clock.now)
        emit(.backfilled(segment))
        persist(flush: true)
        return segment
    }

    public func deleteSegment(id: UUID) {
        if let draft = state.drafts.first(where: { $0.segmentIDs.contains(id) && !$0.isTerminal }) {
            releaseDraft(id: draft.id)
        }
        state.segments.removeAll { $0.id == id }
        persist()
    }

    public func updateSegment(id: UUID, start: Date? = nil, end: Date? = nil, note: String? = nil) {
        guard let index = state.segments.firstIndex(where: { $0.id == id }) else { return }
        var segment = state.segments[index]
        if let start { segment.start = start }
        if let end { segment.end = max(end, segment.start) }
        if let note { segment = segment.withNote(note) }
        state.segments[index] = segment
        state.segments.sort { $0.start < $1.start }
        persist()
    }

    // MARK: - Crash recovery

    /// Called at launch: if the persisted state says a timer was running, the app did not exit
    /// cleanly. Rather than guess, build a proposal for the user.
    private func detectInterruptedSession() {
        guard state.isRunning, let target = state.activeTarget, let since = state.runningSince else { return }

        let heartbeat = state.lastHeartbeat ?? since
        let gap = clock.now.timeIntervalSince(heartbeat)

        // A gap this small means the app was relaunched immediately (a crash-and-restart, or a
        // debug build being re-run) and the timer can simply keep going.
        guard gap > 90 else { return }

        pendingRecovery = RecoveryProposal(
            target: target,
            start: since,
            lastKnownActive: heartbeat,
            discoveredAt: clock.now
        )
        // Stop the clock in the meantime so no time accrues while the user decides.
        state.runningSince = nil
        state.pausedAt = heartbeat
        emit(.recoveryNeeded(pendingRecovery!))
    }

    public func resolveRecovery(_ decision: RecoveryDecision) {
        guard let proposal = pendingRecovery else { return }
        let timestamp = clock.now
        pendingRecovery = nil

        switch decision {
        case .keepUntilLastActivity:
            state.segments.append(
                WorkSegment(
                    id: state.openSegmentID ?? UUID(),
                    target: proposal.target,
                    start: proposal.start,
                    end: proposal.lastKnownActive,
                    note: state.openSegmentNote,
                    source: .recovered
                )
            )
            finishRecovery(clearingTarget: true, at: timestamp)

        case .keepAndContinue:
            state.segments.append(
                WorkSegment(
                    id: state.openSegmentID ?? UUID(),
                    target: proposal.target,
                    start: proposal.start,
                    end: proposal.lastKnownActive,
                    source: .recovered
                )
            )
            state.openSegmentID = nil
            openSegment(target: proposal.target, at: timestamp, source: .recovered, note: state.openSegmentNote)
            state.pausedAt = nil
            persist(flush: true)

        case .discard:
            finishRecovery(clearingTarget: true, at: timestamp)
        }
    }

    private func finishRecovery(clearingTarget: Bool, at timestamp: Date) {
        state.openSegmentID = nil
        state.runningSince = nil
        if clearingTarget {
            state.activeTarget = nil
            state.pausedAt = nil
        }
        _ = settle(at: timestamp)
        persist(flush: true)
    }

    // MARK: - Settings

    public func update(settings newValue: Settings) {
        settings = newValue
        store.saveSettings(newValue)
    }

    public func mutateSettings(_ transform: (inout Settings) -> Void) {
        var copy = settings
        transform(&copy)
        update(settings: copy)
    }

    // MARK: - Recents & pins

    public func pin(_ issue: IssueRef) {
        guard !state.pinnedIssues.contains(where: { $0.key == issue.key }) else { return }
        state.pinnedIssues.insert(issue, at: 0)
        persist()
    }

    public func unpin(issueKey: String) {
        state.pinnedIssues.removeAll { $0.key == issueKey }
        persist()
    }

    public func rememberAdhoc(_ ref: AdhocRef) {
        guard !state.savedAdhocTargets.contains(where: { $0.id == ref.id }) else { return }
        state.savedAdhocTargets.insert(ref, at: 0)
        state.savedAdhocTargets = Array(state.savedAdhocTargets.prefix(12))
        persist()
    }

    /// Keeps a most-recently-used list of issues, capped so the panel stays scannable.
    private func noteRecentUse(of target: TrackingTarget, at timestamp: Date) {
        switch target {
        case .issue(var ref):
            ref.fetchedAt = ref.fetchedAt ?? timestamp
            state.recentIssues.removeAll { $0.key == ref.key }
            state.recentIssues.insert(ref, at: 0)
            state.recentIssues = Array(state.recentIssues.prefix(25))
        case .adhoc(let ref):
            rememberAdhoc(ref)
        }
    }

    /// Refreshes cached issue metadata after a Jira fetch, without disturbing ordering.
    public func refreshCachedIssue(_ issue: IssueRef) {
        if let index = state.recentIssues.firstIndex(where: { $0.key == issue.key }) {
            state.recentIssues[index] = issue
        }
        if let index = state.pinnedIssues.firstIndex(where: { $0.key == issue.key }) {
            state.pinnedIssues[index] = issue
        }
        if case .issue(let current) = state.activeTarget, current.key == issue.key {
            state.activeTarget = .issue(issue)
        }
        persist()
    }

    /// Binds the history to a Jira account, and reports whether it already belonged to a
    /// different one (which would mean two people's time in one file).
    @discardableResult
    public func bind(accountID: String) -> Bool {
        let previous = state.jiraAccountID
        state.jiraAccountID = accountID
        persist()
        return previous == nil || previous == accountID
    }

    // MARK: - Segment plumbing

    private func openSegment(target: TrackingTarget, at timestamp: Date, source: SegmentSource, note: String?) {
        state.activeTarget = target
        state.runningSince = timestamp
        state.openSegmentID = UUID()
        state.openSegmentSource = source
        state.openSegmentNote = note
        state.pausedAt = nil
        state.lastHeartbeat = timestamp
    }

    private func closeOpenSegment(at timestamp: Date, trimmedIdle: TimeInterval = 0) {
        guard let target = state.activeTarget,
              let since = state.runningSince,
              let id = state.openSegmentID
        else { return }

        // Clamp: a clock correction or a sleep/wake could otherwise produce a negative span.
        let end = max(timestamp, since)
        let segment = WorkSegment(
            id: id,
            target: target,
            start: since,
            end: end,
            note: state.openSegmentNote,
            source: state.openSegmentSource,
            trimmedIdle: trimmedIdle
        )

        // A segment shorter than a second is noise from a double-click; drop it.
        if segment.closedDuration >= 1 {
            state.segments.append(segment)
            state.segments.sort { $0.start < $1.start }
            emit(.segmentClosed(segment))
        }

        state.runningSince = nil
        state.openSegmentID = nil
    }

    private func persist(flush: Bool = false) {
        store.save(state)
        if flush { store.flush() }
    }

    /// Writes everything to disk synchronously. Called on quit and before sleep.
    public func flush() {
        state.lastHeartbeat = clock.now
        store.save(state)
        store.saveSettings(settings)
        store.flush()
    }

    private func emit(_ event: EngineEvent) {
        eventHandler?(event)
    }
}

// MARK: - Supporting types

public enum TrackingStatus: Equatable, Sendable {
    case idle
    case running(target: TrackingTarget, since: Date)
    case paused(target: TrackingTarget, pausedAt: Date?)

    public var target: TrackingTarget? {
        switch self {
        case .idle: return nil
        case .running(let target, _), .paused(let target, _): return target
        }
    }

    public var isRunning: Bool { if case .running = self { return true }; return false }
    public var isPaused: Bool { if case .paused = self { return true }; return false }
    public var isIdle: Bool { if case .idle = self { return true }; return false }
}

public enum PauseReason: String, Sendable {
    case user
    case idle
    case screenLock
    case systemSleep
    case meeting
    case remote
    case shutdown

    /// Reasons where the write must hit the disk immediately, because the machine may be
    /// about to stop executing our code.
    public var isUrgent: Bool {
        self == .systemSleep || self == .shutdown || self == .screenLock
    }

    public var humanReason: String {
        switch self {
        case .user: return "paused"
        case .idle: return "paused because you went idle"
        case .screenLock: return "paused when the screen locked"
        case .systemSleep: return "paused when the Mac slept"
        case .meeting: return "paused for a meeting"
        case .remote: return "paused from your phone"
        case .shutdown: return "paused at shutdown"
        }
    }
}

public enum IdleResolution: String, Sendable, CaseIterable {
    case keep
    case discard
    case discardAndPause
    case discardAndStop
}

/// What the app found at launch after an unclean exit.
public struct RecoveryProposal: Sendable, Equatable {
    public let target: TrackingTarget
    public let start: Date
    /// The last heartbeat, i.e. the last moment we know the timer was legitimately running.
    public let lastKnownActive: Date
    public let discoveredAt: Date

    /// Time we are confident about.
    public var confidentSeconds: TimeInterval { max(0, lastKnownActive.timeIntervalSince(start)) }
    /// Time between the last heartbeat and now — the part we refuse to guess about.
    public var unknownSeconds: TimeInterval { max(0, discoveredAt.timeIntervalSince(lastKnownActive)) }
}

public enum RecoveryDecision: Sendable {
    /// Log up to the last heartbeat and stop.
    case keepUntilLastActivity
    /// Log up to the last heartbeat and start a fresh segment now.
    case keepAndContinue
    /// Throw the whole interrupted session away.
    case discard
}

public enum EngineEvent: Sendable {
    case started(TrackingTarget)
    case paused(TrackingTarget, PauseReason)
    case resumed(TrackingTarget)
    case stopped(TrackingTarget, seconds: TimeInterval)
    case switched(from: TrackingTarget, to: TrackingTarget)
    case discarded(TrackingTarget)
    case segmentClosed(WorkSegment)
    case draftsEnqueued([WorklogDraft])
    case idleResolved(IdleResolution, seconds: TimeInterval)
    case recoveryNeeded(RecoveryProposal)
    case adhocReassigned(count: Int, issue: IssueRef)
    case backfilled(WorkSegment)
}
