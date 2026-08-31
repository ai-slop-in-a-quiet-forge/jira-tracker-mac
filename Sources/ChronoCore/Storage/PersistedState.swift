import Foundation

/// Everything Chrono needs to restore itself after a quit, a crash or a reboot.
public struct PersistedState: Codable, Sendable, Equatable {
    /// Bumped only for changes that `FileStore.loadMerging` cannot absorb on its own.
    public var schemaVersion: Int = 1

    // MARK: - Live timer

    /// The selected task. Survives a pause — pausing does not deselect.
    public var activeTarget: TrackingTarget?
    /// Non-nil means the timer is actively counting. This is the whole state machine:
    /// `activeTarget == nil` is idle, `runningSince == nil` with a target is paused.
    public var runningSince: Date?
    /// Identity of the open segment, so a resumed run reuses it rather than fragmenting.
    public var openSegmentID: UUID?
    public var openSegmentSource: SegmentSource = .manual
    public var openSegmentNote: String?
    /// When the timer was paused, for the "you've been paused for 40 minutes" reminder.
    public var pausedAt: Date?

    /// Written every few seconds while the timer runs.
    ///
    /// This is what makes crash recovery honest: if the app is killed at 17:05 and reopened
    /// at 09:00 the next morning, we know the timer was legitimately running only up to the
    /// last heartbeat, so we offer to log until then instead of silently billing 16 hours.
    public var lastHeartbeat: Date?

    // MARK: - History

    /// Closed segments for the recent window. Older ones live in monthly archive files.
    public var segments: [WorkSegment] = []
    public var drafts: [WorklogDraft] = []

    // MARK: - Caches and niceties

    /// Most-recently-tracked issues, newest first — the panel's default list.
    public var recentIssues: [IssueRef] = []
    /// Issues the user pinned to the top of the panel.
    public var pinnedIssues: [IssueRef] = []
    /// Ad-hoc buckets the user has created, so labels persist between uses.
    public var savedAdhocTargets: [AdhocRef] = []

    // MARK: - Reminder bookkeeping

    public var lastNudgeAt: Date?
    public var lastBreakReminderAt: Date?
    public var lastEndOfDayReviewOn: Date?
    /// Suppresses repeated meeting prompts for the same continuous meeting.
    public var lastMeetingPromptAt: Date?

    /// Identity of the Jira account this history belongs to, so switching accounts does not
    /// silently mix two people's timesheets.
    public var jiraAccountID: String?

    public init() {}

    // MARK: - Derived

    public var isRunning: Bool { activeTarget != nil && runningSince != nil }
    public var isPaused: Bool { activeTarget != nil && runningSince == nil }
    public var isIdle: Bool { activeTarget == nil }

    /// Reconstructs the open segment, if any, so callers can treat it like any other segment.
    public func openSegment() -> WorkSegment? {
        guard let activeTarget, let runningSince, let openSegmentID else { return nil }
        return WorkSegment(
            id: openSegmentID,
            target: activeTarget,
            start: runningSince,
            end: nil,
            note: openSegmentNote,
            source: openSegmentSource
        )
    }

    /// Closed segments plus the open one — the list every rollup should be computed from.
    public func allSegments() -> [WorkSegment] {
        guard let open = openSegment() else { return segments }
        return segments + [open]
    }

    /// The pending worklog queue, oldest first.
    public var pendingDrafts: [WorklogDraft] {
        drafts.filter { !$0.isTerminal }.sorted { $0.createdAt < $1.createdAt }
    }

    public var unsyncedSeconds: Int {
        pendingDrafts.reduce(0) { $0 + $1.seconds }
    }
}

/// A month's worth of retired segments, stored separately to keep `state.json` small and quick
/// to write on every heartbeat.
public struct SegmentArchive: Codable, Sendable {
    public var month: String  // "2026-07"
    public var segments: [WorkSegment]

    public init(month: String, segments: [WorkSegment]) {
        self.month = month
        self.segments = segments
    }

    public static func monthKey(for date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", parts.year ?? 0, parts.month ?? 0)
    }

    public static func filename(month: String) -> String { "segments-\(month).json" }
    public static let filenamePrefix = "segments-"
}
