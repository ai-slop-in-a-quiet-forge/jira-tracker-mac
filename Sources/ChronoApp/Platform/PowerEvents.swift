import AppKit
import Foundation
import ChronoCore

/// Machine-level events that should stop the clock: sleep, screen lock, fast user switching
/// and shutdown.
///
/// These matter more than they sound. Closing the lid on a running timer is the single most
/// common way people end up logging fourteen hours to a ticket, and macOS gives us a clean
/// notification for it — as long as the write to disk happens *inside* the notification
/// handler, before the machine stops executing our code.
@MainActor
public final class PowerEvents {

    public enum Event: Sendable, Equatable {
        case willSleep
        case didWake
        case screenLocked
        case screenUnlocked
        case sessionResignedActive   // another user switched in
        case sessionBecameActive
        case willPowerOff
    }

    public var handler: ((Event) -> Void)?

    private var observers: [NSObjectProtocol] = []
    private var distributedObservers: [NSObjectProtocol] = []

    public init() {}

    public func start() {
        stop()

        let workspace = NSWorkspace.shared.notificationCenter
        observe(workspace, NSWorkspace.willSleepNotification, .willSleep)
        observe(workspace, NSWorkspace.didWakeNotification, .didWake)
        observe(workspace, NSWorkspace.willPowerOffNotification, .willPowerOff)
        observe(workspace, NSWorkspace.sessionDidResignActiveNotification, .sessionResignedActive)
        observe(workspace, NSWorkspace.sessionDidBecomeActiveNotification, .sessionBecameActive)

        // Screen lock has no NSWorkspace notification; it arrives on the distributed centre.
        // These names are long-standing and undocumented-but-stable; if they ever stop firing
        // the app degrades to idle detection rather than breaking.
        let distributed = DistributedNotificationCenter.default()
        observeDistributed(distributed, "com.apple.screenIsLocked", .screenLocked)
        observeDistributed(distributed, "com.apple.screenIsUnlocked", .screenUnlocked)
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name, _ event: Event) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.handler?(event) }
        }
        observers.append(token)
    }

    private func observeDistributed(_ center: DistributedNotificationCenter, _ rawName: String, _ event: Event) {
        let token = center.addObserver(
            forName: Notification.Name(rawName),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handler?(event) }
        }
        distributedObservers.append(token)
    }

    public func stop() {
        for token in observers { NSWorkspace.shared.notificationCenter.removeObserver(token) }
        for token in distributedObservers { DistributedNotificationCenter.default().removeObserver(token) }
        observers.removeAll()
        distributedObservers.removeAll()
    }

    deinit {
        // Observers are torn down explicitly by `stop()`; nothing to do here that is safe
        // to touch from a deinit.
    }
}
