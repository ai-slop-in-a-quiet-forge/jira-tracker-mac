import Foundation

/// A unit of work waiting to become a Jira worklog.
///
/// Drafts exist as a separate stage rather than posting straight from a segment because the
/// network is not reliable and Jira is not always reachable from a laptop that has just woken
/// up on a train. A draft is durable, retryable and — crucially — carries an idempotency key
/// so a retry after an ambiguous failure cannot double-log the same hour.
public struct WorklogDraft: Codable, Sendable, Identifiable, Equatable {
    public var id: UUID
    public var issueKey: String
    public var issueID: String?
    /// The Jira `started` timestamp: when the work began.
    public var started: Date
    public var seconds: Int
    public var comment: String?
    /// The segments rolled into this draft, so the timesheet can show provenance and so a
    /// failed draft can be recomputed from source.
    public var segmentIDs: [UUID]
    public var state: SyncState
    public var attempts: Int
    public var lastError: String?
    /// Jira's id for the created worklog, once it exists.
    public var remoteWorklogID: String?
    public var createdAt: Date
    public var submittedAt: Date?
    /// When the last submission attempt was made, so backoff can be computed without the
    /// queue holding in-memory state that a relaunch would lose.
    public var lastAttemptAt: Date?

    public init(
        id: UUID = UUID(),
        issueKey: String,
        issueID: String? = nil,
        started: Date,
        seconds: Int,
        comment: String? = nil,
        segmentIDs: [UUID] = [],
        state: SyncState = .pending,
        attempts: Int = 0,
        lastError: String? = nil,
        remoteWorklogID: String? = nil,
        createdAt: Date = Date(),
        submittedAt: Date? = nil,
        lastAttemptAt: Date? = nil
    ) {
        self.id = id
        self.issueKey = issueKey
        self.issueID = issueID
        self.started = started
        self.seconds = seconds
        self.comment = comment
        self.segmentIDs = segmentIDs
        self.state = state
        self.attempts = attempts
        self.lastError = lastError
        self.remoteWorklogID = remoteWorklogID
        self.createdAt = createdAt
        self.submittedAt = submittedAt
        self.lastAttemptAt = lastAttemptAt
    }

    /// Fingerprint used to recognise this draft among the worklogs Jira already has.
    ///
    /// Jira's worklog endpoint has no idempotency header, so a request that timed out *after*
    /// Jira committed it cannot be detected by asking Jira about the request. Instead, before
    /// re-sending, the sync queue lists the issue's worklogs and looks for one by the same
    /// author with the same `started` instant and duration. `started` comes from us with
    /// millisecond precision, so a false match is vanishingly unlikely.
    public func matches(_ worklog: JiraWorklog, tolerance: TimeInterval = 2) -> Bool {
        guard worklog.seconds == seconds, let remoteStart = worklog.started else { return false }
        return abs(remoteStart.timeIntervalSince(started)) <= tolerance
    }

    public var isTerminal: Bool {
        switch state {
        case .submitted, .discarded: return true
        case .pending, .submitting, .failed: return false
        }
    }

    public var isRetryable: Bool {
        if case .failed(let kind) = state { return kind.isRetryable }
        return state == .pending
    }

    // MARK: - Immutable transitions

    public func marking(_ newState: SyncState, at date: Date, error: String? = nil) -> WorklogDraft {
        var copy = self
        copy.state = newState
        copy.lastError = error
        if case .submitting = newState {
            copy.attempts += 1
            copy.lastAttemptAt = date
        }
        if case .submitted = newState { copy.submittedAt = date }
        return copy
    }

    public func submitted(remoteID: String?, at date: Date) -> WorklogDraft {
        var copy = self
        copy.state = .submitted
        copy.remoteWorklogID = remoteID
        copy.submittedAt = date
        copy.lastError = nil
        return copy
    }

    /// Exponential backoff with a ceiling, so a permanently sad network does not hammer Jira.
    public func nextRetryDelay() -> TimeInterval {
        let base: TimeInterval = 15
        let capped = min(attempts, 7)
        return min(base * pow(2, Double(capped)), 30 * 60)
    }
}

public enum SyncState: Codable, Sendable, Equatable {
    case pending
    case submitting
    case submitted
    case failed(FailureKind)
    /// User decided not to log this after all; kept for the audit trail.
    case discarded

    public var label: String {
        switch self {
        case .pending: return "Queued"
        case .submitting: return "Sending…"
        case .submitted: return "Logged"
        case .failed(let kind): return kind.label
        case .discarded: return "Discarded"
        }
    }
}

public enum FailureKind: String, Codable, Sendable {
    /// Offline, DNS failure, timeout — worth retrying, probably soon.
    case network
    /// 401/403 — the token is wrong or expired. Retrying will not help until the user acts.
    case authentication
    /// 404 — the issue was deleted or the key changed.
    case issueNotFound
    /// 400 — Jira rejected the payload (often: worklogs disabled on the project).
    case rejected
    /// 429 — back off and try later.
    case rateLimited
    /// 5xx.
    case serverError
    case unknown

    public var isRetryable: Bool {
        switch self {
        case .network, .rateLimited, .serverError, .unknown: return true
        case .authentication, .issueNotFound, .rejected: return false
        }
    }

    public var label: String {
        switch self {
        case .network: return "Offline — will retry"
        case .authentication: return "Sign-in needed"
        case .issueNotFound: return "Issue not found"
        case .rejected: return "Jira rejected it"
        case .rateLimited: return "Rate limited — will retry"
        case .serverError: return "Jira error — will retry"
        case .unknown: return "Failed"
        }
    }

    /// What the user should actually do about it.
    public var remedy: String? {
        switch self {
        case .authentication: return "Open Settings and re-enter your Jira API token."
        case .issueNotFound: return "Reassign this time to a different issue."
        case .rejected: return "Check that work logging is enabled for this project."
        default: return nil
        }
    }
}
