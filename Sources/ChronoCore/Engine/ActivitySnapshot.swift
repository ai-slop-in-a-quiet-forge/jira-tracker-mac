import Foundation

/// A reading of everything the platform sensors can tell us at one instant.
///
/// The macOS layer fills this in; ChronoCore only ever reasons about it. That separation is
/// what lets the meeting-detection rules be unit-tested without a microphone, and is also the
/// seam a Windows port would reimplement.
public struct ActivitySnapshot: Sendable, Equatable {
    public var timestamp: Date
    /// Seconds since the last keyboard or mouse event, system-wide.
    public var idleSeconds: TimeInterval
    public var screenLocked: Bool
    /// True between a sleep notification and the matching wake.
    public var systemAsleep: Bool
    /// Some process is recording audio input right now.
    public var microphoneInUse: Bool
    public var cameraInUse: Bool
    public var frontmostBundleID: String?
    public var frontmostAppName: String?
    /// Known meeting apps that are currently running (not necessarily frontmost).
    public var runningMeetingApps: Set<String>
    /// A browser is running, which makes an in-browser meeting plausible.
    public var browserRunning: Bool
    /// True while the user has Do Not Disturb / a Focus mode on, which Chrono treats as
    /// "don't interrupt me" for its own nudges too.
    public var focusModeActive: Bool

    public init(
        timestamp: Date,
        idleSeconds: TimeInterval = 0,
        screenLocked: Bool = false,
        systemAsleep: Bool = false,
        microphoneInUse: Bool = false,
        cameraInUse: Bool = false,
        frontmostBundleID: String? = nil,
        frontmostAppName: String? = nil,
        runningMeetingApps: Set<String> = [],
        browserRunning: Bool = false,
        focusModeActive: Bool = false
    ) {
        self.timestamp = timestamp
        self.idleSeconds = idleSeconds
        self.screenLocked = screenLocked
        self.systemAsleep = systemAsleep
        self.microphoneInUse = microphoneInUse
        self.cameraInUse = cameraInUse
        self.frontmostBundleID = frontmostBundleID
        self.frontmostAppName = frontmostAppName
        self.runningMeetingApps = runningMeetingApps
        self.browserRunning = browserRunning
        self.focusModeActive = focusModeActive
    }

    /// The user is demonstrably at the keyboard.
    public var isUserActive: Bool { idleSeconds < 60 && !screenLocked && !systemAsleep }
}

/// A judgement about whether the user is in a call, and why.
public struct MeetingSignal: Sendable, Equatable {
    public enum Confidence: Int, Sendable, Comparable {
        /// A meeting app is merely frontmost.
        case weak = 1
        /// Audio or video capture is live and a meeting app is running.
        case strong = 2
        /// Both microphone and camera are live — you are unambiguously on a call.
        case certain = 3

        public static func < (lhs: Confidence, rhs: Confidence) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    public let confidence: Confidence
    /// Human-readable app name for the warning text ("You're in Microsoft Teams…").
    public let appName: String
    public let reason: String

    public init(confidence: Confidence, appName: String, reason: String) {
        self.confidence = confidence
        self.appName = appName
        self.reason = reason
    }
}

public extension ActivitySnapshot {
    /// Decides whether this snapshot looks like a meeting.
    ///
    /// The rules are tuned to avoid false positives, because an app that cries "are you in a
    /// meeting?" while you are listening to music gets muted within a day:
    ///
    /// * mic **and** camera live → certain, whatever is running;
    /// * mic or camera live **and** a known meeting app (or a browser) is running → strong;
    /// * a known meeting app merely frontmost → weak, and only if the user opted in.
    ///
    /// Microphone activity on its own is explicitly *not* enough: dictation, Voice Memos and
    /// a dozen menu bar utilities hold the input device open.
    func meetingSignal(settings: Settings) -> MeetingSignal? {
        guard settings.meetingDetectionEnabled, !screenLocked, !systemAsleep else { return nil }

        let micLive = settings.detectViaMicrophone && microphoneInUse
        let cameraLive = settings.detectViaCamera && cameraInUse
        let knownApps = Set(settings.meetingAppBundleIDs)
        let runningKnown = runningMeetingApps.intersection(knownApps)
        let frontmostIsMeetingApp = frontmostBundleID.map { knownApps.contains($0) } ?? false

        // Name the app we are most confident about, for the warning copy.
        let namedApp: String = {
            if frontmostIsMeetingApp, let id = frontmostBundleID {
                return MeetingAppCatalog.displayName(forBundleID: id)
            }
            if let first = runningKnown.sorted().first {
                return MeetingAppCatalog.displayName(forBundleID: first)
            }
            return frontmostAppName ?? "a call"
        }()

        if micLive && cameraLive {
            return MeetingSignal(
                confidence: .certain,
                appName: namedApp,
                reason: "your microphone and camera are both live"
            )
        }
        if micLive || cameraLive {
            guard !runningKnown.isEmpty || browserRunning else { return nil }
            return MeetingSignal(
                confidence: .strong,
                appName: namedApp,
                reason: micLive ? "your microphone is live" : "your camera is live"
            )
        }
        if settings.detectViaFrontmostApp && frontmostIsMeetingApp {
            return MeetingSignal(
                confidence: .weak,
                appName: namedApp,
                reason: "\(namedApp) is in the foreground"
            )
        }
        return nil
    }
}
