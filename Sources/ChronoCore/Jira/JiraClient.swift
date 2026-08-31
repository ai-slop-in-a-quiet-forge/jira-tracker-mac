import Foundation

/// The surface of Jira that Chrono needs. A protocol so the engine and the sync queue can be
/// tested against a fake without a network or a live Jira site.
public protocol JiraAPI: Sendable {
    /// Verifies credentials and returns the authenticated account.
    func currentUser() async throws -> JiraUser
    func search(jql: String, maxResults: Int, pageToken: String?) async throws -> JiraSearchPage
    /// Jira's type-ahead. Much better at "cym 12" than any JQL we could construct.
    func pickIssues(matching query: String) async throws -> [IssueRef]
    func issue(key: String) async throws -> IssueRef
    /// Creates a worklog and returns Jira's id for it, when Jira supplies one.
    func createWorklog(
        issueKey: String,
        started: Date,
        seconds: Int,
        comment: String?,
        adjustEstimate: EstimateAdjustment
    ) async throws -> String?
    func worklogs(issueKey: String) async throws -> [JiraWorklog]
    func deleteWorklog(issueKey: String, worklogID: String) async throws
}

/// Talks to Jira Cloud REST v3 over HTTPS with API-token Basic auth.
///
/// A value type holding only immutable state, which makes it trivially `Sendable` and safe to
/// hand to any actor. It intentionally does *not* implement durable retry: the sync queue owns
/// that, because only the queue can persist attempt counts across relaunches. The one
/// exception is a short in-flight retry for idempotent reads, where a transient blip should
/// not surface as a user-visible error.
public struct JiraClient: JiraAPI {
    public let credentials: JiraCredentials
    private let session: URLSession
    private let clock: any Clock
    /// How many times an idempotent GET is retried on a transient failure.
    private let readRetries: Int

    public init(
        credentials: JiraCredentials,
        session: URLSession? = nil,
        clock: any Clock = SystemClock(),
        readRetries: Int = 2
    ) {
        self.credentials = credentials
        self.clock = clock
        self.readRetries = readRetries
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 20
            config.timeoutIntervalForResource = 60
            config.waitsForConnectivity = false
            // Jira responses are never useful stale, and a cache would make the issue list
            // look like it had failed to refresh.
            config.requestCachePolicy = .reloadIgnoringLocalCacheData
            config.httpAdditionalHeaders = ["User-Agent": JiraClient.userAgent]
            self.session = URLSession(configuration: config)
        }
    }

    static let userAgent = "Chrono/1.0 (macOS; local time tracker)"

    // MARK: - Requests

    private func makeRequest(
        path: String,
        method: String = "GET",
        query: [URLQueryItem] = [],
        body: [String: Any]? = nil
    ) throws -> URLRequest {
        guard var components = URLComponents(
            url: credentials.siteURL.appendingPathComponent(path),
            resolvingAgainstBaseURL: false
        ) else {
            throw JiraError.transport("Could not build a URL for \(path)")
        }
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else {
            throw JiraError.transport("Could not build a URL for \(path)")
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(credentials.basicAuthHeader, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // Atlassian asks clients to opt out of XSRF checks explicitly on REST calls.
        request.setValue("no-check", forHTTPHeaderField: "X-Atlassian-Token")

        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])
        }
        return request
    }

    /// Performs a request, mapping every failure onto `JiraError`.
    private func send(_ request: URLRequest) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            throw JiraError.transport(Self.describe(error))
        } catch {
            throw JiraError.transport(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw JiraError.decoding("Response was not HTTP")
        }

        switch http.statusCode {
        case 200..<300:
            return data
        case 429:
            // Surface Retry-After as the message so `JiraError.retryAfter` can read it back.
            let retryAfter = http.value(forHTTPHeaderField: "Retry-After") ?? ""
            throw JiraError.http(status: 429, message: retryAfter)
        default:
            throw JiraError.http(status: http.statusCode, message: Self.extractMessage(from: data))
        }
    }

    /// Same as `send`, plus a couple of quick retries. Only ever used for reads.
    private func sendIdempotent(_ request: URLRequest) async throws -> Data {
        var lastError: JiraError?
        for attempt in 0...readRetries {
            do {
                return try await send(request)
            } catch let error as JiraError {
                lastError = error
                let kind = error.failureKind
                // Retry only what could plausibly succeed a moment later.
                guard kind == .network || kind == .serverError || kind == .rateLimited,
                      attempt < readRetries
                else { throw error }
                let backoff = error.retryAfter ?? (0.4 * pow(2, Double(attempt)))
                try? await Task.sleep(nanoseconds: UInt64(min(backoff, 5) * 1_000_000_000))
            }
        }
        throw lastError ?? JiraError.emptyResponse
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        guard !data.isEmpty else { throw JiraError.emptyResponse }
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw JiraError.decoding(String(describing: error).prefix(300).description)
        }
    }

    /// Jira reports problems in `errorMessages` or a field-keyed `errors` object.
    static func extractMessage(from data: Data) -> String {
        guard !data.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return String(data: data.prefix(300), encoding: .utf8) ?? ""
        }
        if let messages = object["errorMessages"] as? [String], !messages.isEmpty {
            return messages.joined(separator: " ")
        }
        if let errors = object["errors"] as? [String: Any], !errors.isEmpty {
            return errors.map { "\($0.key): \($0.value)" }.sorted().joined(separator: "; ")
        }
        if let message = object["message"] as? String { return message }
        return ""
    }

    /// Turns URLError into something a human can act on, rather than "operation could not be
    /// completed".
    static func describe(_ error: URLError) -> String {
        switch error.code {
        case .notConnectedToInternet: return "no internet connection"
        case .timedOut: return "the request timed out"
        case .cannotFindHost: return "that Jira site could not be found — check the URL"
        case .cannotConnectToHost: return "could not connect to that Jira site"
        case .networkConnectionLost: return "the connection dropped"
        case .secureConnectionFailed, .serverCertificateUntrusted:
            return "the secure connection failed"
        case .appTransportSecurityRequiresSecureConnection:
            return "Jira must be reached over HTTPS"
        default: return error.localizedDescription
        }
    }

    // MARK: - JiraAPI

    private static let issueFields = [
        "summary", "status", "issuetype", "priority", "project", "assignee", "timetracking",
    ]

    public func currentUser() async throws -> JiraUser {
        let request = try makeRequest(path: "rest/api/3/myself")
        return try decode(JiraUser.self, from: try await sendIdempotent(request))
    }

    public func search(jql: String, maxResults: Int = 50, pageToken: String? = nil) async throws -> JiraSearchPage {
        var body: [String: Any] = [
            "jql": jql,
            "maxResults": max(1, min(maxResults, 100)),
            "fields": Self.issueFields,
        ]
        if let pageToken { body["nextPageToken"] = pageToken }

        // `/search/jql` is the current, token-paginated endpoint. Older/self-managed
        // instances only have the retired `/search`, so fall back rather than fail.
        do {
            let request = try makeRequest(path: "rest/api/3/search/jql", method: "POST", body: body)
            let dto = try decode(JiraSearchResponseDTO.self, from: try await sendIdempotent(request))
            let now = clock.now
            return JiraSearchPage(
                issues: (dto.issues ?? []).map { $0.toIssueRef(fetchedAt: now) },
                nextPageToken: dto.nextPageToken,
                isLast: dto.isLast ?? (dto.nextPageToken == nil)
            )
        } catch let error as JiraError {
            guard case .http(let status, _) = error, status == 404 || status == 410 else { throw error }
            return try await legacySearch(jql: jql, maxResults: maxResults)
        }
    }

    private func legacySearch(jql: String, maxResults: Int) async throws -> JiraSearchPage {
        let request = try makeRequest(
            path: "rest/api/3/search",
            query: [
                URLQueryItem(name: "jql", value: jql),
                URLQueryItem(name: "maxResults", value: String(max(1, min(maxResults, 100)))),
                URLQueryItem(name: "fields", value: Self.issueFields.joined(separator: ",")),
            ]
        )
        let dto = try decode(JiraSearchResponseDTO.self, from: try await sendIdempotent(request))
        let now = clock.now
        return JiraSearchPage(issues: (dto.issues ?? []).map { $0.toIssueRef(fetchedAt: now) })
    }

    public func pickIssues(matching query: String) async throws -> [IssueRef] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let request = try makeRequest(
            path: "rest/api/3/issue/picker",
            query: [
                URLQueryItem(name: "query", value: trimmed),
                URLQueryItem(name: "currentJQL", value: "resolution = Unresolved"),
                URLQueryItem(name: "showSubTasks", value: "true"),
            ]
        )
        let dto = try decode(JiraPickerResponseDTO.self, from: try await sendIdempotent(request))
        let now = clock.now

        // The picker returns several sections ("History", "Current Search"); flatten them and
        // de-duplicate, keeping the first occurrence so history-ranked hits stay on top.
        var seen = Set<String>()
        var results: [IssueRef] = []
        for section in dto.sections ?? [] {
            for issue in section.issues ?? [] where !seen.contains(issue.key) {
                seen.insert(issue.key)
                results.append(
                    IssueRef(
                        key: issue.key,
                        id: issue.id?.value,
                        summary: issue.bestSummary,
                        projectKey: issue.key.split(separator: "-").first.map(String.init),
                        fetchedAt: now
                    )
                )
            }
        }
        return results
    }

    public func issue(key: String) async throws -> IssueRef {
        let request = try makeRequest(
            path: "rest/api/3/issue/\(key)",
            query: [URLQueryItem(name: "fields", value: Self.issueFields.joined(separator: ","))]
        )
        let dto = try decode(JiraIssueDTO.self, from: try await sendIdempotent(request))
        return dto.toIssueRef(fetchedAt: clock.now)
    }

    public func createWorklog(
        issueKey: String,
        started: Date,
        seconds: Int,
        comment: String?,
        adjustEstimate: EstimateAdjustment
    ) async throws -> String? {
        var body: [String: Any] = [
            "timeSpentSeconds": max(60, seconds),
            "started": started.jiraTimestamp,
        ]
        if let document = ADF.document(from: comment) { body["comment"] = document }

        let request = try makeRequest(
            path: "rest/api/3/issue/\(issueKey)/worklog",
            method: "POST",
            query: [
                // Logging your own time should not email every watcher on the issue.
                URLQueryItem(name: "notifyUsers", value: "false"),
                URLQueryItem(name: "adjustEstimate", value: adjustEstimate.rawValue),
            ],
            body: body
        )
        let data = try await send(request)
        // A worklog id is nice to have (it lets us offer "undo"), but its absence is not a
        // failure — the time is logged either way.
        return (try? decode(JiraWorklogResponseDTO.self, from: data))?.id?.value
    }

    public func worklogs(issueKey: String) async throws -> [JiraWorklog] {
        let request = try makeRequest(path: "rest/api/3/issue/\(issueKey)/worklog")
        let dto = try decode(JiraWorklogListDTO.self, from: try await sendIdempotent(request))
        return (dto.worklogs ?? []).map { entry in
            JiraWorklog(
                id: entry.id?.value ?? UUID().uuidString,
                issueKey: issueKey,
                started: entry.started.flatMap(Self.parseJiraDate),
                seconds: entry.timeSpentSeconds ?? 0,
                authorAccountID: entry.author?.accountId,
                comment: ADF.plainText(from: entry.comment?.value)
            )
        }
    }

    public func deleteWorklog(issueKey: String, worklogID: String) async throws {
        let request = try makeRequest(
            path: "rest/api/3/issue/\(issueKey)/worklog/\(worklogID)",
            method: "DELETE",
            query: [URLQueryItem(name: "notifyUsers", value: "false")]
        )
        _ = try await send(request)
    }

    /// Parses Jira's `2024-05-21T09:13:00.000+0530` back into a `Date`.
    static func parseJiraDate(_ raw: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        for format in ["yyyy-MM-dd'T'HH:mm:ss.SSSZZZ", "yyyy-MM-dd'T'HH:mm:ssZZZ"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: raw) { return date }
        }
        return ISO8601DateFormatter().date(from: raw)
    }
}
