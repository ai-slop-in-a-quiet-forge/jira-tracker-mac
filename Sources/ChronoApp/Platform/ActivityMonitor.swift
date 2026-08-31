import AppKit
import Foundation
import Observation
import ChronoCore

/// Polls the sensors, feeds `InterventionPolicy`, and reports what should happen.
///
/// The monitor deliberately makes no decisions of its own — it assembles an `ActivitySnapshot`,
/// asks the (pure, tested) policy what to do, and hands the answer to its delegate closures.
/// Everything about *when to interrupt the user* therefore lives in code that runs in
/// milliseconds under test rather than in a timer callback.
@MainActor
@Observable
public final class ActivityMonitor {

    /// How often the sensors are read. Three seconds is frequent enough to catch a call
    /// starting, and cheap enough to be invisible: the whole sweep is a few property reads.
    public static let pollInterval: TimeInterval = 3

    public private(set) var snapshot: ActivitySnapshot
    public private(set) var memory = InterventionMemory()
    /// Exposed so Settings can show a live sensor readout — the honest way to let someone
    /// verify meeting detection actually works on their machine.
    public private(set) var lastPolledAt: Date?

    private let idleSensor = IdleSensor()
    private let mediaSensor = MediaSensor()
    private let appSensor = AppSensor()
    private let power = PowerEvents()
    private var timer: Timer?

    /// Supplied by `AppEnvironment` so the monitor never holds a reference back to it.
    public var contextProvider: (() -> InterventionContext)?
    public var settingsProvider: (() -> Settings)?

    public var onIntervention: ((Intervention) -> Void)?
    public var onPowerEvent: ((PowerEvents.Event) -> Void)?

    public init() {
        snapshot = ActivitySnapshot(timestamp: Date())
    }

    // MARK: - Lifecycle

    public func start() {
        power.handler = { [weak self] event in
            self?.onPowerEvent?(event)
            // Keep the snapshot consistent immediately, rather than up to three seconds late.
            switch event {
            case .willSleep: self?.snapshot.systemAsleep = true
            case .didWake: self?.snapshot.systemAsleep = false
            case .screenLocked: self?.snapshot.screenLocked = true
            case .screenUnlocked: self?.snapshot.screenLocked = false
            default: break
            }
        }
        power.start()

        timer?.invalidate()
        let timer = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        // A tolerance lets the OS coalesce our wake-ups with others, which measurably helps
        // battery life for a timer that runs all day.
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        poll()
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
        power.stop()
    }

    // MARK: - Polling

    public func poll() {
        guard let settingsProvider, let contextProvider else { return }
        let settings = settingsProvider()
        let now = Date()

        let frontmost = appSensor.frontmostApp()
        // Skip the media probes entirely when meeting detection is off — no reason to poll
        // CoreAudio and CoreMediaIO for a feature the user disabled.
        let detecting = settings.meetingDetectionEnabled
        let micLive = detecting && settings.detectViaMicrophone && mediaSensor.microphoneInUse()
        let cameraLive = detecting && settings.detectViaCamera && mediaSensor.cameraInUse()

        var next = ActivitySnapshot(
            timestamp: now,
            idleSeconds: idleSensor.idleSeconds(),
            screenLocked: snapshot.screenLocked,
            systemAsleep: snapshot.systemAsleep,
            microphoneInUse: micLive,
            cameraInUse: cameraLive,
            frontmostBundleID: frontmost.bundleID,
            frontmostAppName: frontmost.name,
            runningMeetingApps: detecting
                ? appSensor.runningMeetingApps(matching: settings.meetingAppBundleIDs)
                : [],
            browserRunning: detecting ? appSensor.browserRunning() : false,
            // macOS exposes no supported API for reading a Focus mode, so Chrono relies on its
            // own snooze instead of pretending to know.
            focusModeActive: false
        )
        next.screenLocked = snapshot.screenLocked
        snapshot = next
        lastPolledAt = now

        let intervention = InterventionPolicy.evaluate(
            snapshot: next,
            context: contextProvider(),
            settings: settings,
            memory: &memory
        )
        if !intervention.isNone { onIntervention?(intervention) }
    }

    // MARK: - Snooze

    public func snooze(minutes: Int) {
        memory.snooze(until: Date().addingTimeInterval(Double(minutes) * 60))
    }

    public var snoozedUntil: Date? {
        guard let until = memory.suppressedUntil, until > Date() else { return nil }
        return until
    }

    public func cancelSnooze() {
        memory.suppressedUntil = nil
    }

    /// Forces the next idle prompt to be allowed again — used after the user answers one, so
    /// a *new* absence prompts promptly instead of waiting out the cooldown.
    public func resetIdleCooldown() {
        memory.lastIdlePromptAt = nil
    }

    /// A human-readable dump of the current sensor state, for the diagnostics panel.
    public func diagnostics() -> [(label: String, value: String)] {
        [
            ("Idle for", DurationFormat.humane(snapshot.idleSeconds)),
            ("Microphone", snapshot.microphoneInUse ? "In use" : "Idle"),
            ("Camera", snapshot.cameraInUse ? "In use" : "Idle"),
            ("Frontmost app", snapshot.frontmostAppName ?? "Unknown"),
            ("Meeting apps running", snapshot.runningMeetingApps.isEmpty
                ? "None"
                : snapshot.runningMeetingApps
                    .map(MeetingAppCatalog.displayName(forBundleID:))
                    .sorted()
                    .joined(separator: ", ")),
            ("Screen", snapshot.screenLocked ? "Locked" : "Unlocked"),
            ("Meeting verdict", {
                guard let settings = settingsProvider?(),
                      let signal = snapshot.meetingSignal(settings: settings)
                else { return "Not in a meeting" }
                return "\(signal.appName) — \(signal.reason)"
            }()),
        ]
    }
}
