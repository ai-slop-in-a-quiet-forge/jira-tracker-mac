import Foundation

/// Pushes worklog drafts into Jira, durably.
///
/// An actor, so only one submission run happens at a time no matter how many things ask for a
/// sync (a timer stopping, the network coming back, the user clicking "retry", the phone
/// remote). The queue is stateless between runs: it is handed a snapshot of drafts and returns
/// the updated ones, leaving the engine as the single owner of persistence.
///
/// The duplicate problem is the interesting part. If a POST times out, the worklog may or may
/// not exist in Jira. Blindly retrying risks double-logging an hour of someone's day, which is
/// worse than not logging it. So any draft that has already been attempted is checked against
/// the issue's existing worklogs first.
public actor WorklogSyncQueue {
    private let api: any JiraAPI
    private let clock: any Clock
    /// The authenticated account, so duplicate detection only considers our own worklogs.
    private let accountID: String?

    public init(api: any JiraAPI, accountID: String?, clock: any Clock = SystemClock()) {
        self.api = api
        self.accountID = accountID
        self.clock = clock
    }

    /// Attempts to submit every eligible draft.
    ///
    /// - Parameters:
    ///   - drafts: the current pending set.
    ///   - settings: for the estimate-adjustment preference.
    ///   - force: ignore backoff timers — used when the user explicitly clicks "retry now".
    /// - Returns: only the drafts whose state changed, ready to be merged back into the engine.
    public func process(
        drafts: [WorklogDraft],
        settings: Settings,
        force: Bool = false
    ) async -> SyncOutcome {
        var changed: [WorklogDraft] = []
        var submittedSeconds = 0
        var firstBlockingError: JiraError?

        for draft in drafts where !draft.isTerminal {
            guard draft.isRetryable else { continue }
            guard force || isDue(draft, now: clock.now) else { continue }

            let result = await submit(draft, settings: settings)
            changed.append(result.draft)
            if case .submitted = result.draft.state { submittedSeconds += result.draft.seconds }

            if let error = result.error {
                // An auth failure will hit every remaining draft identically; stop rather than
                // burn through the queue generating the same error a dozen times.
                if error.failureKind == .authentication {
                    firstBlockingError = error
                    break
                }
                if error.failureKind == .network {
                    firstBlockingError = error
                    break
                }
            }
        }

        return SyncOutcome(
            updated: changed,
            submittedSeconds: submittedSeconds,
            blockingError: firstBlockingError
        )
    }

    /// Whether enough time has passed since the last attempt.
    private func isDue(_ draft: WorklogDraft, now: Date) -> Bool {
        guard let last = draft.lastAttemptAt else { return true }
        return now.timeIntervalSince(last) >= draft.nextRetryDelay()
    }

    private struct Attempt {
        let draft: WorklogDraft
        let error: JiraError?
    }

    private func submit(_ draft: WorklogDraft, settings: Settings) async -> Attempt {
        let now = clock.now
        var working = draft.marking(.submitting, at: now)

        // Retry path: make sure we are not about to log the same time twice.
        if draft.attempts > 0 {
            if let existing = await findExistingWorklog(for: working) {
                ChronoLog.jira.info("Draft already present in Jira; adopting worklog \(existing.id, privacy: .public)")
                return Attempt(draft: working.submitted(remoteID: existing.id, at: now), error: nil)
            }
        }

        do {
            let remoteID = try await api.createWorklog(
                issueKey: working.issueKey,
                started: working.started,
                seconds: working.seconds,
                comment: working.comment,
                adjustEstimate: settings.adjustEstimate
            )
            return Attempt(draft: working.submitted(remoteID: remoteID, at: now), error: nil)
        } catch let error as JiraError {
            // An ambiguous failure — the request left but we never heard back — is the exact
            // case duplicate detection exists for on the next attempt.
            working = working.marking(
                .failed(error.failureKind),
                at: now,
                error: error.errorDescription
            )
            ChronoLog.jira.error("Worklog submit failed for \(working.issueKey, privacy: .public): \(error.failureKind.rawValue, privacy: .public)")
            return Attempt(draft: working, error: error)
        } catch {
            working = working.marking(.failed(.unknown), at: now, error: error.localizedDescription)
            return Attempt(draft: working, error: nil)
        }
    }

    /// Looks for a worklog Jira already has that this draft would duplicate.
    private func findExistingWorklog(for draft: WorklogDraft) async -> JiraWorklog? {
        do {
            let existing = try await api.worklogs(issueKey: draft.issueKey)
            return existing.first { worklog in
                // Only our own worklogs, and only ones matching this draft's fingerprint.
                let mine = accountID == nil || worklog.authorAccountID == nil || worklog.authorAccountID == accountID
                return mine && draft.matches(worklog)
            }
        } catch {
            // If we cannot check, err on the side of not logging twice by treating an
            // unverifiable state as "already there" is *wrong* — it would silently lose time.
            // Returning nil means we will attempt the POST; a duplicate is recoverable by the
            // user, silently-dropped time is not.
            ChronoLog.jira.debug("Duplicate check failed; proceeding with submit")
            return nil
        }
    }

    /// Removes a worklog from Jira — powers "undo" right after an accidental submit.
    public func deleteRemote(draft: WorklogDraft) async throws {
        guard let remoteID = draft.remoteWorklogID else { return }
        try await api.deleteWorklog(issueKey: draft.issueKey, worklogID: remoteID)
    }
}

public struct SyncOutcome: Sendable {
    public let updated: [WorklogDraft]
    public let submittedSeconds: Int
    /// Set when the run stopped early because every remaining draft would fail the same way.
    public let blockingError: JiraError?

    public var didSubmitAnything: Bool { submittedSeconds > 0 }

    public init(updated: [WorklogDraft], submittedSeconds: Int, blockingError: JiraError?) {
        self.updated = updated
        self.submittedSeconds = submittedSeconds
        self.blockingError = blockingError
    }
}
