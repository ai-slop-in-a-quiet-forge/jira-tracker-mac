import ActivityKit
import SwiftUI
import WidgetKit

/// The widget extension's entry point.
///
/// Only a Live Activity lives here, deliberately. A Home Screen widget would have to read
/// Chrono's state from somewhere, and this app has no state of its own — everything it shows
/// arrives over Bluetooth from the Mac and is meaningless when the Mac is out of range. A Live
/// Activity is the honest shape for that: it exists exactly while there is a live connection to
/// something worth showing, and ends when there is not.
@main
struct ChronoWidgetBundle: WidgetBundle {
    var body: some Widget {
        ChronoLiveActivity()
    }
}

struct ChronoLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ChronoActivityAttributes.self) { context in
            ChronoLockScreenView(context: context)
                // The Lock Screen presentation is composited onto the wallpaper, so it must not
                // assume a background colour of its own.
                .activityBackgroundTint(.black.opacity(0.55))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            chronoDynamicIsland(context: context)
        }
    }
}
