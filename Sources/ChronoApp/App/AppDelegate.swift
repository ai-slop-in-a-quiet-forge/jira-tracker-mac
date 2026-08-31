import AppKit
import SwiftUI
import ChronoCore

/// Application lifecycle for a menu bar app.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var environment: AppEnvironment?
    private var statusItem: StatusItemController?
    private var hotkeys: HotkeyManager?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Accessory: no Dock icon, no menu bar menus of its own. Chrono lives in the status bar.
        NSApp.setActivationPolicy(.accessory)

        let environment = AppEnvironment()
        self.environment = environment
        environment.bootstrap()

        statusItem = StatusItemController(environment: environment)
        installHotkeys(environment: environment)

        // Only show onboarding to someone genuinely new, not to anyone who has ever tracked
        // anything or connected Jira.
        if environment.needsOnboarding {
            WindowManager.shared.showOnboarding(environment: environment)
        }

        ChronoLog.app.info("Chrono launched")
    }

    private func installHotkeys(environment: AppEnvironment) {
        let manager = HotkeyManager()
        manager.apply(environment.engine.settings.hotkeys, handlers: [
            .togglePanel: { [weak self] in self?.statusItem?.togglePopover() },
            .startStop: { [weak environment] in
                guard let environment else { return }
                if environment.engine.status.isIdle {
                    environment.resumeLastTarget()
                } else {
                    environment.stop()
                }
            },
            .pauseResume: { [weak environment] in environment?.togglePauseResume() },
            .quickInterruption: { [weak environment] in environment?.start(adhoc: .interruption) },
        ])
        hotkeys = manager
    }

    /// Closing the timesheet must not quit a menu bar app.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Clicking the app in Finder while it is already running should open the panel rather than
    /// do nothing.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        statusItem?.showPopover()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotkeys?.unregisterAll()
        environment?.shutdown()
        ChronoLog.app.info("Chrono exited cleanly")
    }
}
