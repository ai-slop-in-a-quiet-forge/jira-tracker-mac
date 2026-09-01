import AppKit
import SwiftUI
import ChronoCore

/// A click-then-press control for capturing a global shortcut, like the one in System Settings.
///
/// ## Why AppKit rather than SwiftUI
///
/// Recording a shortcut means seeing the key *before* anything else acts on it. SwiftUI's
/// `onKeyPress` runs after the responder chain has had its turn, so a combination containing
/// Command would be eaten by the menu bar and never arrive. An `NSView` that returns true from
/// `performKeyEquivalent(with:)` sees the event first, which is the whole job.
struct ShortcutRecorder: NSViewRepresentable {

    /// The current combination, or nil when the shortcut is unset.
    let hotkey: Hotkey?
    /// Called with a new combination, or nil when the user clears it.
    let onChange: (Hotkey?) -> Void
    /// Returns a description of the clash when the combination is already spoken for, so the
    /// recorder can refuse it and say why. Nil means the combination is free.
    let conflictCheck: (Hotkey) -> String?

    func makeNSView(context: Context) -> RecorderView {
        let view = RecorderView()
        view.onChange = onChange
        view.conflictCheck = conflictCheck
        view.hotkey = hotkey
        return view
    }

    func updateNSView(_ view: RecorderView, context: Context) {
        view.onChange = onChange
        view.conflictCheck = conflictCheck
        // Do not disturb the display while the user is mid-recording.
        if !view.isRecording { view.hotkey = hotkey }
    }

    /// The AppKit control doing the actual capture.
    final class RecorderView: NSView {

        var onChange: ((Hotkey?) -> Void)?
        var conflictCheck: ((Hotkey) -> String?)?

        var hotkey: Hotkey? {
            didSet { needsDisplay = true }
        }

        private(set) var isRecording = false {
            didSet { needsDisplay = true }
        }

        /// Shown instead of the shortcut for a moment when a combination is refused.
        private var rejection: String? {
            didSet { needsDisplay = true }
        }

        private var rejectionTimer: Timer?

        override var acceptsFirstResponder: Bool { true }
        override var intrinsicContentSize: NSSize { NSSize(width: 108, height: 22) }

        override func mouseDown(with event: NSEvent) {
            if isRecording {
                stopRecording()
            } else {
                window?.makeFirstResponder(self)
                rejection = nil
                isRecording = true
            }
        }

        override func resignFirstResponder() -> Bool {
            stopRecording()
            return true
        }

        private func stopRecording() {
            isRecording = false
        }

        /// Seen before the responder chain, so Command combinations reach us instead of firing a
        /// menu item.
        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            guard isRecording else { return false }
            handle(event)
            return true
        }

        override func keyDown(with event: NSEvent) {
            guard isRecording else {
                super.keyDown(with: event)
                return
            }
            handle(event)
        }

        private func handle(_ event: NSEvent) {
            // Escape abandons the recording; Delete clears the shortcut entirely. Neither can be
            // recorded as a shortcut, which matches System Settings and keeps a way out.
            if event.keyCode == 53 {
                stopRecording()
                return
            }
            if event.keyCode == 51 {
                hotkey = nil
                onChange?(nil)
                stopRecording()
                return
            }

            let modifiers = Self.carbonModifiers(from: event.modifierFlags)
            let candidate = Hotkey(keyCode: UInt32(event.keyCode), modifiers: modifiers)

            guard candidate.hasRequiredModifiers else {
                reject("Add ⌘, ⌃ or ⌥")
                return
            }
            guard candidate.displayString != nil else {
                reject("Unsupported key")
                return
            }
            if let clash = conflictCheck?(candidate) {
                reject(clash)
                return
            }

            hotkey = candidate
            onChange?(candidate)
            stopRecording()
        }

        /// Leaves the recorder open so the next press can simply be a better one.
        private func reject(_ message: String) {
            NSSound.beep()
            rejection = message
            rejectionTimer?.invalidate()
            rejectionTimer = Timer.scheduledTimer(withTimeInterval: 1.6, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.rejection = nil }
            }
        }

        /// `NSEvent` flags are a different bit layout from the Carbon masks `RegisterEventHotKey`
        /// wants, so they have to be translated rather than cast.
        static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
            var carbon: UInt32 = 0
            if flags.contains(.command) { carbon |= Modifiers.command }
            if flags.contains(.shift) { carbon |= Modifiers.shift }
            if flags.contains(.option) { carbon |= Modifiers.option }
            if flags.contains(.control) { carbon |= Modifiers.control }
            return carbon
        }

        // MARK: - Drawing

        override func draw(_ dirtyRect: NSRect) {
            let rounded = NSBezierPath(roundedRect: bounds, xRadius: 5, yRadius: 5)
            (isRecording ? NSColor.controlAccentColor.withAlphaComponent(0.18)
                         : NSColor.quaternaryLabelColor).setFill()
            rounded.fill()

            if isRecording {
                NSColor.controlAccentColor.setStroke()
                rounded.lineWidth = 1
                rounded.stroke()
            }

            let text: String
            let colour: NSColor
            if let rejection {
                text = rejection
                colour = .systemOrange
            } else if isRecording {
                text = "Press keys…"
                colour = .secondaryLabelColor
            } else if let display = hotkey?.displayString {
                text = display
                colour = .labelColor
            } else {
                text = "Not set"
                colour = .tertiaryLabelColor
            }

            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11, weight: .medium),
                .foregroundColor: colour,
            ]
            let size = text.size(withAttributes: attributes)
            text.draw(
                at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2),
                withAttributes: attributes
            )
        }

        override var isFlipped: Bool { false }
    }
}
