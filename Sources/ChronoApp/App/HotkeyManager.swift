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

    /// `HotkeyAction` lives in ChronoCore so the settings UI and `HotkeySet` can share it; the
    /// Carbon API needs a small integer id, which is the only thing added here.
    typealias Action = HotkeyAction

    /// Shortcuts the window server refused, almost always because another app already owns the
    /// combination. Surfaced in Settings rather than only logged: a shortcut that silently does
    /// nothing is indistinguishable from a broken app.
    private(set) var unavailable: Set<Action> = []

    /// Fired after every registration pass with whatever the window server refused, so the
    /// environment can mirror it somewhere observable. Not `@Observable` here: this type has a
    /// `deinit` that unregisters, and the macro's isolation rules do not permit that.
    var onUnavailableChange: ((Set<Action>) -> Void)?

    private var registrations: [Action: EventHotKeyRef] = [:]
    private var handlers: [Action: () -> Void] = [:]
    /// Kept so the set can be re-registered when settings change, without rebuilding the
    /// closures that only `AppDelegate` knows how to make.
    private var installedHandlers: [Action: () -> Void] = [:]
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
                    guard let action = HotkeyManager.Action(carbonID: hotKeyID.id) else { return }
                    HotkeyManager.current?.handlers[action]?()
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
        installedHandlers = handlers
        reapply(set)
    }

    /// Re-registers everything for a changed set, reusing the handlers given to `apply`.
    ///
    /// Registration is all-or-nothing per shortcut and cheap, so replacing the lot is simpler
    /// than diffing — and it means a combination freed by one row is immediately available to
    /// another without an intermediate state where both are registered.
    func reapply(_ set: HotkeySet) {
        unregisterAll()

        for action in Action.allCases {
            guard let hotkey = set[action], hotkey.enabled,
                  let handler = installedHandlers[action]
            else { continue }
            register(action: action, hotkey: hotkey, handler: handler)
        }
        onUnavailableChange?(unavailable)
    }

    private func register(action: Action, hotkey: Hotkey, handler: @escaping () -> Void) {
        var reference: EventHotKeyRef?
        let identifier = EventHotKeyID(signature: OSType(0x4348_524F), id: action.carbonID) // 'CHRO'

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
            // so the app carries on — but Settings shows it, because a shortcut that does
            // nothing looks like a bug rather than a collision.
            ChronoLog.app.info("Could not register hotkey for \(action.rawValue, privacy: .public)")
            unavailable.insert(action)
            return
        }
        registrations[action] = reference
        handlers[action] = handler
    }

    func unregisterAll() {
        for reference in registrations.values {
            UnregisterEventHotKey(reference)
        }
        registrations.removeAll()
        handlers.removeAll()
        unavailable.removeAll()
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

/// The Carbon hot key API identifies a registration by a small integer, so each action needs a
/// stable numeric id. Kept next to the manager rather than on the shared `HotkeyAction`, because
/// it is an artefact of this one API and means nothing to the settings model.
extension HotkeyAction {

    var carbonID: UInt32 {
        switch self {
        case .togglePanel: return 1
        case .startStop: return 2
        case .pauseResume: return 3
        case .quickInterruption: return 4
        }
    }

    init?(carbonID: UInt32) {
        guard let match = HotkeyAction.allCases.first(where: { $0.carbonID == carbonID }) else {
            return nil
        }
        self = match
    }
}
