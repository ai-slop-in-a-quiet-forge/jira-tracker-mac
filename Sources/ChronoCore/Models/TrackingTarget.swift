import Foundation

/// What the timer is currently pointed at.
///
/// Deliberately an enum rather than "a struct with an optional issue key": a huge part of
/// the problem this app solves is the *unplanned* time — the ad-hoc Teams call, the
/// interruption, the thing you did for twenty minutes that has no ticket yet. Modelling
/// that as a first-class case, instead of a half-empty issue, means untracked time can be
/// captured immediately and reconciled to a Jira issue later without losing the timestamps.
public enum TrackingTarget: Codable, Hashable, Sendable, Identifiable {
    case issue(IssueRef)
    case adhoc(AdhocRef)

    public var id: String {
        switch self {
        case .issue(let ref): return "issue:\(ref.key)"
        case .adhoc(let ref): return "adhoc:\(ref.id.uuidString)"
        }
    }

    /// Short label for the menu bar — kept tight because menu bar space is precious.
    public var shortLabel: String {
        switch self {
        case .issue(let ref): return ref.key
        case .adhoc(let ref): return ref.category.shortLabel
        }
    }

    /// Full label for panels and notifications.
    public var displayLabel: String {
        switch self {
        case .issue(let ref): return "\(ref.key) — \(ref.summary)"
        case .adhoc(let ref): return ref.label
        }
    }

    public var issueKey: String? {
        if case .issue(let ref) = self { return ref.key }
        return nil
    }

    public var adhoc: AdhocRef? {
        if case .adhoc(let ref) = self { return ref }
        return nil
    }

    /// Ad-hoc time cannot be pushed to Jira until it has been assigned an issue.
    public var isLoggable: Bool { issueKey != nil }
}

/// A Jira issue, cached locally so the panel and the phone remote can render it offline.
public struct IssueRef: Codable, Hashable, Sendable, Identifiable {
    public var key: String
    /// Jira's internal numeric id. The worklog endpoint accepts either, but the id is
    /// stable across project-key renames, so we keep it when we have it.
    public var id: String?
    public var summary: String
    public var projectKey: String?
    public var issueType: String?
    public var status: String?
    public var priority: String?
    public var assigneeAccountID: String?
    /// When Jira last told us about this issue — drives cache staleness.
    public var fetchedAt: Date?

    public init(
        key: String,
        id: String? = nil,
        summary: String = "",
        projectKey: String? = nil,
        issueType: String? = nil,
        status: String? = nil,
        priority: String? = nil,
        assigneeAccountID: String? = nil,
        fetchedAt: Date? = nil
    ) {
        self.key = key
        self.id = id
        self.summary = summary
        self.projectKey = projectKey
        self.issueType = issueType
        self.status = status
        self.priority = priority
        self.assigneeAccountID = assigneeAccountID
        self.fetchedAt = fetchedAt
    }

    /// Two issue refs are the same issue if the key matches; the cached metadata around it
    /// is incidental. Used for de-duplicating recents lists.
    public func isSameIssue(as other: IssueRef) -> Bool { key == other.key }
}

/// Time that is real but has no ticket yet.
public struct AdhocRef: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var label: String
    public var category: AdhocCategory

    public init(id: UUID = UUID(), label: String, category: AdhocCategory = .other) {
        self.id = id
        self.label = label
        self.category = category
    }

    /// The one-tap buckets offered when something interrupts you. These exist so that
    /// "a call just landed" is a single click, not a data-entry exercise.
    public static func quick(_ category: AdhocCategory) -> AdhocRef {
        AdhocRef(label: category.defaultLabel, category: category)
    }
}

public enum AdhocCategory: String, Codable, CaseIterable, Sendable {
    case meeting
    case call
    case interruption
    case support
    case admin
    case review
    case learning
    case breakTime = "break"
    case other

    public var defaultLabel: String {
        switch self {
        case .meeting: return "Meeting"
        case .call: return "Call"
        case .interruption: return "Interruption"
        case .support: return "Support / firefighting"
        case .admin: return "Admin"
        case .review: return "Code review"
        case .learning: return "Learning"
        case .breakTime: return "Break"
        case .other: return "Unfiled work"
        }
    }

    public var shortLabel: String {
        switch self {
        case .meeting: return "Meeting"
        case .call: return "Call"
        case .interruption: return "Interrupt"
        case .support: return "Support"
        case .admin: return "Admin"
        case .review: return "Review"
        case .learning: return "Learning"
        case .breakTime: return "Break"
        case .other: return "Unfiled"
        }
    }

    public var symbolName: String {
        switch self {
        case .meeting: return "person.2.fill"
        case .call: return "phone.fill"
        case .interruption: return "bolt.fill"
        case .support: return "flame.fill"
        case .admin: return "tray.full.fill"
        case .review: return "eyeglasses"
        case .learning: return "book.fill"
        case .breakTime: return "cup.and.saucer.fill"
        case .other: return "questionmark.circle.fill"
        }
    }

    /// Break time is tracked so the day adds up honestly, but it is never billed to Jira.
    public var countsAsWork: Bool { self != .breakTime }
}
