import Foundation
import CoreGraphics

/// How long the user has been away from the keyboard and mouse.
///
/// Uses `CGEventSource`, which reports system-wide HID inactivity and needs no accessibility
/// or input-monitoring permission — Chrono can tell *that* you stopped typing without being
/// able to see *what* you type, which is the right trade for a time tracker.
public struct IdleSensor: Sendable {

    public init() {}

    /// Seconds since the last human input of any kind.
    public func idleSeconds() -> TimeInterval {
        // Each event type is tracked separately, so the true idle time is the minimum across
        // everything a person could plausibly have done.
        let interesting: [CGEventType] = [
            .mouseMoved,
            .leftMouseDown,
            .rightMouseDown,
            .otherMouseDown,
            .keyDown,
            .scrollWheel,
            .flagsChanged,
        ]

        let shortest = interesting
            .map { CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: $0) }
            .filter { $0.isFinite && $0 >= 0 }
            .min()

        return shortest ?? 0
    }
}
