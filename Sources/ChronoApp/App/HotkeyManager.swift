import AppKit
import Carbon.HIToolbox
import ChronoCore

/// System-wide keyboard shortcuts.
///
/// Uses the Carbon hot key API rather than an `NSEvent` global monitor, because the Carbon one
/// needs no Accessibility permission — it registers a specific combination with the window
/// server instead of observing every keystroke. For a time tracker, asking for permission to
/// watch all input would be a wildly disproportionate request.
@MainActor
final class HotkeyManager {

    enum Action: UInt32, CaseIterable {
        case togglePanel = 1
        case startStop = 2
        case pauseResume = 3
        case quickInterruption = 4
    }

    private var registrations: [UInt32: EventHotKeyRef] = [:]
    private var handlers: [UInt32: () -> Void] = [:]
    private var eventHandler: EventHandlerRef?

    /// The Carbon callback is a C function pointer and cannot capture context, so the live
    /// manager is reached through this.
    private static weak var current: HotkeyManager?

    init() {
        Self.current = self
        installEventHandler()
    }

    private func installEventHandler() {
        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, _ -> OSStatus in
                var hotKeyID = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                guard status == noErr else { return status }

                // Hot key events are delivered on the main thread by the window server.
                MainActor.assumeIsolated {
                    HotkeyManager.current?.handlers[hotKeyID.id]?()
                }
                return noErr
            },
            1,
            &spec,
            nil,
            &eventHandler
        )
    }

    /// Applies a whole set at once, replacing anything previously registered.
    func apply(_ set: HotkeySet, handlers: [Action: () -> Void]) {
        unregisterAll()

        let pairs: [(Action, Hotkey?)] = [
            (.togglePanel, set.togglePanel),
            (.startStop, set.startStop),
            (.pauseResume, set.pauseResume),
            (.quickInterruption, set.quickInterruption),
        ]

        for (action, hotkey) in pairs {
            guard let hotkey, hotkey.enabled, let handler = handlers[action] else { continue }
            register(action: action, hotkey: hotkey, handler: handler)
        }
    }

    private func register(action: Action, hotkey: Hotkey, handler: @escaping () -> Void) {
        var reference: EventHotKeyRef?
        let identifier = EventHotKeyID(signature: OSType(0x4348_524F), id: action.rawValue) // 'CHRO'

        let status = RegisterEventHotKey(
            hotkey.keyCode,
            hotkey.modifiers,
            identifier,
            GetApplicationEventTarget(),
            0,
            &reference
        )

        guard status == noErr, let reference else {
            // The most likely cause is another app already owning the combination. Not fatal,
            // and not worth interrupting the user over.
            ChronoLog.app.info("Could not register hotkey for \(String(describing: action), privacy: .public)")
            return
        }
        registrations[action.rawValue] = reference
        handlers[action.rawValue] = handler
    }

    func unregisterAll() {
        for reference in registrations.values {
            UnregisterEventHotKey(reference)
        }
        registrations.removeAll()
        handlers.removeAll()
    }

    deinit {
        for reference in registrations.values {
            UnregisterEventHotKey(reference)
        }
        if let eventHandler {
            RemoveEventHandler(eventHandler)
        }
    }
}
