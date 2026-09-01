import Foundation
import Testing
@testable import ChronoCore

@Suite("Web remote port fallback")
struct PortFallbackTests {

    @Test("A taken configured port falls back to an OS-assigned one")
    func fallsBackOnce() {
        var fallback = PortFallback(preferredPort: 47_632)
        #expect(fallback.hasFallenBack == false)
        #expect(fallback.handleFailure("Address already in use") == .retryOnAssignedPort)
        #expect(fallback.hasFallenBack)
    }

    @Test("There is never a third attempt")
    func doesNotLoop() {
        // The whole point of the guard: a genuinely broken network would otherwise restart a
        // listener forever, burning CPU while reporting nothing to the user.
        var fallback = PortFallback(preferredPort: 47_632)
        #expect(fallback.handleFailure("Address already in use") == .retryOnAssignedPort)
        #expect(fallback.handleFailure("No route to host") == .surface("No route to host"))
        #expect(fallback.handleFailure("No route to host") == .surface("No route to host"))
    }

    @Test("A failure on an OS-assigned port is surfaced, not retried")
    func assignedPortHasNowhereToFallBackTo() {
        // preferredPort 0 already means "let the OS choose"; retrying would ask for the same
        // thing again and fail the same way.
        var fallback = PortFallback(preferredPort: 0)
        #expect(fallback.handleFailure("Operation not permitted") == .surface("Operation not permitted"))
        #expect(fallback.hasFallenBack == false)
    }

    @Test("The surfaced message is the one the listener reported")
    func messageIsPreserved() {
        var fallback = PortFallback(preferredPort: 0)
        guard case .surface(let message) = fallback.handleFailure("Address already in use") else {
            Issue.record("expected the failure to be surfaced")
            return
        }
        #expect(message == "Address already in use")
    }

    @Test("Stopping deliberately re-arms the retry")
    func resetRearms() {
        // Turning the remote off and on again should get a fresh attempt at the configured
        // port, rather than going straight to an assigned one for the rest of the session.
        var fallback = PortFallback(preferredPort: 47_632)
        _ = fallback.handleFailure("Address already in use")
        #expect(fallback.hasFallenBack)

        fallback.reset()
        #expect(fallback.hasFallenBack == false)
        #expect(fallback.handleFailure("Address already in use") == .retryOnAssignedPort)
    }

    @Test("State can be restored across a restart", arguments: [true, false])
    func roundTripsItsGuard(spent: Bool) {
        // `WebRemoteServer.start` carries this across its internal `stop()`, so the restart that
        // *is* the retry cannot reset its own guard.
        let carried = PortFallback(preferredPort: 47_632, hasFallenBack: spent)
        #expect(carried.hasFallenBack == spent)

        var copy = carried
        let decision = copy.handleFailure("Address already in use")
        #expect(decision == (spent ? .surface("Address already in use") : .retryOnAssignedPort))
    }
}
