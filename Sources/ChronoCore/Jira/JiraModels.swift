import Foundation

// MARK: - Wire types
//
// These mirror Jira Cloud REST v3 responses. They are kept separate from `IssueRef` and
// friends so that a change in Jira's payload shape never leaks into the domain model or the
// on-disk format.

/// Jira is inconsistent about whether ids arrive as strings or numbers (the issue *picker*
/// endpoint returns numeric ids, everything else returns strings). This decodes either.
public struct FlexibleID: Codable, Sendable, Hashable {
    public let value: String

    public init(_ value: String) { self.value = value }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let text = try? container.decode(String.self) {
            value = text
        } else if let number = try? container.decode(Int64.self) {
            value = String(number)
        } else {
            throw DecodingError.typeMismatch(
                String.self,
                .init(codingPath: decoder.codingPath, debugDescription: "Expected a string or integer id")
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}

struct JiraIssueDTO: Codable {
    let id: FlexibleID?
    let key: String
    let fields: Fields?

    struct Fields: Codable {
        let summary: String?
        let status: NamedDTO?
        let issuetype: NamedDTO?
        let priority: NamedDTO?
        let project: ProjectDTO?
        let assignee: AssigneeDTO?
        let timetracking: TimeTrackingDTO?
    }

    struct NamedDTO: Codable {
        let name: String?
        let statusCategory: StatusCategoryDTO?
    }

    struct StatusCategoryDTO: Codable {
        let key: String?
        let name: String?
    }

    struct ProjectDTO: Codable {
        let key: String?
        let name: String?
    }

    struct AssigneeDTO: Codable {
        let accountId: String?
        let displayName: String?
    }

    struct TimeTrackingDTO: Codable {
        let originalEstimateSeconds: Int?
        let remainingEstimateSeconds: Int?
        let timeSpentSeconds: Int?
    }

    /// Projects into the domain model.
    func toIssueRef(fetchedAt: Date) -> IssueRef {
        IssueRef(
            key: key,
            id: id?.value,
            summary: fields?.summary ?? "",
            projectKey: fields?.project?.key,
            issueType: fields?.issuetype?.name,
            status: fields?.status?.name,
            priority: fields?.priority?.name,
            assigneeAccountID: fields?.assignee?.accountId,
            fetchedAt: fetchedAt
        )
    }
}

/// Response of `POST /rest/api/3/search/jql` (the token-paginated replacement for the
/// removed `/search` endpoint).
struct JiraSearchResponseDTO: Codable {
    let issues: [JiraIssueDTO]?
    let nextPageToken: String?
    let isLast: Bool?
}

/// Response of `GET /rest/api/3/issue/picker` — Jira's own type-ahead, which is far better at
/// fuzzy-matching an issue from a few characters than any JQL we could write.
struct JiraPickerResponseDTO: Codable {
    let sections: [Section]?

    struct Section: Codable {
        let id: String?
        let label: String?
        let issues: [PickerIssue]?
    }

    struct PickerIssue: Codable {
        let id: FlexibleID?
        let key: String
        let summaryText: String?
        let summary: String?
        let img: String?

        var bestSummary: String {
            // `summary` is HTML-highlighted (<b> around the match); summaryText is plain.
            summaryText ?? summary?.replacingOccurrences(
                of: "<[^>]+>",
                with: "",
                options: .regularExpression
            ) ?? ""
        }
    }
}

struct JiraWorklogResponseDTO: Codable {
    let id: FlexibleID?
    let issueId: FlexibleID?
    let timeSpentSeconds: Int?
    let started: String?
}

struct JiraWorklogListDTO: Codable {
    let worklogs: [Entry]?
    let total: Int?

    struct Entry: Codable {
        let id: FlexibleID?
        let started: String?
        let timeSpentSeconds: Int?
        let author: JiraIssueDTO.AssigneeDTO?
        /// ADF; decoded loosely because we only ever flatten it to text.
        let comment: AnyCodable?
    }
}

/// Existing Jira worklogs, used for the "already logged elsewhere" reconciliation check.
public struct JiraWorklog: Sendable, Identifiable, Equatable {
    public let id: String
    public let issueKey: String
    public let started: Date?
    public let seconds: Int
    public let authorAccountID: String?
    public let comment: String

    public init(id: String, issueKey: String, started: Date?, seconds: Int, authorAccountID: String?, comment: String) {
        self.id = id
        self.issueKey = issueKey
        self.started = started
        self.seconds = seconds
        self.authorAccountID = authorAccountID
        self.comment = comment
    }
}

/// A type-erased JSON value, so ADF blobs can ride through Codable untouched.
public struct AnyCodable: Codable, @unchecked Sendable {
    public let value: Any

    public init(_ value: Any) { self.value = value }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { value = NSNull() }
        else if let v = try? container.decode(Bool.self) { value = v }
        else if let v = try? container.decode(Int.self) { value = v }
        else if let v = try? container.decode(Double.self) { value = v }
        else if let v = try? container.decode(String.self) { value = v }
        else if let v = try? container.decode([AnyCodable].self) { value = v.map(\.value) }
        else if let v = try? container.decode([String: AnyCodable].self) {
            value = v.mapValues(\.value)
        } else {
            value = NSNull()
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case let v as Bool: try container.encode(v)
        case let v as Int: try container.encode(v)
        case let v as Double: try container.encode(v)
        case let v as String: try container.encode(v)
        case let v as [Any]: try container.encode(v.map(AnyCodable.init))
        case let v as [String: Any]: try container.encode(v.mapValues(AnyCodable.init))
        default: try container.encodeNil()
        }
    }
}

/// One page of JQL results.
public struct JiraSearchPage: Sendable, Equatable {
    public let issues: [IssueRef]
    public let nextPageToken: String?
    public let isLast: Bool

    public init(issues: [IssueRef], nextPageToken: String? = nil, isLast: Bool = true) {
        self.issues = issues
        self.nextPageToken = nextPageToken
        self.isLast = isLast
    }
}

/// How a worklog should affect the issue's remaining estimate.
public enum EstimateAdjustment: String, Codable, Sendable, CaseIterable {
    /// Jira's default: subtract the logged time from the remaining estimate.
    case auto
    /// Log the time but leave the estimate untouched.
    case leave

    public var title: String {
        switch self {
        case .auto: return "Reduce the remaining estimate"
        case .leave: return "Leave the estimate alone"
        }
    }
}
