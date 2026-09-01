import Foundation
import Testing
@testable import ChronoCore

@Suite("Keyboard shortcuts")
struct HotkeyTests {

    @Test("Renders a combination the way macOS writes it")
    func displayString() {
        let hotkey = Hotkey(keyCode: KeyCodes.t, modifiers: Modifiers.controlOption)
        #expect(hotkey.displayString == "⌃⌥T")
    }

    @Test("Modifier glyphs are ordered Control, Option, Shift, Command")
    func modifierOrder() {
        // Whatever order the bits are combined in, the glyphs come out in the order System
        // Settings prints them; anything else looks like a different shortcut at a glance.
        let all = Modifiers.command | Modifiers.shift | Modifiers.option | Modifiers.control
        #expect(Hotkey.modifierSymbols(all) == "⌃⌥⇧⌘")
        #expect(Hotkey.modifierSymbols(Modifiers.commandShift) == "⇧⌘")
    }

    @Test("Every default shortcut is nameable")
    func defaultsAreNameable() {
        for (_, hotkey) in HotkeySet.defaults.assignments() {
            #expect(hotkey.displayString != nil)
        }
        #expect(HotkeySet.defaults.togglePanel?.displayString == "⌃⌥T")
        #expect(HotkeySet.defaults.startStop?.displayString == "⌃⌥S")
        #expect(HotkeySet.defaults.pauseResume?.displayString == "⌃⌥P")
        #expect(HotkeySet.defaults.quickInterruption?.displayString == "⌃⌥I")
    }

    @Test("An unknown key code produces no label rather than a wrong one")
    func unknownKeyCode() {
        #expect(Hotkey(keyCode: 9999, modifiers: Modifiers.control).displayString == nil)
    }

    @Test("A combination needs Command, Control or Option to be registerable")
    func requiredModifiers() {
        // Without one of these the shortcut would swallow ordinary typing in every app.
        #expect(Hotkey(keyCode: KeyCodes.t, modifiers: 0).hasRequiredModifiers == false)
        #expect(Hotkey(keyCode: KeyCodes.t, modifiers: Modifiers.shift).hasRequiredModifiers == false)
        #expect(Hotkey(keyCode: KeyCodes.t, modifiers: Modifiers.control).hasRequiredModifiers)
        #expect(Hotkey(keyCode: KeyCodes.t, modifiers: Modifiers.command).hasRequiredModifiers)
        #expect(Hotkey(keyCode: KeyCodes.t, modifiers: Modifiers.option).hasRequiredModifiers)
    }

    @Test("A set can be read and written by action")
    func subscriptAccess() {
        var set = HotkeySet.defaults
        #expect(set[.startStop] == set.startStop)

        let replacement = Hotkey(keyCode: KeyCodes.i, modifiers: Modifiers.commandShift)
        set[.startStop] = replacement
        #expect(set.startStop == replacement)

        set[.startStop] = nil
        #expect(set.startStop == nil)
        #expect(set.assignments().count == 3)
    }

    @Test("A combination already used by another action is reported as a conflict")
    func conflictDetection() {
        let set = HotkeySet.defaults
        let takenByToggle = Hotkey(keyCode: KeyCodes.t, modifiers: Modifiers.controlOption)

        #expect(set.conflict(with: takenByToggle, excluding: .startStop) == .togglePanel)
        // Re-recording the same combination onto the row that already owns it is not a clash.
        #expect(set.conflict(with: takenByToggle, excluding: .togglePanel) == nil)
        // A free combination is not a clash either.
        let free = Hotkey(keyCode: KeyCodes.i, modifiers: Modifiers.commandShift)
        #expect(set.conflict(with: free, excluding: .startStop) == nil)
    }

    @Test("Modifiers alone do not make two shortcuts equal")
    func sameKeyDifferentModifiers() {
        let set = HotkeySet.defaults
        let sameKeyOtherModifiers = Hotkey(keyCode: KeyCodes.t, modifiers: Modifiers.commandShift)
        #expect(set.conflict(with: sameKeyOtherModifiers, excluding: .startStop) == nil)
    }
}
