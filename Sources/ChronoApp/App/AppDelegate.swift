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

        // Must happen before any window opens. An accessory app has no menu bar of its own,
        // and without a main menu AppKit has nowhere to route the standard editing key
        // equivalents — so Cmd-V silently does nothing in every text field in the app.
        installMainMenu()

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

    /// Installs a minimal main menu.
    ///
    /// Chrono is `LSUIElement`, so this menu is never *displayed* — an accessory app does not
    /// own the system menu bar. It still has to exist: `NSApplication` resolves key equivalents
    /// through `mainMenu`, so without it Cut, Copy, Paste, Select All and Undo do not work
    /// anywhere in the app. That is a genuinely baffling bug to hit as a user, and the fix is
    /// nothing more than the menu below.
    private func installMainMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(
            withTitle: "Settings…",
            action: #selector(openSettings),
            keyEquivalent: ","
        ).target = self
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: "Hide Chrono",
            action: #selector(NSApplication.hide(_:)),
            keyEquivalent: "h"
        )
        appMenu.addItem(
            withTitle: "Close Window",
            action: #selector(NSWindow.performClose(_:)),
            keyEquivalent: "w"
        )
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: "Quit Chrono",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        // Undo and redo are not on a public selector, hence the string selectors; this is the
        // standard way to build an Edit menu in code.
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(
            withTitle: "Select All",
            action: #selector(NSText.selectAll(_:)),
            keyEquivalent: "a"
        )
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        NSApp.mainMenu = mainMenu
    }

    @objc private func openSettings() {
        guard let environment else { return }
        WindowManager.shared.showSettings(environment: environment)
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
        manager.onUnavailableChange = { [weak environment] actions in
            environment?.recordUnavailableHotkeys(actions)
        }
        // The first pass ran inside `apply` before the callback existed.
        environment.recordUnavailableHotkeys(manager.unavailable)
        environment.hotkeys = manager
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
