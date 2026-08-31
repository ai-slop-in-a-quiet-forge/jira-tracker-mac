import Foundation
import Observation
import ChronoCore

/// Owns the Jira credentials and the live client, and exposes the connection state the UI
/// needs to render honestly ("connected as…", "sign-in needed", "checking…").
///
/// Credentials come from one of two places, in order of preference:
/// 1. a 1Password secret reference, resolved through the `op` CLI at launch;
/// 2. the login Keychain.
///
/// The API token is never written to `settings.json`.
@MainActor
@Observable
public final class JiraConnection {

    public enum State: Equatable {
        case unconfigured
        case connecting
        case connected(JiraUser)
        /// The credentials exist but Jira rejected them.
        case unauthorized(String)
        /// Configured, but Jira is unreachable right now. The app stays fully usable offline.
        case offline(String)

        public var isConnected: Bool { if case .connected = self { return true }; return false }

        public var summary: String {
            switch self {
            case .unconfigured: return "Not connected"
            case .connecting: return "Connecting…"
            case .connected(let user): return user.displayName
            case .unauthorized: return "Sign-in needed"
            case .offline: return "Offline"
            }
        }

        public var symbolName: String {
            switch self {
            case .unconfigured: return "link.badge.plus"
            case .connecting: return "arrow.triangle.2.circlepath"
            case .connected: return "checkmark.circle.fill"
            case .unauthorized: return "exclamationmark.triangle.fill"
            case .offline: return "wifi.slash"
            }
        }
    }

    public private(set) var state: State = .unconfigured
    public private(set) var client: JiraClient?
    public private(set) var user: JiraUser?
    /// Set when the token came from 1Password, so Settings can say so instead of showing a
    /// token field the user cannot meaningfully edit.
    public private(set) var tokenSource: TokenSource = .none

    public enum TokenSource: Equatable {
        case none
        case keychain
        case onePassword(reference: String)

        public var description: String {
            switch self {
            case .none: return "No token stored"
            case .keychain: return "Stored in your login Keychain"
            case .onePassword(let reference): return "Read from 1Password (\(reference))"
            }
        }
    }

    private let keychain: KeychainStore

    public init(keychain: KeychainStore) {
        self.keychain = keychain
    }

    // MARK: - Loading

    /// Rebuilds the client from stored settings and secrets. Safe to call repeatedly.
    public func load(settings: Settings) async {
        guard let site = JiraCredentials.normalizeSite(settings.siteURL),
              !settings.accountEmail.isEmpty
        else {
            state = .unconfigured
            client = nil
            tokenSource = .none
            return
        }

        guard let token = await resolveToken(settings: settings) else {
            state = .unauthorized("No API token stored for \(settings.accountEmail).")
            client = nil
            return
        }

        let credentials = JiraCredentials(siteURL: site, email: settings.accountEmail, apiToken: token)
        client = JiraClient(credentials: credentials)
        await verify()
    }

    /// Resolves the token, preferring 1Password when a reference is configured.
    private func resolveToken(settings: Settings) async -> String? {
        if let reference = settings.onePasswordTokenRef, !reference.isEmpty {
            switch await OnePassword.read(reference: reference) {
            case .success(let secret):
                tokenSource = .onePassword(reference: reference)
                return secret
            case .failure(let error):
                // Fall through to the Keychain rather than hard-failing: `op` may simply not be
                // unlocked yet, and the user should still be able to work.
                ChronoLog.app.warning("1Password lookup failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        if let stored = keychain.value(for: .jiraAPIToken, qualifier: settings.accountEmail) {
            tokenSource = .keychain
            return stored
        }
        tokenSource = .none
        return nil
    }

    /// Confirms the credentials work, and reports *why* not if they do not.
    public func verify() async {
        guard let client else {
            state = .unconfigured
            return
        }
        state = .connecting
        do {
            let account = try await client.currentUser()
            user = account
            state = .connected(account)
            ChronoLog.jira.info("Connected to Jira as \(account.displayName, privacy: .public)")
        } catch let error as JiraError {
            switch error.failureKind {
            case .authentication:
                state = .unauthorized(error.errorDescription ?? "Jira rejected the credentials.")
            default:
                state = .offline(error.errorDescription ?? "Jira is unreachable.")
            }
        } catch {
            state = .offline(error.localizedDescription)
        }
    }

    // MARK: - Saving

    /// Validates and stores a new set of credentials.
    ///
    /// The token is only written to the Keychain *after* Jira has accepted it, so a typo never
    /// replaces a working token with a broken one.
    public func connect(
        site: String,
        email: String,
        token: String,
        settings: inout Settings
    ) async -> Result<JiraUser, JiraError> {
        guard let credentials = JiraCredentials(rawSite: site, email: email, apiToken: token) else {
            return .failure(.transport("Please fill in the site, your email and an API token."))
        }

        state = .connecting
        let candidate = JiraClient(credentials: credentials)
        do {
            let account = try await candidate.currentUser()
            try? keychain.set(token, for: .jiraAPIToken, qualifier: credentials.email)

            settings.siteURL = credentials.siteURL.absoluteString
            settings.accountEmail = credentials.email
            settings.onePasswordTokenRef = nil

            client = candidate
            user = account
            tokenSource = .keychain
            state = .connected(account)
            return .success(account)
        } catch let error as JiraError {
            state = error.failureKind == .authentication
                ? .unauthorized(error.errorDescription ?? "Rejected")
                : .offline(error.errorDescription ?? "Unreachable")
            return .failure(error)
        } catch {
            state = .offline(error.localizedDescription)
            return .failure(.transport(error.localizedDescription))
        }
    }

    /// Points the connection at a 1Password reference instead of a stored token.
    public func useOnePassword(
        reference: String,
        site: String,
        email: String,
        settings: inout Settings
    ) async -> Result<JiraUser, JiraError> {
        switch await OnePassword.read(reference: reference) {
        case .failure(let error):
            state = .unauthorized(error.localizedDescription)
            return .failure(.transport(error.localizedDescription))
        case .success(let token):
            var working = settings
            let result = await connect(site: site, email: email, token: token, settings: &working)
            if case .success = result {
                // Keep the reference as the source of truth and drop the copied token.
                working.onePasswordTokenRef = reference
                try? keychain.remove(.jiraAPIToken, qualifier: working.accountEmail)
                tokenSource = .onePassword(reference: reference)
            }
            settings = working
            return result
        }
    }

    public func disconnect(settings: inout Settings) {
        try? keychain.remove(.jiraAPIToken, qualifier: settings.accountEmail)
        settings.siteURL = ""
        settings.accountEmail = ""
        settings.onePasswordTokenRef = nil
        client = nil
        user = nil
        tokenSource = .none
        state = .unconfigured
    }

    /// Deep link to an issue in the browser.
    public func issueURL(key: String) -> URL? {
        guard let client else { return nil }
        return client.credentials.siteURL.appendingPathComponent("browse/\(key)")
    }
}
