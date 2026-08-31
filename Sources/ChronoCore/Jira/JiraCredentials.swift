import Foundation

/// Jira Cloud credentials: a site, an account email and an API token.
///
/// Chrono deliberately uses an API token over Basic auth rather than OAuth. OAuth 3LO would
/// require a registered app with a redirect URL — i.e. a server — and the whole point of this
/// app is that there isn't one. An API token is created by the user at
/// id.atlassian.com/manage-profile/security/api-tokens, is scoped to that user, and can be
/// revoked from the same page.
public struct JiraCredentials: Sendable, Equatable {
    public let siteURL: URL
    public let email: String
    public let apiToken: String

    public init(siteURL: URL, email: String, apiToken: String) {
        self.siteURL = siteURL
        self.email = email
        self.apiToken = apiToken
    }

    /// Builds credentials from loosely-typed user input, normalising the many shapes people
    /// paste into a "site" field: bare hostnames, trailing slashes, a deep link to a board.
    public init?(rawSite: String, email: String, apiToken: String) {
        guard let url = JiraCredentials.normalizeSite(rawSite),
              !email.trimmingCharacters(in: .whitespaces).isEmpty,
              !apiToken.trimmingCharacters(in: .whitespaces).isEmpty
        else { return nil }
        self.siteURL = url
        self.email = email.trimmingCharacters(in: .whitespaces)
        self.apiToken = apiToken.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `acme` / `acme.atlassian.net` / `https://acme.atlassian.net/jira/software/…`
    /// all normalise to `https://acme.atlassian.net`.
    public static func normalizeSite(_ raw: String) -> URL? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        if !text.contains("://") {
            // A bare word is assumed to be an Atlassian Cloud subdomain.
            if !text.contains(".") { text += ".atlassian.net" }
            text = "https://" + text
        }
        guard var components = URLComponents(string: text), let host = components.host else { return nil }
        components.scheme = "https"
        components.host = host.lowercased()
        components.path = ""
        components.query = nil
        components.fragment = nil
        components.user = nil
        components.password = nil
        return components.url
    }

    /// `Authorization: Basic base64(email:token)`
    public var basicAuthHeader: String {
        let raw = "\(email):\(apiToken)"
        let encoded = Data(raw.utf8).base64EncodedString()
        return "Basic \(encoded)"
    }

    /// Never log the token. This is what shows up in diagnostics instead.
    public var redactedDescription: String {
        let tail = apiToken.count > 4 ? String(apiToken.suffix(4)) : ""
        return "\(siteURL.host ?? "?") as \(email) (token …\(tail))"
    }
}

/// The authenticated user, as Jira sees them. `accountID` is what `currentUser()` resolves to
/// in JQL, and what worklog authorship is checked against.
public struct JiraUser: Codable, Sendable, Equatable {
    public let accountId: String
    public let displayName: String
    public let emailAddress: String?
    public let timeZone: String?
    public let avatarUrls: [String: String]?

    public var avatarURL: URL? {
        guard let raw = avatarUrls?["48x48"] ?? avatarUrls?["32x32"] else { return nil }
        return URL(string: raw)
    }
}
