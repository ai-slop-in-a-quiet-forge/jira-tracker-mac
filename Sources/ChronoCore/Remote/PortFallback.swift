import Foundation

/// Decides what to do when a listener fails to bind.
///
/// Extracted from `WebRemoteServer` because the *decision* is where this can be wrong, and it is
/// the one part that does not need a socket to exercise. The server keeps the networking; this
/// keeps the rule, which is:
///
/// - The configured port is tried first, so the shortcut saved on the phone's Home Screen keeps
///   working across restarts.
/// - If it will not bind, fall back **once** to an OS-assigned port, so the remote still works
///   rather than leaving the user with nothing.
/// - Never a third attempt. A genuinely broken network would otherwise loop, restarting a
///   listener forever and burning CPU while reporting nothing.
/// - When there was no configured port to begin with, there is nothing to fall back *to*, so the
///   failure is real and must be surfaced.
public struct PortFallback: Sendable, Equatable {

    public enum Decision: Equatable, Sendable {
        /// Cancel and restart on an OS-assigned port.
        case retryOnAssignedPort
        /// Out of options: show the user why the remote is not running.
        case surface(String)
    }

    /// The port the user asked for. Zero means "let the OS choose", which cannot fall back.
    public let preferredPort: UInt16
    /// Whether the one permitted retry has been spent.
    public private(set) var hasFallenBack: Bool

    public init(preferredPort: UInt16, hasFallenBack: Bool = false) {
        self.preferredPort = preferredPort
        self.hasFallenBack = hasFallenBack
    }

    /// Consumes a bind failure and says what should happen next.
    ///
    /// Mutating rather than pure because spending the retry *is* the state change; a version
    /// that only reported would leave the caller to remember, which is precisely the bookkeeping
    /// that loops when it goes wrong.
    public mutating func handleFailure(_ message: String) -> Decision {
        guard preferredPort != 0, !hasFallenBack else {
            return .surface(message)
        }
        hasFallenBack = true
        return .retryOnAssignedPort
    }

    /// Re-arms the retry. Called when the server is stopped deliberately, so that enabling the
    /// remote again gets a fresh attempt at the configured port rather than going straight to an
    /// assigned one.
    public mutating func reset() {
        hasFallenBack = false
    }
}
