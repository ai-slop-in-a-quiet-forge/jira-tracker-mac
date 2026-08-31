import AppKit
import SwiftUI
import ChronoCore

/// Owns Chrono's auxiliary windows: the timesheet, settings, onboarding, crash recovery and
/// phone pairing.
///
/// A menu bar app has no main window and no document model, so window lifecycle is managed by
/// hand. Each kind is a singleton: asking for the timesheet twice brings the existing one
/// forward rather than opening a second copy.
@MainActor
public final class WindowManager {
    public static let shared = WindowManager()

    public enum Kind: String, CaseIterable {
        case timesheet
        case settings
        case onboarding
        case recovery
        case pairing

        var title: String {
            switch self {
            case .timesheet: return "Timesheet"
            case .settings: return "Chrono Settings"
            case .onboarding: return "Welcome to Chrono"
            case .recovery: return "Unfinished Session"
            case .pairing: return "Phone Remote"
            }
        }

        var size: CGSize {
            switch self {
            case .timesheet: return CGSize(width: 900, height: 620)
            case .settings: return CGSize(width: 620, height: 620)
            case .onboarding: return CGSize(width: 560, height: 540)
            case .recovery: return CGSize(width: 480, height: 340)
            case .pairing: return CGSize(width: 520, height: 600)
            }
        }

        /// Small, focused windows should not be resizable — it only lets the user make them ugly.
        var isResizable: Bool {
            switch self {
            case .timesheet, .settings: return true
            case .onboarding, .recovery, .pairing: return false
            }
        }
    }

    private var windows: [Kind: NSWindow] = [:]

    private init() {}

    public var hasVisibleWindow: Bool {
        windows.values.contains { $0.isVisible }
    }

    // MARK: - Public entry points

    public func showTimesheet(environment: AppEnvironment) {
        show(.timesheet, environment: environment) { TimesheetView().environment(environment) }
    }

    public func showSettings(environment: AppEnvironment) {
        show(.settings, environment: environment) { SettingsView().environment(environment) }
    }

    public func showOnboarding(environment: AppEnvironment) {
        show(.onboarding, environment: environment) { OnboardingView().environment(environment) }
    }

    public func showRecovery(environment: AppEnvironment) {
        show(.recovery, environment: environment) { RecoveryView().environment(environment) }
    }

    public func showPairing(environment: AppEnvironment) {
        show(.pairing, environment: environment) { PairingView().environment(environment) }
    }

    public func close(_ kind: Kind) {
        windows[kind]?.close()
        windows[kind] = nil
    }

    // MARK: - Plumbing

    private func show<Content: View>(
        _ kind: Kind,
        environment: AppEnvironment,
        @ViewBuilder content: () -> Content
    ) {
        if let existing = windows[kind] {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        var style: NSWindow.StyleMask = [.titled, .closable, .fullSizeContentView]
        if kind.isResizable { style.insert(.resizable); style.insert(.miniaturizable) }

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: kind.size),
            styleMask: style,
            backing: .buffered,
            defer: false
        )
        window.title = kind.title
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: content())
        window.center()
        // Remember where the user put it, per kind.
        window.setFrameAutosaveName("chrono.window.\(kind.rawValue)")
        window.delegate = WindowCloseObserver.shared

        WindowCloseObserver.shared.register(window: window, kind: kind) { [weak self] in
            self?.windows[kind] = nil
        }

        windows[kind] = window
        window.makeKeyAndOrderFront(nil)
        // An accessory app is not activated by default, so a window would open behind whatever
        // the user was doing.
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// Clears the cached window when the user closes it, so the next request builds a fresh one.
@MainActor
final class WindowCloseObserver: NSObject, NSWindowDelegate {
    static let shared = WindowCloseObserver()

    private var callbacks: [ObjectIdentifier: () -> Void] = [:]

    func register(window: NSWindow, kind: WindowManager.Kind, onClose: @escaping () -> Void) {
        callbacks[ObjectIdentifier(window)] = onClose
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        let key = ObjectIdentifier(window)
        callbacks[key]?()
        callbacks[key] = nil
    }
}
