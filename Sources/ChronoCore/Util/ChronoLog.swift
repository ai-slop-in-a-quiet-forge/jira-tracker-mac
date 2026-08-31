import Foundation
import os

/// Thin wrapper over the unified logging system.
///
/// Uses `os.Logger` rather than `print` so that logs survive into Console.app for a user
/// reporting a problem, and so that anything privacy-sensitive can be marked as such. Nothing
/// here ever logs a credential: tokens and pairing secrets are only ever described by their
/// last few characters, via the `redacted` helpers on the types that hold them.
public enum ChronoLog {
    private static let subsystem = "in.chrono.tracker"

    public static let app = Logger(subsystem: subsystem, category: "app")
    public static let engine = Logger(subsystem: subsystem, category: "engine")
    public static let jira = Logger(subsystem: subsystem, category: "jira")
    public static let sensors = Logger(subsystem: subsystem, category: "sensors")
    public static let remote = Logger(subsystem: subsystem, category: "remote")
    public static let storage = Logger(subsystem: subsystem, category: "storage")

    public static func error(_ message: String) {
        app.error("\(message, privacy: .public)")
    }

    public static func info(_ message: String) {
        app.info("\(message, privacy: .public)")
    }

    public static func debug(_ message: String) {
        app.debug("\(message, privacy: .public)")
    }
}
