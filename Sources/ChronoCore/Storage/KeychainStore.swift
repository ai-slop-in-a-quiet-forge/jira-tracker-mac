import Foundation
import Security

/// Keychain-backed storage for the two secrets Chrono holds: the Jira API token and the
/// pairing secret shared with the phone remote.
///
/// Nothing sensitive goes into `state.json` or `settings.json`. Items are created with
/// `kSecAttrAccessibleAfterFirstUnlock` so that a timer can keep syncing after a reboot the
/// user has logged into, without the secret being readable while the machine is locked cold.
public struct KeychainStore: Sendable {
    public let service: String

    public init(service: String = "in.chrono.tracker") {
        self.service = service
    }

    public enum Key: String, Sendable {
        /// Jira API token, keyed per account email by `account(for:)`.
        case jiraAPIToken = "jira-api-token"
        /// Shared secret the phone remote proves knowledge of.
        case remotePairingSecret = "remote-pairing-secret"
    }

    public enum KeychainError: Error, LocalizedError {
        case unexpectedStatus(OSStatus)
        case dataCorrupt

        public var errorDescription: String? {
            switch self {
            case .unexpectedStatus(let status):
                let detail = SecCopyErrorMessageString(status, nil) as String? ?? "status \(status)"
                return "Keychain error: \(detail)"
            case .dataCorrupt:
                return "The stored value could not be read."
            }
        }
    }

    /// Namespaces the token by account, so switching Jira accounts does not clobber the old
    /// token (and switching back does not require re-entering it).
    private func account(for key: Key, qualifier: String?) -> String {
        guard let qualifier, !qualifier.isEmpty else { return key.rawValue }
        return "\(key.rawValue)|\(qualifier.lowercased())"
    }

    private func baseQuery(_ key: Key, qualifier: String?) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(for: key, qualifier: qualifier),
        ]
    }

    // MARK: - Read / write

    public func set(_ value: String, for key: Key, qualifier: String? = nil) throws {
        guard !value.isEmpty else { try remove(key, qualifier: qualifier); return }
        let data = Data(value.utf8)
        var query = baseQuery(key, qualifier: qualifier)

        // Try an update first; fall back to adding. This ordering avoids the delete-then-add
        // race that briefly leaves the app with no stored token at all.
        let attributes: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else { throw KeychainError.unexpectedStatus(updateStatus) }

        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let addStatus = SecItemAdd(query as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw KeychainError.unexpectedStatus(addStatus) }
    }

    public func get(_ key: Key, qualifier: String? = nil) throws -> String? {
        var query = baseQuery(key, qualifier: qualifier)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
        guard let data = item as? Data, let text = String(data: data, encoding: .utf8) else {
            throw KeychainError.dataCorrupt
        }
        return text
    }

    public func remove(_ key: Key, qualifier: String? = nil) throws {
        let status = SecItemDelete(baseQuery(key, qualifier: qualifier) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    /// Non-throwing read, for the many places that simply want "the token, if we have one".
    public func value(for key: Key, qualifier: String? = nil) -> String? {
        try? get(key, qualifier: qualifier)
    }

    /// Fetches the pairing secret, generating and storing one on first use.
    public func remotePairingSecret() -> String {
        if let existing = value(for: .remotePairingSecret), !existing.isEmpty { return existing }
        let secret = Self.randomSecret()
        try? set(secret, for: .remotePairingSecret)
        return secret
    }

    /// Replaces the pairing secret, which invalidates every already-paired device.
    @discardableResult
    public func rotateRemotePairingSecret() -> String {
        let secret = Self.randomSecret()
        try? set(secret, for: .remotePairingSecret)
        return secret
    }

    /// 32 bytes of cryptographic randomness, base64url encoded.
    static func randomSecret(byteCount: Int = 32) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes)
        if status != errSecSuccess {
            // SecRandomCopyBytes essentially cannot fail, but never silently fall back to a
            // weak source for something that gates remote control of the timer.
            bytes = (0..<byteCount).map { _ in UInt8.random(in: .min ... .max) }
        }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
