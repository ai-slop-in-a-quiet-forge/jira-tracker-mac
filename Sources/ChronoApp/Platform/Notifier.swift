import AppKit
import Foundation
import UserNotifications
import ChronoCore

/// System notifications, used for the *informational* nudges.
///
/// Anything that needs an answer ("you're in a meeting — pause?") is shown in Chrono's own
/// floating panel instead, see `InterventionPresenter`. That split is deliberate: notification
/// permission can be denied, notifications can be silently swallowed by a Focus mode, and the
/// core promise of this app — warning you that the wrong thing is being tracked — must not
/// depend on a permission the user might refuse.
@MainActor
public final class Notifier: NSObject, UNUserNotificationCenterDelegate {

    public enum Response: Sendable, Equatable {
        case startLastTask
        case stopTimer
        case openTimesheet
        case openPanel
        case snooze(minutes: Int)
        case dismissed
    }

    public var handler: ((Response) -> Void)?
    public private(set) var authorizationDenied = false

    /// `UNUserNotificationCenter` traps when there is no bundle identifier, which is the case
    /// when the binary is run directly out of `.build` during development. Guarding on this
    /// keeps `swift run` usable.
    private var isAvailable: Bool { Bundle.main.bundleIdentifier != nil }

    public enum Category: String {
        case nudge = "chrono.nudge"
        case forgot = "chrono.forgot"
        case info = "chrono.info"
    }

    public enum ActionID: String {
        case startLast = "chrono.action.startLast"
        case stop = "chrono.action.stop"
        case openTimesheet = "chrono.action.timesheet"
        case snooze = "chrono.action.snooze"
    }

    public func configure() {
        guard isAvailable else {
            ChronoLog.app.info("Notifications unavailable (unbundled build); using in-app panels only")
            return
        }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        registerCategories(on: center)

        center.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, error in
            if let error {
                ChronoLog.app.error("Notification authorization failed: \(error.localizedDescription, privacy: .public)")
            }
            Task { @MainActor in self?.authorizationDenied = !granted }
        }
    }

    private func registerCategories(on center: UNUserNotificationCenter) {
        let stop = UNNotificationAction(
            identifier: ActionID.stop.rawValue,
            title: "Stop timer",
            options: []
        )
        let timesheet = UNNotificationAction(
            identifier: ActionID.openTimesheet.rawValue,
            title: "Review my day",
            options: [.foreground]
        )
        let snooze = UNNotificationAction(
            identifier: ActionID.snooze.rawValue,
            title: "Not now",
            options: []
        )
        let startLast = UNNotificationAction(
            identifier: ActionID.startLast.rawValue,
            title: "Start last task",
            options: []
        )

        center.setNotificationCategories([
            UNNotificationCategory(
                identifier: Category.nudge.rawValue,
                actions: [stop, timesheet, snooze],
                intentIdentifiers: []
            ),
            UNNotificationCategory(
                identifier: Category.forgot.rawValue,
                actions: [startLast, snooze],
                intentIdentifiers: []
            ),
            UNNotificationCategory(
                identifier: Category.info.rawValue,
                actions: [timesheet],
                intentIdentifiers: []
            ),
        ])
    }

    // MARK: - Sending

    /// Fire-and-forget informational notification.
    public func post(title: String, body: String, category: Category = .info, sound: Bool = false) {
        guard isAvailable, !authorizationDenied else { return }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.categoryIdentifier = category.rawValue
        if sound { content.sound = .default }

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil   // deliver immediately
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                ChronoLog.app.error("Could not post notification: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    public func postNudge(target: TrackingTarget, elapsed: TimeInterval) {
        post(
            title: "Still on \(target.shortLabel)?",
            body: "\(DurationFormat.humane(elapsed)) so far today. Tap to stop or review.",
            category: .nudge
        )
    }

    public func postForgotToStart(activeSeconds: TimeInterval) {
        post(
            title: "Nothing is being tracked",
            body: "You've been working for \(DurationFormat.humane(activeSeconds)) with no timer running.",
            category: .forgot
        )
    }

    public func postBreakReminder(continuousSeconds: TimeInterval) {
        post(
            title: "You've been at it a while",
            body: "\(DurationFormat.humane(continuousSeconds)) without a break.",
            category: .info
        )
    }

    public func postPausedTooLong(target: TrackingTarget, seconds: TimeInterval) {
        post(
            title: "\(target.shortLabel) is still paused",
            body: "Paused \(DurationFormat.humane(seconds)) ago. Resume it, or stop and log what you have.",
            category: .nudge
        )
    }

    public func postSyncFailure(_ message: String) {
        post(title: "Couldn't reach Jira", body: message, category: .info)
    }

    public func postSubmitted(seconds: Int, issueCount: Int) {
        let what = issueCount == 1 ? "1 issue" : "\(issueCount) issues"
        post(
            title: "Logged to Jira",
            body: "\(DurationFormat.humane(Double(seconds))) across \(what).",
            category: .info
        )
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// Show our notifications even when Chrono is the active app.
    ///
    /// `nonisolated` because `UNUserNotificationCenterDelegate` makes no actor guarantees;
    /// anything touching Chrono's state hops to the main actor explicitly below.
    public nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list])
    }

    public nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let mapped: Response
        switch ActionID(rawValue: response.actionIdentifier) {
        case .startLast: mapped = .startLastTask
        case .stop: mapped = .stopTimer
        case .openTimesheet: mapped = .openTimesheet
        case .snooze: mapped = .snooze(minutes: 30)
        case .none:
            // Tapping the body of the notification opens the panel.
            mapped = response.actionIdentifier == UNNotificationDefaultActionIdentifier
                ? .openPanel
                : .dismissed
        }

        Task { @MainActor in
            self.handler?(mapped)
            completionHandler()
        }
    }
}
