import Foundation

/// Renders a `Hotkey` the way macOS writes shortcuts: `⌃⌥T`.
///
/// Lives in ChronoCore rather than beside the settings view because it is pure translation with
/// no AppKit in it, and because the recorder, the settings row and any future menu item must all
/// spell the same combination the same way.
///
/// ## Why a table rather than the keyboard layout
///
/// A `Hotkey` stores a Carbon virtual key code, which is a *physical* key position: code 17 is
/// wherever T sits on a US layout and stays that key on AZERTY, which is exactly what a global
/// shortcut should do. Asking the current input source to name it would produce a label that
/// changes when the user switches layout, describing a key that did not move. So the table names
/// the position, as System Settings does.
public extension Hotkey {

    /// `⌃⌥T`, or nil when the key code is one this does not know how to name — better an honest
    /// blank than a confident wrong label.
    var displayString: String? {
        guard let key = Self.keyName(for: keyCode) else { return nil }
        return Self.modifierSymbols(modifiers) + key
    }

    /// The modifier glyphs in the order macOS prints them: Control, Option, Shift, Command.
    static func modifierSymbols(_ modifiers: UInt32) -> String {
        var symbols = ""
        if modifiers & Modifiers.control != 0 { symbols += "⌃" }
        if modifiers & Modifiers.option != 0 { symbols += "⌥" }
        if modifiers & Modifiers.shift != 0 { symbols += "⇧" }
        if modifiers & Modifiers.command != 0 { symbols += "⌘" }
        return symbols
    }

    /// Whether this combination is safe to register system-wide.
    ///
    /// A bare key, or one held only with Shift, would swallow ordinary typing in every app —
    /// pressing `T` anywhere would toggle the panel. macOS itself refuses these in System
    /// Settings, and so does the recorder.
    var hasRequiredModifiers: Bool {
        modifiers & (Modifiers.command | Modifiers.control | Modifiers.option) != 0
    }

    /// Names a Carbon virtual key code. Nil for keys with no sensible short label.
    static func keyName(for keyCode: UInt32) -> String? { keyNames[keyCode] }

    private static let keyNames: [UInt32: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V",
        11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T",
        18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5",
        24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0",
        30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P",
        36: "↩", 37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\",
        43: ",", 44: "/", 45: "N", 46: "M", 47: ".",
        48: "⇥", 49: "Space", 50: "`", 51: "⌫", 53: "⎋",
        // Keypad
        65: "._", 67: "*_", 69: "+_", 71: "⌧", 75: "/_", 76: "↩_", 78: "-_", 81: "=_",
        82: "0_", 83: "1_", 84: "2_", 85: "3_", 86: "4_", 87: "5_", 88: "6_", 89: "7_",
        91: "8_", 92: "9_",
        96: "F5", 97: "F6", 98: "F7", 99: "F3", 100: "F8", 101: "F9", 103: "F11",
        105: "F13", 107: "F14", 109: "F10", 111: "F12", 113: "F15",
        114: "?⃝", 115: "↖", 116: "⇞", 117: "⌦", 118: "F4", 119: "↘", 120: "F2",
        121: "⇟", 122: "F1", 123: "←", 124: "→", 125: "↓", 126: "↑",
    ]
}

public extension HotkeySet {
    /// Every combination currently in use, so the recorder can refuse a duplicate rather than
    /// silently letting the second registration lose to the first.
    func assignments() -> [(action: HotkeyAction, hotkey: Hotkey)] {
        [
            (.togglePanel, togglePanel),
            (.startStop, startStop),
            (.pauseResume, pauseResume),
            (.quickInterruption, quickInterruption),
        ].compactMap { action, hotkey in hotkey.map { (action, $0) } }
    }

    subscript(action: HotkeyAction) -> Hotkey? {
        get {
            switch action {
            case .togglePanel: return togglePanel
            case .startStop: return startStop
            case .pauseResume: return pauseResume
            case .quickInterruption: return quickInterruption
            }
        }
        set {
            switch action {
            case .togglePanel: togglePanel = newValue
            case .startStop: startStop = newValue
            case .pauseResume: pauseResume = newValue
            case .quickInterruption: quickInterruption = newValue
            }
        }
    }

    /// The action already using `hotkey`, ignoring `excluding` so re-recording the same
    /// combination onto the row that already owns it is not reported as a clash.
    func conflict(with hotkey: Hotkey, excluding action: HotkeyAction) -> HotkeyAction? {
        assignments().first { assignment in
            assignment.action != action
                && assignment.hotkey.keyCode == hotkey.keyCode
                && assignment.hotkey.modifiers == hotkey.modifiers
        }?.action
    }
}

/// The four shortcut slots, named here rather than in the app target so `HotkeySet` can be
/// indexed by them and the settings UI can build its rows from one list.
public enum HotkeyAction: String, CaseIterable, Sendable {
    case togglePanel
    case startStop
    case pauseResume
    case quickInterruption

    public var title: String {
        switch self {
        case .togglePanel: return "Show or hide the panel"
        case .startStop: return "Start or stop the timer"
        case .pauseResume: return "Pause or resume"
        case .quickInterruption: return "Capture an interruption"
        }
    }
}
