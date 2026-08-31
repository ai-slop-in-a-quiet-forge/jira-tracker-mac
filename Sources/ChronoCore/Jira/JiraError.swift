import Foundation

public enum JiraError: Error, Sendable, LocalizedError, Equatable {
    /// No credentials configured yet.
    case notConfigured
    /// Could not reach Jira at all: offline, DNS, TLS, timeout.
    case transport(String)
    /// Jira answered, but not happily.
    case http(status: Int, message: String)
    /// Jira answered with something we could not parse.
    case decoding(String)
    /// A response arrived with no body where one was required.
    case emptyResponse

    /// Maps onto the durable failure taxonomy used by the sync queue, which decides whether
    /// a retry is worth attempting.
    public var failureKind: FailureKind {
        switch self {
        case .notConfigured: return .authentication
        case .transport: return .network
        case .decoding, .emptyResponse: return .unknown
        case .http(let status, _):
            switch status {
            case 401, 403: return .authentication
            case 404: return .issueNotFound
            case 400, 405, 422: return .rejected
            case 429: return .rateLimited
            case 500...599: return .serverError
            default: return .unknown
            }
        }
    }

    public var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Chrono is not connected to Jira yet."
        case .transport(let detail):
            return "Could not reach Jira: \(detail)"
        case .http(let status, let message):
            // Jira's own error text is usually the most useful thing we can show.
            let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { return "Jira returned HTTP \(status)." }
            return "Jira returned HTTP \(status): \(trimmed)"
        case .decoding(let detail):
            return "Unexpected response from Jira: \(detail)"
        case .emptyResponse:
            return "Jira returned an empty response."
        }
    }

    /// Retry hint in seconds for rate limiting, if Jira told us one.
    public var retryAfter: TimeInterval? {
        if case .http(429, let message) = self, let seconds = TimeInterval(message) { return seconds }
        return nil
    }
}
