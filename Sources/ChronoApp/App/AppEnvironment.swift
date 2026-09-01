import AppKit
import Foundation
import Observation
import ChronoCore

/// The composition root: builds every collaborator, wires them together, and exposes the small
/// set of verbs the UI actually calls.
///
/// Views talk only to this object. That keeps SwiftUI code free of policy decisions — a button
/// says `environment.togglePauseResume()` rather than reaching into the engine, the sync queue
/// and the sensors itself.
@MainActor
@Observable
public final class AppEnvironment {

    // MARK: - Collaborators

    public let engine: TrackingEngine
    public let keychain: KeychainStore
    public let connection: JiraConnection
    public let issues: IssueService
    public let notifier: Notifier
    public let activity: ActivityMonitor
    public let sync: SyncCoordinator
    /// Optional, off by default. See `RemoteCoordinator`.
    let remote: RemoteCoordinator
    /// Set by `AppDelegate`, which owns the manager and builds its handlers. Held here so
    /// Settings can re-register a changed shortcut without a relaunch.
    weak var hotkeys: HotkeyManager?

    // MARK: - UI state

    /// An intervention awaiting the user's answer, shown in the floating panel.
    public private(set) var pendingIntervention: Intervention?
    /// Transient banner text shown at the top of the panel ("Logged 2h 15m to CYM-12").
    public private(set) var flash: Flash?
    /// Shortcuts the window server refused, usually because another app owns the combination.
    /// Mirrored from `HotkeyManager` because that type cannot be `@Observable`.
    private(set) var unavailableHotkeys: Set<HotkeyAction> = []
    /// True while the first-run flow has not been completed.
    public var needsOnboarding: Bool {
        connection.state == .unconfigured && engine.state.segments.isEmpty
    }

    public struct Flash: Equatable, Identifiable {
        public enum Kind: Equatable { case success, warning, failure, info }
        public let id = UUID()
        public let kind: Kind
        public let message: String
    }

    /// Remembers what was being tracked before an automatic switch, so "back to work" can put
    /// it back exactly as it was.
    private var targetBeforeMeeting: TrackingTarget?
    /// Set when Chrono (not the user) paused the timer, so unlocking can offer to resume.
    private var autoPausedReason: PauseReason?

    private var tickTimer: Timer?

    // MARK: - Init

    public init() {
        let store: StateStore
        do {
            store = try StateStore.standard()
        } catch {
            // Application Support being unwritable is fatal for a tracker whose whole job is
            // remembering things, but crashing is a terrible way to say so. Fall back to a
            // temporary directory and let the UI report it.
            ChronoLog.error("Falling back to a temporary store: \(error.localizedDescription)")
            let fallback = FileStore(
                directory: URL(fileURLWithPath: NSTemporaryDirectory())
                    .appendingPathComponent("Chrono", isDirectory: true)
            )
            try? fallback.ensureDirectoryExists()
            store = StateStore(fileStore: fallback)
        }

        let keychain = KeychainStore()
        let engine = TrackingEngine(store: store)
        let connection = JiraConnection(keychain: keychain)

        self.keychain = keychain
        self.engine = engine
        self.connection = connection
        self.issues = IssueService(connection: connection)
        self.notifier = Notifier()
        self.activity = ActivityMonitor()
        self.sync = SyncCoordinator(engine: engine, connection: connection)
        self.remote = RemoteCoordinator(keychain: keychain)

        // The coordinator needs to call back into the environment to execute commands; the
        // reference is weak on its side, since the environment owns it.
        self.remote.environment = self
    }

    // MARK: - Bootstrap

    public func bootstrap() {
        wireEngine()
        wireActivity()
        wireNotifier()
        wireSync()

        notifier.configure()
        activity.start()
        sync.start()
        remote.applySettings(engine.settings)
        startTicking()

        Task { await connectToJira() }
    }

    public func shutdown() {
        tickTimer?.invalidate()
        tickTimer = nil
        activity.stop()
        sync.stop()
        remote.stop()
        // Pausing on quit is the honest default: the app is about to stop counting anyway, and
        // leaving a segment open would look like a crash on next launch.
        if engine.isRunning { engine.pause(reason: .shutdown) }
        engine.flush()
    }

    private func wireEngine() {
        engine.eventHandler = { [weak self] event in
            self?.handle(engineEvent: event)
        }
    }

    private func wireActivity() {
        activity.settingsProvider = { [weak self] in self?.engine.settings ?? Settings() }
        activity.contextProvider = { [weak self] in
            guard let self else { return InterventionContext(status: .idle) }
            return InterventionContext(
                status: self.engine.status,
                continuousWorkSeconds: self.engine.currentSegmentElapsed,
                unfiledSeconds: self.engine.unfiledSecondsToday,
                unsettledSeconds: self.engine.unsettledSeconds,
                pendingDraftCount: self.sync.pendingCount
            )
        }
        activity.onIntervention = { [weak self] intervention in
            self?.handle(intervention: intervention)
        }
        activity.onPowerEvent = { [weak self] event in
            self?.handle(powerEvent: event)
        }
    }

    private func wireNotifier() {
        notifier.handler = { [weak self] response in
            guard let self else { return }
            switch response {
            case .startLastTask: self.resumeLastTarget()
            case .stopTimer: self.stop()
            case .openTimesheet: WindowManager.shared.showTimesheet(environment: self)
            case .openPanel: NotificationCenter.default.post(name: .chronoShowPanel, object: nil)
            case .snooze(let minutes): self.activity.snooze(minutes: minutes)
            case .dismissed: break
            }
        }
    }

    private func wireSync() {
        sync.onSubmitted = { [weak self] seconds, issueCount in
            guard let self else { return }
            let what = issueCount == 1 ? "1 issue" : "\(issueCount) issues"
            self.show(.init(kind: .success, message: "Logged \(DurationFormat.humane(Double(seconds))) to \(what)."))
        }
        sync.onFailure = { [weak self] message in
            self?.notifier.postSyncFailure(message)
            self?.show(.init(kind: .failure, message: message))
        }
    }

    /// One timer for the whole app, driving the menu bar title and any open views.
    ///
    /// Ticking only while something is running matters: an idle Chrono should cost nothing, and
    /// a per-second timer that never sleeps is exactly the kind of thing that shows up in
    /// Activity Monitor's energy tab.
    private func startTicking() {
        tickTimer?.invalidate()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard self.engine.isRunning || WindowManager.shared.hasVisibleWindow else { return }
                self.engine.tick()
            }
        }
        timer.tolerance = 0.2
        RunLoop.main.add(timer, forMode: .common)
        tickTimer = timer
    }

    // MARK: - Jira

    public func connectToJira() async {
        await connection.load(settings: engine.settings)
        if let account = connection.user {
            // Guard against two Jira accounts sharing one history file.
            if !engine.bind(accountID: account.accountId) {
                show(.init(
                    kind: .warning,
                    message: "This history was recorded under a different Jira account."
                ))
            }
        }
        await issues.loadFilter(engine.settings.savedFilters.first)
    }

    // MARK: - Tracking verbs

    public func start(issue: IssueRef, source: SegmentSource = .manual) {
        engine.start(.issue(issue), source: source)
        refreshIssueMetadata(for: issue)
    }

    public func start(adhoc category: AdhocCategory, source: SegmentSource = .manual) {
        // If the user configured a Jira issue for meetings, prefer it — logged time beats
        // unfiled time.
        if category == .meeting || category == .call {
            let key = engine.settings.meetingIssueKey.trimmingCharacters(in: .whitespaces)
            if !key.isEmpty {
                engine.start(.issue(IssueRef(key: key, summary: category.defaultLabel)), source: source)
                return
            }
        }
        engine.start(.adhoc(.quick(category)), source: source)
    }

    public func togglePauseResume() {
        if engine.isRunning {
            engine.pause(reason: .user)
            autoPausedReason = nil
        } else if engine.isPaused {
            engine.resume()
        }
    }

    public func stop() {
        _ = engine.stop()
        autoPausedReason = nil
        sync.syncIfNeeded()
    }

    /// Resumes whatever was last tracked — the phone remote's and the notification's
    /// "get back to it" action.
    public func resumeLastTarget() {
        if engine.isPaused {
            engine.resume(source: .remote)
            return
        }
        guard engine.status.isIdle else { return }
        if let recent = engine.state.recentIssues.first {
            engine.start(.issue(recent), source: .remote)
        } else if let adhoc = engine.state.savedAdhocTargets.first {
            engine.start(.adhoc(adhoc), source: .remote)
        }
    }

    /// Switches to the meeting bucket, remembering what to come back to.
    public func switchToMeeting(source: SegmentSource = .automatic) {
        targetBeforeMeeting = engine.activeTarget
        start(adhoc: engine.settings.meetingBucket, source: source)
    }

    /// Returns to whatever was being tracked before a meeting switch.
    public func returnFromMeeting() {
        guard let previous = targetBeforeMeeting else { return }
        targetBeforeMeeting = nil
        engine.start(previous, source: .automatic)
    }

    public var canReturnFromMeeting: Bool { targetBeforeMeeting != nil }

    private func refreshIssueMetadata(for issue: IssueRef) {
        // Summary and status may be stale in the cache; refresh quietly in the background.
        guard let client = connection.client, issue.summary.isEmpty || issue.fetchedAt == nil else { return }
        Task { [weak self] in
            guard let fresh = try? await client.issue(key: issue.key) else { return }
            self?.engine.refreshCachedIssue(fresh)
        }
    }

    // MARK: - Engine events

    private func handle(engineEvent event: EngineEvent) {
        // Anything that changes what is being tracked should reach a paired phone at once,
        // rather than waiting for its next poll.
        remote.publish()

        switch event {
        case .draftsEnqueued:
            sync.syncIfNeeded()
        case .stopped:
            sync.syncIfNeeded()
        case .recoveryNeeded:
            // Surfaced by the panel rather than a notification: it needs a considered answer,
            // and the app has just launched anyway.
            WindowManager.shared.showRecovery(environment: self)
        case .adhocReassigned(let count, let issue):
            show(.init(
                kind: .success,
                message: "Moved \(count == 1 ? "1 entry" : "\(count) entries") to \(issue.key)."
            ))
        default:
            break
        }
    }

    // MARK: - Interventions

    private func handle(intervention: Intervention) {
        switch intervention {
        case .none:
            break

        case .idleDetected(_, let seconds):
            // Honour a pre-decided preference without interrupting.
            switch engine.settings.idleDefaultAction {
            case .ask:
                pendingIntervention = intervention
                InterventionPresenter.shared.present(intervention, environment: self)
            case .keep:
                engine.resolveIdle(.keep, idleSeconds: seconds)
            case .discard:
                engine.resolveIdle(.discard, idleSeconds: seconds)
                show(.init(kind: .info, message: "Trimmed \(DurationFormat.humane(seconds)) of idle time."))
            case .discardAndPause:
                engine.resolveIdle(.discardAndPause, idleSeconds: seconds)
                autoPausedReason = .idle
                show(.init(kind: .info, message: "Paused after \(DurationFormat.humane(seconds)) idle."))
            }

        case .meetingDetected(_, let signal, _):
            switch engine.settings.meetingDefaultAction {
            case .ask:
                pendingIntervention = intervention
                InterventionPresenter.shared.present(intervention, environment: self)
            case .switchToMeeting:
                switchToMeeting()
                show(.init(kind: .info, message: "Switched to \(engine.settings.meetingBucket.shortLabel) — \(signal.appName)."))
            case .pause:
                engine.pause(reason: .meeting)
                autoPausedReason = .meeting
                show(.init(kind: .info, message: "Paused for \(signal.appName)."))
            case .ignore:
                break
            }

        case .runawaySession, .endOfDayReview:
            pendingIntervention = intervention
            InterventionPresenter.shared.present(intervention, environment: self)

        case .stillTracking(let target, let elapsed):
            notifier.postNudge(target: target, elapsed: elapsed)

        case .forgotToStart(let activeSeconds):
            notifier.postForgotToStart(activeSeconds: activeSeconds)

        case .pausedTooLong(let target, let seconds):
            notifier.postPausedTooLong(target: target, seconds: seconds)

        case .takeABreak(let continuousSeconds):
            notifier.postBreakReminder(continuousSeconds: continuousSeconds)
        }
    }

    /// Called by the intervention panel once the user answers.
    public func resolve(intervention: Intervention, with choice: InterventionChoice) {
        pendingIntervention = nil
        InterventionPresenter.shared.dismiss()

        switch (intervention, choice) {
        case (.idleDetected(_, let seconds), .idleKeep):
            engine.resolveIdle(.keep, idleSeconds: seconds)
        case (.idleDetected(_, let seconds), .idleDiscard):
            engine.resolveIdle(.discard, idleSeconds: seconds)
        case (.idleDetected(_, let seconds), .idleDiscardAndPause):
            engine.resolveIdle(.discardAndPause, idleSeconds: seconds)
            autoPausedReason = .idle
        case (.idleDetected(_, let seconds), .idleDiscardAndStop):
            engine.resolveIdle(.discardAndStop, idleSeconds: seconds)
            sync.syncIfNeeded()

        case (.meetingDetected, .meetingSwitch):
            switchToMeeting()
        case (.meetingDetected, .meetingPause):
            engine.pause(reason: .meeting)
            autoPausedReason = .meeting
        case (.meetingDetected, .meetingKeep):
            break

        case (.runawaySession, .stopAndLog):
            stop()
        case (.runawaySession, .keepGoing):
            break

        case (.endOfDayReview, .openTimesheet):
            WindowManager.shared.showTimesheet(environment: self)

        case (_, .snooze(let minutes)):
            activity.snooze(minutes: minutes)

        default:
            break
        }
        activity.resetIdleCooldown()
    }

    // MARK: - Power events

    private func handle(powerEvent event: PowerEvents.Event) {
        switch event {
        case .willSleep:
            guard engine.settings.autoPauseOnSleep, engine.isRunning else {
                engine.flush()
                return
            }
            engine.pause(reason: .systemSleep)
            autoPausedReason = .systemSleep

        case .screenLocked, .sessionResignedActive:
            guard engine.settings.autoPauseOnScreenLock, engine.isRunning else { return }
            engine.pause(reason: .screenLock)
            autoPausedReason = .screenLock

        case .didWake, .screenUnlocked, .sessionBecameActive:
            // Deliberately does *not* auto-resume. Waking the Mac is not the same as going back
            // to the task, and silently resuming would log time you did not work. Offer it.
            guard let reason = autoPausedReason, engine.isPaused, let target = engine.activeTarget else { return }
            autoPausedReason = nil
            notifier.post(
                title: "\(target.shortLabel) is paused",
                body: "Chrono \(reason.humanReason). Resume it?",
                category: .forgot
            )

        case .willPowerOff:
            if engine.isRunning { engine.pause(reason: .shutdown) }
            engine.flush()
        }
    }

    // MARK: - Flash messages

    public func show(_ flash: Flash) {
        self.flash = flash
        // Auto-clear, so a stale success banner does not sit in the panel forever.
        let id = flash.id
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            if self?.flash?.id == id { self?.flash = nil }
        }
    }

    public func dismissFlash() {
        flash = nil
    }

    // MARK: - Settings passthrough

    public func mutateSettings(_ transform: (inout Settings) -> Void) {
        engine.mutateSettings(transform)
    }

    /// Changes a shortcut and re-registers straight away.
    ///
    /// Persisting without re-registering would leave Settings showing one combination while the
    /// window server still answers the old one — the shortcut would appear simply not to work
    /// until the next launch.
    func updateHotkeys(_ transform: (inout HotkeySet) -> Void) {
        mutateSettings { transform(&$0.hotkeys) }
        hotkeys?.reapply(engine.settings.hotkeys)
    }

    func recordUnavailableHotkeys(_ actions: Set<HotkeyAction>) {
        unavailableHotkeys = actions
    }
}

/// The answers the intervention panel can produce.
public enum InterventionChoice: Equatable, Sendable {
    case idleKeep
    case idleDiscard
    case idleDiscardAndPause
    case idleDiscardAndStop
    case meetingSwitch
    case meetingPause
    case meetingKeep
    case stopAndLog
    case keepGoing
    case openTimesheet
    case snooze(minutes: Int)
}

public extension Notification.Name {
    /// Posted when something outside the menu bar wants the panel opened.
    static let chronoShowPanel = Notification.Name("in.chrono.showPanel")
}
