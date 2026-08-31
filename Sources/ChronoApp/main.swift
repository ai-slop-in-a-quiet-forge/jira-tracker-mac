import AppKit

// Chrono is an AppKit app rather than a SwiftUI `App`, because a menu bar app needs precise
// control over the status item, the popover's focus behaviour and the non-activating panels —
// all of which SwiftUI's `MenuBarExtra` abstracts away.
//
// Top-level code rather than `@main`, so the activation policy is set before any window can be
// created and the app never flashes a Dock icon on launch. Top-level code is not itself
// main-actor isolated, hence the explicit hops: this genuinely does run on the main thread.

/// Held at top level for the lifetime of the process, because `NSApplication.delegate` is weak.
let delegate = MainActor.assumeIsolated { AppDelegate() }

MainActor.assumeIsolated {
    let application = NSApplication.shared
    application.delegate = delegate
    application.setActivationPolicy(.accessory)
    application.run()
}
