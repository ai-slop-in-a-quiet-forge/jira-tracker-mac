import Foundation
import Observation
import ChronoCore

/// Drives the worklog queue.
///
/// Responsibilities kept narrow on purpose: decide *when* a sync should run, run it, and merge
/// the results back into the engine. The retry policy itself lives in `WorklogSyncQueue`, and
/// what to submit lives in `WorklogBuilder`.
@MainActor
@Observable
public final class SyncCoordinator {

    public private(set) var isSyncing = false
    public private(set) var lastSyncedAt: Date?
    public private(set) var lastError: String?
    /// Set when Jira rejected the credentials, so the UI can prompt for re-authentication
    /// instead of silently retrying forever.
    public private(set) var needsReauthentication = false

    /// Retry sweep interval. Individual drafts have their own exponential backoff, so this only
    /// has to be frequent enough to notice the network coming back.
    private static let sweepInterval: TimeInterval = 90

    private let engine: TrackingEngine
    private let connection: JiraConnection
    private var timer: Timer?

    public var onSubmitted: ((Int, Int) -> Void)?
    public var onFailure: ((String) -> Void)?

    public init(engine: TrackingEngine, connection: JiraConnection) {
        self.engine = engine
        self.connection = connection
    }

    public func start() {
        timer?.invalidate()
        let timer = Timer(timeInterval: Self.sweepInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncIfNeeded() }
        }
        timer.tolerance = 15
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Number of drafts waiting, for the badge in the panel footer.
    public var pendingCount: Int { engine.state.pendingDrafts.count }
    public var pendingSeconds: Int { engine.state.unsyncedSeconds }

    /// Drafts eligible for automatic submission under the current strategy.
    private func eligibleDrafts() -> [WorklogDraft] {
        let pending = engine.state.pendingDrafts
        switch engine.settings.submitStrategy {
        case .onStop:
            return pending
        case .endOfDay, .manual:
            // Under these strategies nothing goes automatically; the user submits from the
            // timesheet, which calls `sync(force:)`.
            return []
        }
    }

    public func syncIfNeeded() {
        guard !eligibleDrafts().isEmpty else { return }
        Task { await sync() }
    }

    /// Runs a sync. `force` bypasses both the submit strategy and per-draft backoff.
    public func sync(force: Bool = false) async {
        guard !isSyncing else { return }
        guard let client = connection.client else {
            lastError = "Not connected to Jira."
            return
        }

        let drafts = force ? engine.state.pendingDrafts : eligibleDrafts()
        guard !drafts.isEmpty else { return }

        isSyncing = true
        defer { isSyncing = false }

        let queue = WorklogSyncQueue(api: client, accountID: connection.user?.accountId)
        let outcome = await queue.process(drafts: drafts, settings: engine.settings, force: force)

        if !outcome.updated.isEmpty {
            engine.applyDraftUpdates(outcome.updated)
        }
        lastSyncedAt = Date()

        if outcome.submittedSeconds > 0 {
            let issues = Set(
                outcome.updated.filter { $0.state == .submitted }.map(\.issueKey)
            ).count
            onSubmitted?(outcome.submittedSeconds, issues)
        }

        if let error = outcome.blockingError {
            lastError = error.errorDescription
            needsReauthentication = error.failureKind == .authentication
            // Only shout about a real problem. Being offline is normal and self-healing; a bad
            // token is not, and needs the user.
            if needsReauthentication {
                onFailure?(error.errorDescription ?? "Jira rejected the credentials.")
                await connection.verify()
            }
        } else {
            lastError = nil
            needsReauthentication = false
        }
    }

    /// Removes a submitted worklog from Jira again — the "undo" right after an accidental log.
    public func undo(draft: WorklogDraft) async -> Bool {
        guard let client = connection.client, draft.remoteWorklogID != nil else { return false }
        let queue = WorklogSyncQueue(api: client, accountID: connection.user?.accountId)
        do {
            try await queue.deleteRemote(draft: draft)
            engine.releaseDraft(id: draft.id)
            return true
        } catch {
            lastError = (error as? JiraError)?.errorDescription ?? error.localizedDescription
            return false
        }
    }

    public var statusSummary: String {
        if isSyncing { return "Syncing…" }
        if needsReauthentication { return "Sign-in needed" }
        let pending = pendingCount
        if pending > 0 {
            return "\(DurationFormat.humane(Double(pendingSeconds))) queued"
        }
        if let lastSyncedAt {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .abbreviated
            return "Synced \(formatter.localizedString(for: lastSyncedAt, relativeTo: Date()))"
        }
        return "Nothing queued"
    }
}
