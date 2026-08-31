import Foundation

/// The wire contract between the Mac and the phone.
///
/// One protocol serves both transports — Bluetooth LE and the LAN web remote — so the iOS app
/// and the browser remote cannot drift apart, and so a new transport (Watch app, anyone?) only
/// has to move bytes.
///
/// BLE is the constraint that shapes everything here: a default ATT payload is 20 bytes and a
/// negotiated one is typically 185. So the snapshot uses single-character keys and integer
/// seconds, which keeps a full state update comfortably inside one notification instead of
/// needing a chunking layer.
public enum ChronoRemote {
    /// Bumped when the wire format changes incompatibly. The phone checks this before
    /// trusting anything else and tells the user to update rather than misbehaving.
    public static let protocolVersion = 1

    public enum BLE {
        /// A 128-bit custom service; fixed for the life of the product.
        public static let serviceUUID = "CF19620C-714C-466A-9CA6-B00A8ADE3510"
        /// Read + notify: the current `RemoteSnapshot`.
        public static let stateCharacteristicUUID = "78F5D285-868A-4D01-A960-47DA2122DC83"
        /// Write: a `SignedEnvelope` wrapping a `RemoteCommand`.
        public static let commandCharacteristicUUID = "03F8929E-84AD-4D63-9E86-9B923EA65FEC"
        /// Read: `RemoteInfo` — protocol version and device name, readable before pairing so
        /// the phone can show "Abhishek's MacBook Pro" in a picker.
        public static let infoCharacteristicUUID = "FCA9CF6B-E44F-45A3-9A1D-E163FA3581CE"

        /// Advertised local name prefix, so the phone can filter the neighbourhood quickly.
        public static let advertisedNamePrefix = "Chrono"
    }
}

// MARK: - State

/// What the phone displays. Keys are terse to fit a BLE notification.
public struct RemoteSnapshot: Codable, Sendable, Equatable {
    public var status: RemoteStatus
    /// Short label — the issue key, or the ad-hoc bucket name.
    public var label: String
    /// Seconds on the current segment.
    public var elapsed: Int
    /// Seconds of work logged today.
    public var todaySeconds: Int
    /// The daily target in seconds, so the phone can draw a progress ring.
    public var targetSeconds: Int
    /// Worklogs waiting to reach Jira.
    public var pendingDrafts: Int
    /// Seconds tracked today with no Jira issue attached yet.
    public var unfiledSeconds: Int
    /// True when the Mac believes you are in a meeting — the phone shows this prominently,
    /// because it is exactly the moment you want to hit pause.
    public var inMeeting: Bool
    /// Monotonic counter; the phone ignores snapshots older than the newest it has seen, which
    /// makes out-of-order BLE notifications harmless.
    public var revision: Int

    enum CodingKeys: String, CodingKey {
        case status = "s"
        case label = "l"
        case elapsed = "e"
        case todaySeconds = "d"
        case targetSeconds = "t"
        case pendingDrafts = "q"
        case unfiledSeconds = "u"
        case inMeeting = "m"
        case revision = "r"
    }

    public init(
        status: RemoteStatus,
        label: String,
        elapsed: Int,
        todaySeconds: Int,
        targetSeconds: Int,
        pendingDrafts: Int = 0,
        unfiledSeconds: Int = 0,
        inMeeting: Bool = false,
        revision: Int = 0
    ) {
        self.status = status
        // Hard cap: a long issue summary must never be the reason a BLE packet needs chunking.
        self.label = String(label.prefix(40))
        self.elapsed = elapsed
        self.todaySeconds = todaySeconds
        self.targetSeconds = targetSeconds
        self.pendingDrafts = pendingDrafts
        self.unfiledSeconds = unfiledSeconds
        self.inMeeting = inMeeting
        self.revision = revision
    }

    public static let disconnected = RemoteSnapshot(
        status: .idle, label: "", elapsed: 0, todaySeconds: 0, targetSeconds: 8 * 3600
    )
}

public enum RemoteStatus: Int, Codable, Sendable {
    case idle = 0
    case running = 1
    case paused = 2
}

/// Readable without authentication, so a phone can identify a Mac before pairing. Contains
/// nothing sensitive.
public struct RemoteInfo: Codable, Sendable, Equatable {
    public var version: Int
    public var deviceName: String
    /// True once a pairing secret exists, i.e. the Mac is ready to accept commands.
    public var paired: Bool

    enum CodingKeys: String, CodingKey {
        case version = "v"
        case deviceName = "n"
        case paired = "p"
    }

    public init(version: Int = ChronoRemote.protocolVersion, deviceName: String, paired: Bool) {
        self.version = version
        self.deviceName = String(deviceName.prefix(40))
        self.paired = paired
    }
}

// MARK: - Commands

/// Everything the phone is allowed to ask the Mac to do.
///
/// Deliberately a small, safe surface. The phone can pause, resume, stop, switch to a meeting
/// bucket and snooze reminders — the things you need when you have walked away from your desk.
/// It cannot reconfigure Jira, delete history, or submit arbitrary worklogs.
public enum RemoteCommand: Codable, Sendable, Equatable {
    case pause
    case resume
    case stop
    /// Start (or resume) the most recent target — the "get back to it" button.
    case resumeLast
    /// Switch to the configured meeting bucket, keeping the previous task for later.
    case switchToMeeting
    /// Start a specific issue by key, chosen from the recents the phone was sent.
    case startIssue(String)
    /// Silence reminders for a number of minutes.
    case snooze(minutes: Int)
    /// Ask for a fresh snapshot.
    case refresh
    /// Attach a note to the running segment, dictated on the phone.
    case note(String)

    enum CodingKeys: String, CodingKey {
        case kind = "c"
        case value = "v"
    }

    private enum Kind: String, Codable {
        case pause, resume, stop, resumeLast, switchToMeeting, startIssue, snooze, refresh, note
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)
        switch kind {
        case .pause: self = .pause
        case .resume: self = .resume
        case .stop: self = .stop
        case .resumeLast: self = .resumeLast
        case .switchToMeeting: self = .switchToMeeting
        case .refresh: self = .refresh
        case .startIssue:
            self = .startIssue(try container.decode(String.self, forKey: .value))
        case .snooze:
            self = .snooze(minutes: try container.decode(Int.self, forKey: .value))
        case .note:
            self = .note(try container.decode(String.self, forKey: .value))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .pause: try container.encode(Kind.pause, forKey: .kind)
        case .resume: try container.encode(Kind.resume, forKey: .kind)
        case .stop: try container.encode(Kind.stop, forKey: .kind)
        case .resumeLast: try container.encode(Kind.resumeLast, forKey: .kind)
        case .switchToMeeting: try container.encode(Kind.switchToMeeting, forKey: .kind)
        case .refresh: try container.encode(Kind.refresh, forKey: .kind)
        case .startIssue(let key):
            try container.encode(Kind.startIssue, forKey: .kind)
            try container.encode(key, forKey: .value)
        case .snooze(let minutes):
            try container.encode(Kind.snooze, forKey: .kind)
            try container.encode(minutes, forKey: .value)
        case .note(let text):
            try container.encode(Kind.note, forKey: .kind)
            try container.encode(String(text.prefix(200)), forKey: .value)
        }
    }

    /// Commands that end a session rather than merely suspending it. These can be gated behind
    /// a confirmation on the Mac.
    public var isDestructive: Bool {
        if case .stop = self { return true }
        return false
    }

    public var auditDescription: String {
        switch self {
        case .pause: return "pause"
        case .resume: return "resume"
        case .stop: return "stop"
        case .resumeLast: return "resume last task"
        case .switchToMeeting: return "switch to meeting"
        case .startIssue(let key): return "start \(key)"
        case .snooze(let minutes): return "snooze \(minutes)m"
        case .refresh: return "refresh"
        case .note: return "set note"
        }
    }
}

/// A short list of issues the phone can offer, sent alongside the snapshot over the web remote
/// (BLE keeps it out of band to stay small).
public struct RemoteIssueOption: Codable, Sendable, Equatable {
    public var key: String
    public var summary: String

    public init(key: String, summary: String) {
        self.key = key
        self.summary = String(summary.prefix(80))
    }
}

/// The reply to a command.
public struct RemoteCommandResult: Codable, Sendable, Equatable {
    public var accepted: Bool
    public var message: String
    public var snapshot: RemoteSnapshot?

    public init(accepted: Bool, message: String, snapshot: RemoteSnapshot? = nil) {
        self.accepted = accepted
        self.message = message
        self.snapshot = snapshot
    }
}
