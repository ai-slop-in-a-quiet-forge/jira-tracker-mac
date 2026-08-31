import AppKit
import Foundation
import ChronoCore

/// What is running and what is in front.
///
/// A supporting signal only: a meeting app being open means nothing on its own (Teams is
/// always open), but combined with live audio capture it tells us *which* app the call is in,
/// which is what makes the warning specific enough to be trustworthy.
@MainActor
public struct AppSensor {

    public init() {}

    public func frontmostApp() -> (bundleID: String?, name: String?) {
        guard let app = NSWorkspace.shared.frontmostApplication else { return (nil, nil) }
        return (app.bundleIdentifier, app.localizedName)
    }

    /// Which of the configured meeting apps are running right now.
    public func runningMeetingApps(matching bundleIDs: [String]) -> Set<String> {
        let wanted = Set(bundleIDs)
        let running = NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)
        return Set(running).intersection(wanted)
    }

    private static let browserBundleIDs: Set<String> = [
        "com.google.Chrome",
        "com.apple.Safari",
        "com.microsoft.edgemac",
        "org.mozilla.firefox",
        "com.brave.Browser",
        "company.thebrowser.Browser",   // Arc
        "com.vivaldi.Vivaldi",
        "com.operasoftware.Opera",
    ]

    /// A browser being open makes an in-tab meeting (Meet, Teams web, Zoom web) plausible.
    public func browserRunning() -> Bool {
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        return !running.intersection(Self.browserBundleIDs).isEmpty
    }
}
