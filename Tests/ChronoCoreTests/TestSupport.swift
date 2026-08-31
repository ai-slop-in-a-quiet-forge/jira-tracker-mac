import Foundation
import Testing
@testable import ChronoCore

/// Shared fixtures. Every test gets its own temporary directory so runs are independent and
/// can execute in parallel.
enum Fixture {
    static func tempStore() throws -> StateStore {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("chrono-tests-\(UUID().uuidString)", isDirectory: true)
        let fileStore = FileStore(directory: directory)
        try fileStore.ensureDirectoryExists()
        // Zero debounce: tests should not have to wait on a timer to observe a write.
        return StateStore(fileStore: fileStore, debounce: 0)
    }

    /// A fixed instant with a comfortable margin either side of midnight: 2026-03-10 09:00 local.
    static var referenceDate: Date {
        var components = DateComponents()
        components.year = 2026
        components.month = 3
        components.day = 10
        components.hour = 9
        components.minute = 0
        return Calendar.current.date(from: components)!
    }

    static func issue(_ key: String, _ summary: String = "Some work", id: String? = nil) -> TrackingTarget {
        .issue(IssueRef(key: key, id: id, summary: summary))
    }

    static func adhoc(_ category: AdhocCategory = .meeting, id: UUID = UUID()) -> TrackingTarget {
        .adhoc(AdhocRef(id: id, label: category.defaultLabel, category: category))
    }

    static func segment(
        _ target: TrackingTarget,
        from start: Date,
        minutes: Double,
        note: String? = nil,
        id: UUID = UUID()
    ) -> WorkSegment {
        WorkSegment(
            id: id,
            target: target,
            start: start,
            end: start.addingTimeInterval(minutes * 60),
            note: note
        )
    }

    @MainActor
    static func engine(clock: MutableClock) throws -> TrackingEngine {
        let store = try tempStore()
        return TrackingEngine(store: store, clock: clock)
    }
}

/// An in-memory stand-in for Jira, so sync behaviour can be tested without a network.
///
/// An actor rather than a lock-guarded class: `JiraAPI` is an async protocol, so actor
/// isolation is the natural fit and avoids locking from async contexts.
actor FakeJira: JiraAPI {
    struct Created: Equatable {
        let issueKey: String
        let started: Date
        let seconds: Int
        let comment: String?
    }

    private var _created: [Created] = []
    private var _existing: [String: [JiraWorklog]] = [:]
    /// Scripted failures, consumed one per `createWorklog` call.
    private var failures: [JiraError] = []
    /// When true, `worklogs(issueKey:)` throws — simulating a failed duplicate check.
    private var worklogLookupFails = false
    private var accountID = "acct-1"

    init(accountID: String = "acct-1") {
        self.accountID = accountID
    }

    // MARK: - Test controls

    func scheduleFailures(_ errors: [JiraError]) { failures = errors }
    func setWorklogLookupFails(_ value: Bool) { worklogLookupFails = value }
    func seedExisting(_ worklog: JiraWorklog) { _existing[worklog.issueKey, default: []].append(worklog) }

    var created: [Created] { _created }
    var createCallCount: Int { _created.count }

    // MARK: - JiraAPI

    func currentUser() async throws -> JiraUser {
        JiraUser(
            accountId: accountID,
            displayName: "Test User",
            emailAddress: "t@example.com",
            timeZone: "UTC",
            avatarUrls: nil
        )
    }

    func search(jql: String, maxResults: Int, pageToken: String?) async throws -> JiraSearchPage {
        JiraSearchPage(issues: [])
    }

    func pickIssues(matching query: String) async throws -> [IssueRef] { [] }

    func issue(key: String) async throws -> IssueRef { IssueRef(key: key, summary: "Fetched") }

    func createWorklog(
        issueKey: String,
        started: Date,
        seconds: Int,
        comment: String?,
        adjustEstimate: EstimateAdjustment
    ) async throws -> String? {
        if !failures.isEmpty { throw failures.removeFirst() }

        _created.append(Created(issueKey: issueKey, started: started, seconds: seconds, comment: comment))
        let id = "wl-\(_created.count)"
        _existing[issueKey, default: []].append(
            JiraWorklog(
                id: id,
                issueKey: issueKey,
                started: started,
                seconds: seconds,
                authorAccountID: accountID,
                comment: comment ?? ""
            )
        )
        return id
    }

    func worklogs(issueKey: String) async throws -> [JiraWorklog] {
        if worklogLookupFails { throw JiraError.transport("lookup down") }
        return _existing[issueKey] ?? []
    }

    func deleteWorklog(issueKey: String, worklogID: String) async throws {
        _existing[issueKey]?.removeAll { $0.id == worklogID }
    }
}
