import Foundation

/// Every tunable in one Codable value.
///
/// Kept as a single struct (rather than scattered `UserDefaults` reads) so that settings can
/// be diffed, exported, unit-tested and round-tripped to the phone remote. Defaults are
/// chosen to be useful on first launch without any configuration.
public struct Settings: Codable, Sendable, Equatable {

    // MARK: - Jira connection

    /// e.g. `https://your-company.atlassian.net`
    public var siteURL: String = ""
    public var accountEmail: String = ""
    /// Optional 1Password secret reference (`op://Vault/Item/field`). When set, Chrono reads
    /// the API token through the `op` CLI at launch instead of storing it in the Keychain.
    public var onePasswordTokenRef: String? = nil
    /// The issue list shown when the panel opens with an empty search box.
    public var defaultJQL: String = "assignee = currentUser() AND resolution = Unresolved ORDER BY updated DESC"
    /// Extra saved filters the user can flip between.
    public var savedFilters: [SavedFilter] = SavedFilter.defaults

    // MARK: - Worklog submission

    /// Round each worklog to a multiple of this many minutes. `0` disables rounding.
    /// Defaults to 1 minute because Jira itself stores whole minutes.
    public var roundingMinutes: Int = 1
    public var roundingMode: RoundingMode = .nearest
    /// Sessions shorter than this are never pushed to Jira — stops a mis-click from
    /// littering issues with 4-second worklogs.
    public var minimumLoggableSeconds: Int = 60
    public var submitStrategy: SubmitStrategy = .onStop
    /// Whether logging time should eat into the issue's remaining estimate. Jira's own default
    /// is to reduce it, which surprises people, so it is surfaced here.
    public var adjustEstimate: EstimateAdjustment = .auto
    /// Attach the session note as the Jira worklog comment.
    public var includeNoteAsComment: Bool = true
    /// Appended to every worklog comment so worklogs are traceable back to this app.
    public var commentSignature: String = ""

    // MARK: - Idle / away handling

    /// No keyboard or mouse for this long counts as idle.
    public var idleThresholdSeconds: Int = 300
    public var autoPauseOnIdle: Bool = true
    public var idleDefaultAction: IdleAction = .ask
    public var autoPauseOnScreenLock: Bool = true
    public var autoPauseOnSleep: Bool = true
    /// After a pause this long, treat the session as finished rather than resumable.
    public var abandonPausedAfterMinutes: Int = 240

    // MARK: - Meeting & call detection

    public var meetingDetectionEnabled: Bool = true
    /// Microphone-in-use is by far the strongest signal that you are actually *in* a call,
    /// as opposed to merely having Teams open.
    public var detectViaMicrophone: Bool = true
    public var detectViaCamera: Bool = true
    /// Weaker signal, off by default: the meeting app merely being frontmost.
    public var detectViaFrontmostApp: Bool = false
    public var meetingAppBundleIDs: [String] = MeetingAppCatalog.defaultBundleIDs
    /// Ignore blips shorter than this — a two-second mic activation is a notification sound,
    /// not a meeting.
    public var meetingGraceSeconds: Int = 45
    public var meetingDefaultAction: MeetingAction = .ask
    /// When auto-switching, the bucket ad-hoc meeting time lands in.
    public var meetingBucket: AdhocCategory = .meeting
    /// A Jira issue that meeting time is logged against, if the team has one
    /// (e.g. a recurring "Ceremonies" ticket). Empty means keep it ad-hoc.
    public var meetingIssueKey: String = ""

    // MARK: - Nudges

    /// "Still on CYM-123?" while a timer runs.
    public var nudgeEnabled: Bool = true
    public var nudgeIntervalMinutes: Int = 45
    /// "You're clearly working but nothing is tracking."
    public var forgotToStartNudgeEnabled: Bool = true
    public var forgotToStartAfterMinutes: Int = 10
    /// Warn when one session has run implausibly long — usually a timer left on overnight.
    public var runawaySessionHours: Double = 5
    public var breakReminderEnabled: Bool = false
    public var breakReminderAfterMinutes: Int = 90

    // MARK: - The working day

    public var dailyTargetHours: Double = 8
    /// ISO weekday numbers (1 = Sunday … 7 = Saturday), matching `Calendar.component(.weekday:)`.
    public var workdays: Set<Int> = [2, 3, 4, 5, 6]
    /// Used for the "unlogged time" review prompt at the end of the day.
    public var endOfDayReviewHour: Int = 18
    public var endOfDayReviewEnabled: Bool = true

    // MARK: - Phone remote
    //
    // Both default to OFF. The phone remote is a bonus, not a dependency: the Mac app is
    // fully functional with neither enabled, and Chrono should not advertise over Bluetooth
    // or open a listening socket until the user has explicitly asked it to.

    public var bluetoothRemoteEnabled: Bool = false
    public var webRemoteEnabled: Bool = false
    /// 0 asks the OS for any free port, which avoids clashing with whatever else is running.
    public var webRemotePort: Int = 0
    /// Require a confirmation on the Mac before a remote can stop (as opposed to pause) a timer.
    public var remoteConfirmDestructiveActions: Bool = false

    // MARK: - Appearance & behaviour

    public var launchAtLogin: Bool = true
    public var showSecondsInMenuBar: Bool = false
    public var menuBarShowsLabel: Bool = true
    /// Cap on menu bar label length, so a long issue summary cannot eat the whole bar.
    public var menuBarLabelMaxLength: Int = 18
    public var playSoundOnStateChange: Bool = false
    public var hotkeys: HotkeySet = .defaults

    public init() {}
}

// MARK: - Supporting types

public enum RoundingMode: String, Codable, Sendable, CaseIterable {
    case nearest, up, down

    public var title: String {
        switch self {
        case .nearest: return "Nearest"
        case .up: return "Round up"
        case .down: return "Round down"
        }
    }
}

public enum SubmitStrategy: String, Codable, Sendable, CaseIterable {
    /// Push the worklog to Jira as soon as the timer stops.
    case onStop
    /// Batch everything and push at end of day, after a review.
    case endOfDay
    /// Never push automatically; the user submits from the timesheet.
    case manual

    public var title: String {
        switch self {
        case .onStop: return "When I stop the timer"
        case .endOfDay: return "End of day, after review"
        case .manual: return "Only when I click submit"
        }
    }
}

public enum IdleAction: String, Codable, Sendable, CaseIterable {
    /// Show a prompt and let the user decide (default — least surprising).
    case ask
    /// Silently drop the idle time and keep the timer running.
    case discard
    /// Keep the idle time as work (for people who think at a whiteboard).
    case keep
    /// Drop the idle time and pause.
    case discardAndPause

    public var title: String {
        switch self {
        case .ask: return "Ask me"
        case .discard: return "Discard idle time, keep running"
        case .keep: return "Count it as work"
        case .discardAndPause: return "Discard it and pause"
        }
    }
}

public enum MeetingAction: String, Codable, Sendable, CaseIterable {
    case ask
    /// Auto-switch to the meeting bucket and switch back afterwards.
    case switchToMeeting
    case pause
    case ignore

    public var title: String {
        switch self {
        case .ask: return "Warn me and ask"
        case .switchToMeeting: return "Switch to my meeting bucket"
        case .pause: return "Pause the timer"
        case .ignore: return "Do nothing"
        }
    }
}

public struct SavedFilter: Codable, Sendable, Equatable, Identifiable, Hashable {
    public var id: UUID
    public var name: String
    public var jql: String
    public var symbolName: String

    public init(id: UUID = UUID(), name: String, jql: String, symbolName: String = "line.3.horizontal.decrease.circle") {
        self.id = id
        self.name = name
        self.jql = jql
        self.symbolName = symbolName
    }

    public static let defaults: [SavedFilter] = [
        SavedFilter(
            name: "My open issues",
            jql: "assignee = currentUser() AND resolution = Unresolved ORDER BY updated DESC",
            symbolName: "person.crop.circle"
        ),
        SavedFilter(
            name: "In progress",
            jql: "assignee = currentUser() AND statusCategory = \"In Progress\" ORDER BY updated DESC",
            symbolName: "play.circle"
        ),
        SavedFilter(
            name: "Recently viewed",
            jql: "issuekey IN issueHistory() ORDER BY lastViewed DESC",
            symbolName: "clock.arrow.circlepath"
        ),
        SavedFilter(
            name: "Current sprint",
            jql: "assignee = currentUser() AND sprint IN openSprints() ORDER BY rank ASC",
            symbolName: "figure.run"
        ),
        SavedFilter(
            name: "Reported by me",
            jql: "reporter = currentUser() AND resolution = Unresolved ORDER BY created DESC",
            symbolName: "square.and.pencil"
        ),
    ]
}

/// Bundle identifiers for the apps that mean "you are probably in a call".
public enum MeetingAppCatalog {
    public static let defaultBundleIDs: [String] = [
        "com.microsoft.teams",          // Teams classic
        "com.microsoft.teams2",         // Teams (new)
        "us.zoom.xos",                  // Zoom
        "com.google.Chrome",            // Meet in Chrome — only meaningful with mic/camera signal
        "com.cisco.webexmeetingsapp",
        "com.webex.meetingmanager",
        "com.tinyspeck.slackmacgap",    // Slack huddles
        "com.skype.skype",
        "com.apple.FaceTime",
        "com.discordapp.Discord",
        "com.ringcentral.RingCentral",
        "com.gotomeeting.GoToMeeting",
        "com.bluejeansnet.Blue",
        "com.microsoft.SkypeForBusiness",
    ]

    /// Human-friendly name for a bundle id, for use in warnings ("You're in Zoom…").
    public static func displayName(forBundleID id: String) -> String {
        switch id {
        case "com.microsoft.teams", "com.microsoft.teams2": return "Microsoft Teams"
        case "us.zoom.xos": return "Zoom"
        case "com.cisco.webexmeetingsapp", "com.webex.meetingmanager": return "Webex"
        case "com.tinyspeck.slackmacgap": return "Slack"
        case "com.apple.FaceTime": return "FaceTime"
        case "com.google.Chrome": return "Chrome"
        default:
            return id.split(separator: ".").last.map(String.init)?.capitalized ?? id
        }
    }
}

/// A global hotkey, stored as a Carbon-style key code plus modifier mask so it survives
/// keyboard-layout changes.
public struct Hotkey: Codable, Sendable, Equatable, Hashable {
    public var keyCode: UInt32
    public var modifiers: UInt32
    public var enabled: Bool

    public init(keyCode: UInt32, modifiers: UInt32, enabled: Bool = true) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.enabled = enabled
    }
}

public struct HotkeySet: Codable, Sendable, Equatable {
    public var togglePanel: Hotkey?
    public var startStop: Hotkey?
    public var pauseResume: Hotkey?
    public var quickInterruption: Hotkey?

    public init(
        togglePanel: Hotkey? = nil,
        startStop: Hotkey? = nil,
        pauseResume: Hotkey? = nil,
        quickInterruption: Hotkey? = nil
    ) {
        self.togglePanel = togglePanel
        self.startStop = startStop
        self.pauseResume = pauseResume
        self.quickInterruption = quickInterruption
    }

    /// Control-Option-… by default: unlikely to collide with app shortcuts, and reachable
    /// with one hand.
    public static let defaults = HotkeySet(
        togglePanel: Hotkey(keyCode: KeyCodes.t, modifiers: Modifiers.controlOption),
        startStop: Hotkey(keyCode: KeyCodes.s, modifiers: Modifiers.controlOption),
        pauseResume: Hotkey(keyCode: KeyCodes.p, modifiers: Modifiers.controlOption),
        quickInterruption: Hotkey(keyCode: KeyCodes.i, modifiers: Modifiers.controlOption)
    )
}

/// The handful of Carbon virtual key codes the defaults need, named so the defaults read clearly.
public enum KeyCodes {
    public static let s: UInt32 = 1
    public static let t: UInt32 = 17
    public static let p: UInt32 = 35
    public static let i: UInt32 = 34
}

public enum Modifiers {
    // Carbon modifier masks (cmdKey/optionKey/controlKey/shiftKey).
    public static let command: UInt32 = 0x0100
    public static let shift: UInt32 = 0x0200
    public static let option: UInt32 = 0x0800
    public static let control: UInt32 = 0x1000
    public static let controlOption: UInt32 = control | option
    public static let commandShift: UInt32 = command | shift
}
