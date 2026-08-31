import Foundation
import Security

/// Holds the pairing secret and the monotonic command counter.
///
/// The secret lives in the Keychain rather than `UserDefaults`, because it is the only thing
/// standing between a stranger on the same floor and your timer. The counter lives in
/// `UserDefaults` — losing it is harmless (the Mac also enforces a timestamp freshness window),
/// and keeping it out of the Keychain avoids a write on every single command.
@MainActor
@Observable
final class PairingStore {

    private static let service = "in.chrono.remote"
    private static let account = "pairing-secret"
    private static let counterKey = "chrono.counter"
    private static let deviceKey = "chrono.deviceID"
    private static let nameKey = "chrono.macName"

    private(set) var isPaired: Bool = false
    private(set) var macName: String = "Mac"

    init() {
        isPaired = secret != nil
        macName = UserDefaults.standard.string(forKey: Self.nameKey) ?? "Mac"
    }

    // MARK: - Secret

    var secret: String? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
        ]
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func store(secret: String, macName: String?) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
        ]
        // Replace wholesale: pairing again should discard the old Mac entirely.
        SecItemDelete(base as CFDictionary)

        var attributes = base
        attributes[kSecValueData as String] = Data(secret.utf8)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(attributes as CFDictionary, nil)

        if let macName, !macName.isEmpty {
            UserDefaults.standard.set(macName, forKey: Self.nameKey)
            self.macName = macName
        }
        // A fresh pairing restarts the counter; the Mac forgot the old one too.
        UserDefaults.standard.set(0, forKey: Self.counterKey)
        isPaired = true
    }

    func unpair() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
        ]
        SecItemDelete(query as CFDictionary)
        UserDefaults.standard.removeObject(forKey: Self.counterKey)
        UserDefaults.standard.removeObject(forKey: Self.nameKey)
        isPaired = false
        macName = "Mac"
    }

    // MARK: - Counter and device identity

    func nextCounter() -> UInt64 {
        let next = UInt64(UserDefaults.standard.integer(forKey: Self.counterKey)) + 1
        UserDefaults.standard.set(Int(next), forKey: Self.counterKey)
        return next
    }

    /// Stable per-install identifier, so the Mac tracks counters per device.
    var deviceID: String {
        if let existing = UserDefaults.standard.string(forKey: Self.deviceKey) { return existing }
        let generated = "ios-" + UUID().uuidString.prefix(12)
        UserDefaults.standard.set(generated, forKey: Self.deviceKey)
        return String(generated)
    }

    // MARK: - QR payload

    /// Extracts the secret from a scanned pairing URL.
    ///
    /// The Mac puts it in the fragment (so browsers never transmit it), which means parsing the
    /// fragment rather than the query.
    static func parse(pairingURL raw: String) -> (secret: String, name: String?)? {
        guard let url = URL(string: raw), let fragment = url.fragment else { return nil }
        var secret: String?
        var name: String?
        for pair in fragment.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            switch parts[0] {
            case "s": secret = String(parts[1])
            case "n": name = String(parts[1]).removingPercentEncoding
            default: break
            }
        }
        guard let secret, !secret.isEmpty else { return nil }
        return (secret, name)
    }
}
