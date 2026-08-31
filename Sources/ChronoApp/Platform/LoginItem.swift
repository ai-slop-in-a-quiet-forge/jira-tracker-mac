import Foundation
import ServiceManagement
import ChronoCore

/// Registers Chrono to start at login.
///
/// Uses `SMAppService.mainApp`, the modern replacement for the deprecated
/// `LSSharedFileList` API — it needs no helper bundle and the user can see and revoke it in
/// System Settings > General > Login Items, which is where they would look anyway.
public enum LoginItem {

    public static var isEnabled: Bool {
        guard isSupported else { return false }
        return SMAppService.mainApp.status == .enabled
    }

    /// Only meaningful for a properly bundled, launchable app; a bare binary from `.build`
    /// cannot register itself.
    public static var isSupported: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app"
    }

    @discardableResult
    public static func setEnabled(_ enabled: Bool) -> Bool {
        guard isSupported else { return false }
        do {
            if enabled {
                // Registering when already enabled throws, which is not an error worth surfacing.
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            }
            return true
        } catch {
            ChronoLog.app.error("Could not update login item: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// Human-readable status, for Settings.
    public static var statusDescription: String {
        guard isSupported else { return "Available once Chrono is installed in Applications" }
        switch SMAppService.mainApp.status {
        case .enabled: return "Enabled"
        case .requiresApproval: return "Needs approval in System Settings > Login Items"
        case .notRegistered: return "Disabled"
        case .notFound: return "Unavailable"
        @unknown default: return "Unknown"
        }
    }
}
