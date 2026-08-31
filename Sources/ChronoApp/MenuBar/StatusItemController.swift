import AppKit
import SwiftUI
import Observation
import ChronoCore

/// Owns the menu bar item and the popover.
///
/// The title is the app's most-seen surface, so it is treated carefully: monospaced digits so
/// it does not jitter, hours-and-minutes rather than seconds by default so its width is stable,
/// and a hard cap on the label so a long issue summary cannot push everything else off the bar.
@MainActor
final class StatusItemController {

    private let environment: AppEnvironment
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private var observationTask: Task<Void, Never>?
    /// Cached so the icon and title are only rewritten when they actually change.
    private var lastRenderedTitle: String?
    private var lastRenderedStatusKind: String?

    init(environment: AppEnvironment) {
        self.environment = environment
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        configureButton()
        configurePopover()
        startObserving()

        NotificationCenter.default.addObserver(
            forName: .chronoShowPanel,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.showPopover() }
        }
    }

    // MARK: - Setup

    private func configureButton() {
        guard let button = statusItem.button else { return }
        button.imagePosition = .imageLeading
        button.target = self
        button.action = #selector(handleClick)
        // Ask for both so a right-click can open the menu instead of the popover.
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.toolTip = "Chrono"
        render(force: true)
    }

    private func configurePopover() {
        popover.behavior = .transient   // closes when the user clicks elsewhere
        popover.animates = true
        popover.contentSize = NSSize(width: Theme.panelWidth, height: 560)
        popover.contentViewController = NSHostingController(
            rootView: PanelView().environment(environment)
        )
    }

    /// Re-renders whenever any observable the render path reads changes.
    ///
    /// `withObservationTracking` fires once per change, so it is re-armed each time. This is
    /// cheaper and more accurate than polling the engine on a timer.
    private func startObserving() {
        observationTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let stream = AsyncStream<Void> { continuation in
                    withObservationTracking {
                        _ = self.environment.engine.status
                        _ = self.environment.engine.now
                        _ = self.environment.engine.settings.menuBarShowsLabel
                        _ = self.environment.engine.settings.showSecondsInMenuBar
                    } onChange: {
                        continuation.yield()
                        continuation.finish()
                    }
                }
                for await _ in stream { break }
                self.render()
            }
        }
    }

    // MARK: - Rendering

    func render(force: Bool = false) {
        guard let button = statusItem.button else { return }
        let engine = environment.engine
        let status = engine.status

        let kind: String
        switch status {
        case .idle: kind = "idle"
        case .running: kind = "running"
        case .paused: kind = "paused"
        }

        if force || kind != lastRenderedStatusKind {
            button.image = TrayIcon.image(for: status)
            lastRenderedStatusKind = kind
        }

        let title = menuBarTitle(engine: engine, status: status)
        guard force || title != lastRenderedTitle else { return }
        lastRenderedTitle = title

        if title.isEmpty {
            button.attributedTitle = NSAttributedString(string: "")
            return
        }

        button.attributedTitle = NSAttributedString(
            string: " " + title,
            attributes: [
                // Monospaced digits are the difference between a calm menu bar and one that
                // twitches every second.
                .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular),
            ]
        )
        button.toolTip = tooltip(status: status)
    }

    private func menuBarTitle(engine: TrackingEngine, status: TrackingStatus) -> String {
        let settings = engine.settings

        switch status {
        case .idle:
            // Nothing running: show nothing. A permanent "0:00" is just noise.
            return ""

        case .running(let target, _):
            let elapsed = settings.showSecondsInMenuBar
                ? DurationFormat.clock(engine.currentSegmentElapsed)
                : DurationFormat.compact(engine.currentSegmentElapsed)
            guard settings.menuBarShowsLabel else { return elapsed }
            return "\(trim(target.shortLabel, to: settings.menuBarLabelMaxLength)) \(elapsed)"

        case .paused(let target, _):
            let total = DurationFormat.compact(engine.activeTargetTodayElapsed)
            guard settings.menuBarShowsLabel else { return "|| \(total)" }
            return "\(trim(target.shortLabel, to: settings.menuBarLabelMaxLength)) || \(total)"
        }
    }

    private func trim(_ text: String, to limit: Int) -> String {
        guard text.count > limit, limit > 1 else { return text }
        return String(text.prefix(limit - 1)) + "…"
    }

    private func tooltip(status: TrackingStatus) -> String {
        switch status {
        case .idle:
            return "Chrono — not tracking"
        case .running(let target, _):
            return "Tracking \(target.displayLabel)"
        case .paused(let target, _):
            return "Paused — \(target.displayLabel)"
        }
    }

    // MARK: - Interaction

    @objc private func handleClick() {
        guard let event = NSApp.currentEvent else { showPopover(); return }

        // Right-click or control-click opens a menu of the actions worth having without
        // opening the whole panel.
        if event.type == .rightMouseUp || event.modifierFlags.contains(.control) {
            showContextMenu()
        } else {
            togglePopover()
        }
    }

    func togglePopover() {
        popover.isShown ? popover.performClose(nil) : showPopover()
    }

    func showPopover() {
        guard let button = statusItem.button else { return }
        environment.engine.tick()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        // A transient popover needs the app frontmost for keyboard focus to land in the
        // search field.
        popover.contentViewController?.view.window?.makeKey()
    }

    private func showContextMenu() {
        let menu = NSMenu()
        let engine = environment.engine

        switch engine.status {
        case .running(let target, _):
            menu.addItem(header("Tracking \(target.shortLabel) · \(DurationFormat.humane(engine.currentSegmentElapsed))"))
            menu.addItem(action("Pause", key: "p") { [weak self] in self?.environment.togglePauseResume() })
            menu.addItem(action("Stop and log", key: "s") { [weak self] in self?.environment.stop() })
        case .paused(let target, _):
            menu.addItem(header("Paused · \(target.shortLabel)"))
            menu.addItem(action("Resume", key: "p") { [weak self] in self?.environment.togglePauseResume() })
            menu.addItem(action("Stop and log", key: "s") { [weak self] in self?.environment.stop() })
        case .idle:
            menu.addItem(header("Not tracking"))
            if let recent = engine.state.recentIssues.first {
                menu.addItem(action("Resume \(recent.key)", key: "r") { [weak self] in
                    self?.environment.start(issue: recent)
                })
            }
        }

        menu.addItem(.separator())

        let quick = NSMenu()
        for category in [AdhocCategory.meeting, .call, .interruption, .breakTime] {
            quick.addItem(action(category.defaultLabel) { [weak self] in
                self?.environment.start(adhoc: category)
            })
        }
        let quickItem = NSMenuItem(title: "Quick capture", action: nil, keyEquivalent: "")
        quickItem.submenu = quick
        menu.addItem(quickItem)

        menu.addItem(.separator())
        menu.addItem(action("Open Chrono", key: "o") { [weak self] in self?.showPopover() })
        menu.addItem(action("Timesheet…") { [weak self] in
            guard let self else { return }
            WindowManager.shared.showTimesheet(environment: self.environment)
        })
        menu.addItem(action("Settings…", key: ",") { [weak self] in
            guard let self else { return }
            WindowManager.shared.showSettings(environment: self.environment)
        })
        menu.addItem(.separator())
        menu.addItem(action("Quit Chrono", key: "q") { NSApp.terminate(nil) })

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        // Detach immediately, or the menu would hijack the next left-click too.
        statusItem.menu = nil
    }

    private func header(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func action(_ title: String, key: String = "", handler: @escaping () -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(MenuActionTarget.fire), keyEquivalent: key)
        let target = MenuActionTarget(handler: handler)
        item.target = target
        item.representedObject = target   // keeps the target alive as long as the item
        return item
    }

    deinit {
        observationTask?.cancel()
    }
}

/// Bridges an AppKit menu action to a closure.
private final class MenuActionTarget: NSObject {
    private let handler: () -> Void

    init(handler: @escaping () -> Void) {
        self.handler = handler
    }

    @objc func fire() {
        handler()
    }
}
