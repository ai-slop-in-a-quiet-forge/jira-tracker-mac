import Foundation
import Observation
import ChronoCore

/// Finds issues to track.
///
/// Search is debounced and cancellable, because the panel searches as you type and Jira is a
/// network away. A pasted or typed issue key short-circuits straight to a direct fetch, which
/// is the fastest path for the most common case: you already know the ticket.
@MainActor
@Observable
public final class IssueService {

    public private(set) var results: [IssueRef] = []
    public private(set) var isSearching = false
    public private(set) var errorMessage: String?
    public private(set) var activeFilter: SavedFilter?
    /// The query the current `results` correspond to, so the UI can tell stale from fresh.
    public private(set) var resolvedQuery = ""

    /// How long to wait after the last keystroke before asking Jira.
    private static let debounce: Duration = .milliseconds(250)

    private let connection: JiraConnection
    private var searchTask: Task<Void, Never>?
    /// Short-lived cache so re-typing a query, or backspacing into one, is instant.
    private var cache: [String: [IssueRef]] = [:]

    public init(connection: JiraConnection) {
        self.connection = connection
    }

    /// Whether the text is shaped like a Jira issue key (`ABC-123`, `CYM_2-4517`).
    ///
    /// Hand-parsed rather than done with a regex: it is faster on a per-keystroke path, and
    /// the rules are clearer written out than encoded in a pattern.
    public static func looksLikeIssueKey(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Split on the *last* dash, so a project key containing one still parses.
        guard let dash = trimmed.lastIndex(of: "-") else { return false }

        let project = trimmed[trimmed.startIndex..<dash]
        let number = trimmed[trimmed.index(after: dash)...]

        guard let first = project.first, first.isLetter else { return false }
        guard project.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else { return false }
        guard !number.isEmpty, number.allSatisfy(\.isNumber) else { return false }
        return true
    }

    // MARK: - Querying

    /// Called on every keystroke. Cancels the in-flight search and schedules a new one.
    public func search(_ raw: String) {
        let query = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        searchTask?.cancel()

        guard !query.isEmpty else {
            // Empty box: fall back to the active filter's list.
            searchTask = Task { await loadFilter(activeFilter) }
            return
        }

        if let cached = cache[query.lowercased()] {
            results = cached
            resolvedQuery = query
            errorMessage = nil
            return
        }

        searchTask = Task { [weak self] in
            try? await Task.sleep(for: Self.debounce)
            guard !Task.isCancelled else { return }
            await self?.performSearch(query)
        }
    }

    private func performSearch(_ query: String) async {
        guard let client = connection.client else {
            errorMessage = "Connect to Jira to search issues."
            return
        }

        isSearching = true
        defer { isSearching = false }
        errorMessage = nil

        do {
            var found: [IssueRef]

            if Self.looksLikeIssueKey(query) {
                // Direct hit. Still fall back to a fuzzy search if the key does not exist, so a
                // typo does not leave the user staring at an empty list.
                let key = query.uppercased()
                do {
                    found = [try await client.issue(key: key)]
                } catch {
                    found = try await client.pickIssues(matching: query)
                }
            } else {
                found = try await client.pickIssues(matching: query)
                if found.isEmpty {
                    // The picker only matches keys and summaries; widen to a text search.
                    let escaped = query.replacingOccurrences(of: "\"", with: "\\\"")
                    found = try await client.search(
                        jql: "text ~ \"\(escaped)*\" ORDER BY updated DESC",
                        maxResults: 25,
                        pageToken: nil
                    ).issues
                }
            }

            guard !Task.isCancelled else { return }
            results = found
            resolvedQuery = query
            cache[query.lowercased()] = found
            trimCache()
        } catch let error as JiraError {
            guard !Task.isCancelled else { return }
            results = []
            errorMessage = error.errorDescription
        } catch {
            guard !Task.isCancelled else { return }
            results = []
            errorMessage = error.localizedDescription
        }
    }

    /// Runs a saved filter's JQL — the list shown when the search box is empty.
    public func loadFilter(_ filter: SavedFilter?) async {
        activeFilter = filter
        resolvedQuery = ""

        guard let client = connection.client else {
            results = []
            errorMessage = connection.state == .unconfigured ? nil : "Jira is unreachable."
            return
        }
        guard let filter else {
            results = []
            return
        }

        isSearching = true
        defer { isSearching = false }
        do {
            results = try await client.search(jql: filter.jql, maxResults: 40, pageToken: nil).issues
            errorMessage = nil
        } catch let error as JiraError {
            results = []
            // A malformed saved filter is worth naming precisely; people write their own JQL.
            errorMessage = error.failureKind == .rejected
                ? "That filter's JQL was rejected by Jira."
                : error.errorDescription
        } catch {
            results = []
            errorMessage = error.localizedDescription
        }
    }

    public func clear() {
        searchTask?.cancel()
        results = []
        resolvedQuery = ""
        errorMessage = nil
    }

    public func invalidateCache() {
        cache.removeAll()
    }

    private func trimCache() {
        guard cache.count > 40 else { return }
        cache.removeAll()
    }
}
