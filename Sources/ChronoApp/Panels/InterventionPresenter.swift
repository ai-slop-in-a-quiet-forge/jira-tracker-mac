import AppKit
import SwiftUI
import ChronoCore

/// Shows the interventions that need an answer in a floating panel near the menu bar.
///
/// Why not a notification? Three reasons, all learned from how these things actually fail:
/// notification permission can be denied outright; a Focus mode swallows banners silently; and
/// the whole promise of this app is that it *will* tell you when the wrong thing is being
/// tracked. A panel Chrono draws itself cannot be suppressed by any of that.
///
/// The panel is `.nonactivatingPanel` and never becomes key, so answering "keep going" does
/// not yank focus out of the call you are on.
@MainActor
public final class InterventionPresenter {
    public static let shared = InterventionPresenter()

    private var panel: NSPanel?
    private var dismissTask: Task<Void, Never>?

    private init() {}

    public func present(_ intervention: Intervention, environment: AppEnvironment) {
        dismiss()

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 200),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        // Follow the user across Spaces: a prompt about a meeting is useless if it is stranded
        // on the desktop you left.
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.animationBehavior = .utilityWindow

        let view = InterventionView(intervention: intervention) { choice in
            environment.resolve(intervention: intervention, with: choice)
        }
        .environment(environment)

        let hosting = NSHostingView(rootView: view)
        hosting.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView = hosting
        // Let the SwiftUI content decide the height.
        panel.setContentSize(hosting.fittingSize)

        position(panel)
        panel.orderFrontRegardless()
        self.panel = panel

        scheduleAutoDismiss(for: intervention, environment: environment)
    }

    /// Places the panel just below the menu bar on the right, where the status item lives.
    private func position(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let size = panel.frame.size
        let origin = CGPoint(
            x: visible.maxX - size.width - 14,
            y: visible.maxY - size.height - 6
        )
        panel.setFrameOrigin(origin)
    }

    /// Prompts that can safely time out do so, choosing the conservative option.
    ///
    /// An idle prompt left unanswered means the user really is away, so after a while the idle
    /// time is discarded and the timer paused — the answer they would almost certainly have
    /// given. A meeting prompt simply fades: doing nothing keeps tracking, which is reversible.
    private func scheduleAutoDismiss(for intervention: Intervention, environment: AppEnvironment) {
        dismissTask?.cancel()

        let timeout: Duration?
        let fallback: InterventionChoice?
        switch intervention {
        case .idleDetected:
            timeout = .seconds(120)
            fallback = .idleDiscardAndPause
        case .meetingDetected:
            timeout = .seconds(60)
            fallback = nil
        case .runawaySession:
            timeout = nil        // too important to disappear on its own
            fallback = nil
        case .endOfDayReview:
            timeout = .seconds(90)
            fallback = nil
        default:
            timeout = .seconds(30)
            fallback = nil
        }

        guard let timeout else { return }
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            if let fallback {
                environment.resolve(intervention: intervention, with: fallback)
            } else {
                self?.dismiss()
            }
        }
    }

    public func dismiss() {
        dismissTask?.cancel()
        dismissTask = nil
        panel?.orderOut(nil)
        panel = nil
    }

    public var isPresenting: Bool { panel != nil }
}
