import Foundation
import CryptoKit

/// Authentication for remote commands, shared by both transports.
///
/// The threat is modest but real: BLE advertisements are visible to anyone in the room, and the
/// LAN web remote is reachable by anything on the office Wi-Fi. Neither should let a passer-by
/// stop your timer. So a command is only obeyed if it carries an HMAC-SHA256 signature proving
/// knowledge of the pairing secret, which is transferred once by QR code and never sent over
/// the wire afterwards.
///
/// Replay is blocked two ways at once, because either alone has a gap:
/// * a **monotonic counter**, which stops replay within a session, but resets when the Mac
///   restarts;
/// * a **timestamp freshness window**, which stops replay of a captured packet later, and
///   covers exactly the restart case the counter does not.
public enum RemoteAuth {

    /// How far a command's timestamp may be from ours. Generous enough for a phone whose clock
    /// drifts, tight enough that a captured packet is useless by the time it is replayed.
    public static let freshnessWindow: TimeInterval = 120

    /// Derives the HMAC key from the printable pairing secret.
    static func key(from secret: String) -> SymmetricKey {
        SymmetricKey(data: SHA256.hash(data: Data(secret.utf8)))
    }

    /// The exact bytes that get signed. Both sides must build this identically, so it is
    /// defined in one place and documented: `counter.timestamp.payload`.
    static func signingInput(counter: UInt64, timestamp: Int64, payload: Data) -> Data {
        var data = Data("\(counter).\(timestamp).".utf8)
        data.append(payload)
        return data
    }

    public static func sign(payload: Data, counter: UInt64, timestamp: Int64, secret: String) -> Data {
        let mac = HMAC<SHA256>.authenticationCode(
            for: signingInput(counter: counter, timestamp: timestamp, payload: payload),
            using: key(from: secret)
        )
        return Data(mac)
    }

    /// Verifies a signature in constant time.
    public static func isValid(
        payload: Data,
        counter: UInt64,
        timestamp: Int64,
        mac: Data,
        secret: String
    ) -> Bool {
        HMAC<SHA256>.isValidAuthenticationCode(
            mac,
            authenticating: signingInput(counter: counter, timestamp: timestamp, payload: payload),
            using: key(from: secret)
        )
    }
}

/// A signed command as it travels over either transport.
public struct SignedEnvelope: Codable, Sendable {
    /// Monotonic per-device counter.
    public var counter: UInt64
    /// Unix seconds, for the freshness check.
    public var timestamp: Int64
    /// The JSON-encoded `RemoteCommand`.
    public var payload: Data
    public var mac: Data
    /// Stable id for the phone, so counters are tracked per device rather than globally.
    public var deviceID: String

    enum CodingKeys: String, CodingKey {
        case counter = "n"
        case timestamp = "t"
        case payload = "p"
        case mac = "m"
        case deviceID = "d"
    }

    public init(counter: UInt64, timestamp: Int64, payload: Data, mac: Data, deviceID: String) {
        self.counter = counter
        self.timestamp = timestamp
        self.payload = payload
        self.mac = mac
        self.deviceID = deviceID
    }

    /// Builds a signed envelope around a command.
    public static func make(
        command: RemoteCommand,
        counter: UInt64,
        deviceID: String,
        secret: String,
        now: Date = Date()
    ) throws -> SignedEnvelope {
        let payload = try JSONEncoder().encode(command)
        let timestamp = Int64(now.timeIntervalSince1970)
        return SignedEnvelope(
            counter: counter,
            timestamp: timestamp,
            payload: payload,
            mac: RemoteAuth.sign(payload: payload, counter: counter, timestamp: timestamp, secret: secret),
            deviceID: deviceID
        )
    }
}

/// Validates envelopes and remembers counters per device.
///
/// An actor because both transports feed into it concurrently, and the counter check is only
/// meaningful if it is serialised.
public actor RemoteCommandVerifier {
    public enum Rejection: Error, Equatable, Sendable {
        case notPaired
        case badSignature
        case stale(driftSeconds: Int)
        case replayed(counter: UInt64, lastSeen: UInt64)
        case malformed

        public var userFacingReason: String {
            switch self {
            case .notPaired: return "This device is not paired."
            case .badSignature: return "The command signature did not match."
            case .stale(let drift): return "The command was \(drift)s out of date."
            case .replayed: return "That command was already used."
            case .malformed: return "The command could not be read."
            }
        }
    }

    private var secret: String?
    private var lastCounters: [String: UInt64] = [:]
    private let clock: any Clock

    public init(secret: String?, clock: any Clock = SystemClock()) {
        self.secret = secret
        self.clock = clock
    }

    public func updateSecret(_ newValue: String?) {
        secret = newValue
        // Rotating the secret unpairs every device, so old counters are meaningless.
        lastCounters.removeAll()
    }

    /// Verifies an envelope and returns the command it carries.
    public func verify(_ envelope: SignedEnvelope) throws -> RemoteCommand {
        guard let secret, !secret.isEmpty else { throw Rejection.notPaired }

        let drift = abs(Double(envelope.timestamp) - clock.now.timeIntervalSince1970)
        guard drift <= RemoteAuth.freshnessWindow else {
            throw Rejection.stale(driftSeconds: Int(drift))
        }

        guard RemoteAuth.isValid(
            payload: envelope.payload,
            counter: envelope.counter,
            timestamp: envelope.timestamp,
            mac: envelope.mac,
            secret: secret
        ) else { throw Rejection.badSignature }

        // Signature checked before the counter, so an attacker cannot burn counter values.
        if let last = lastCounters[envelope.deviceID], envelope.counter <= last {
            throw Rejection.replayed(counter: envelope.counter, lastSeen: last)
        }
        lastCounters[envelope.deviceID] = envelope.counter

        guard let command = try? JSONDecoder().decode(RemoteCommand.self, from: envelope.payload) else {
            throw Rejection.malformed
        }
        return command
    }

    /// Verifies a signed request that carries no command — the web remote's state read.
    ///
    /// A `GET` has no body, so the signed payload is the request path. Reading what someone is
    /// working on is no less private than changing it, so it is authenticated identically.
    public func verifySignatureOnly(
        payload: Data,
        counter: UInt64,
        timestamp: Int64,
        mac: Data,
        deviceID: String
    ) throws {
        guard let secret, !secret.isEmpty else { throw Rejection.notPaired }

        let drift = abs(Double(timestamp) - clock.now.timeIntervalSince1970)
        guard drift <= RemoteAuth.freshnessWindow else {
            throw Rejection.stale(driftSeconds: Int(drift))
        }
        guard RemoteAuth.isValid(
            payload: payload, counter: counter, timestamp: timestamp, mac: mac, secret: secret
        ) else { throw Rejection.badSignature }

        if let last = lastCounters[deviceID], counter <= last {
            throw Rejection.replayed(counter: counter, lastSeen: last)
        }
        lastCounters[deviceID] = counter
    }

    /// Verifies a web-remote request, where the signed payload is the raw HTTP body and the
    /// signature travels in headers.
    public func verifyRequest(
        body: Data,
        counter: UInt64,
        timestamp: Int64,
        mac: Data,
        deviceID: String
    ) throws -> RemoteCommand {
        try verify(
            SignedEnvelope(counter: counter, timestamp: timestamp, payload: body, mac: mac, deviceID: deviceID)
        )
    }

    public func knownDeviceCount() -> Int { lastCounters.count }
}

/// The payload encoded into the pairing QR code.
public struct PairingPayload: Codable, Sendable, Equatable {
    /// Everything the phone needs to reach the Mac over the LAN.
    public var host: String
    public var port: Int
    public var secret: String
    public var deviceName: String
    public var version: Int

    public init(host: String, port: Int, secret: String, deviceName: String, version: Int = ChronoRemote.protocolVersion) {
        self.host = host
        self.port = port
        self.secret = secret
        self.deviceName = deviceName
        self.version = version
    }

    /// The URL put in the QR code.
    ///
    /// The secret lives in the URL **fragment**, which browsers never send to the server. So
    /// even though the LAN remote is plain HTTP, the secret itself is not transmitted — it is
    /// read by the page's own JavaScript and kept in local storage.
    public func pairingURL() -> URL? {
        var components = URLComponents()
        components.scheme = "http"
        components.host = host
        components.port = port
        components.path = "/"
        components.fragment = "s=\(secret)&n=\(deviceName.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "Mac")&v=\(version)"
        return components.url
    }
}
