import Foundation
import Network
import ChronoCore

/// A very small HTTP server on the local network, serving the phone remote.
///
/// This is the zero-install path: the Mac serves one self-contained page, the phone scans a QR
/// code, adds it to the Home Screen and behaves like an app. No App Store, no Xcode, no
/// certificates, nothing to expire.
///
/// It is intentionally tiny and closes every connection after responding rather than
/// implementing keep-alive. The traffic is a handful of requests every couple of seconds from
/// one device on a LAN; a connection state machine would be all risk and no benefit.
///
/// **Security.** Only the loopback and private LAN can reach it, and every request must carry
/// an HMAC signature proving knowledge of the pairing secret. The secret itself never travels
/// over the wire — it reaches the phone in the QR code's URL *fragment*, which browsers do not
/// send to servers.
final class WebRemoteServer: @unchecked Sendable {

    /// Called on the main actor to produce the current state as JSON.
    typealias StateProvider = @MainActor () -> Data
    /// Called on the main actor with a verified-shape request; returns the response JSON.
    typealias CommandHandler = @MainActor (
        _ body: Data,
        _ counter: UInt64,
        _ timestamp: Int64,
        _ mac: Data,
        _ deviceID: String
    ) async -> (status: Int, body: Data)

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "in.chrono.webremote")
    private var connections = Set<ObjectIdentifier>()
    private let lock = NSLock()

    var stateProvider: StateProvider?
    var commandHandler: CommandHandler?

    private(set) var port: UInt16?
    private(set) var lastError: String?
    /// The one-shot retry rule, in `ChronoCore` so it can be tested without a socket.
    private var fallback = PortFallback(preferredPort: 0)
    /// True once the configured port turned out to be taken and an assigned one was used
    /// instead. Worth knowing: the phone's saved Home Screen shortcut points at the old port.
    var didFallBackToAssignedPort: Bool { fallback.hasFallenBack }

    /// Cap on request size. The largest legitimate request is a signed command with a note in
    /// it; anything vastly bigger is either a bug or an attack.
    private static let maxRequestBytes = 16 * 1024

    // MARK: - Lifecycle

    func start(preferredPort: UInt16) throws {
        // `stop` re-arms the retry, which is right for a deliberate stop but wrong here: a
        // restart *is* the retry, and re-arming would allow an endless chain of them.
        let carried = fallback
        stop()
        fallback = carried

        // A different configured port is a new situation and deserves a fresh retry. The
        // fallback's own restart passes 0, which is how it is told apart from the user changing
        // the port in Settings — otherwise the retry would re-arm its own guard and loop.
        if preferredPort != 0, preferredPort != fallback.preferredPort {
            fallback = PortFallback(preferredPort: preferredPort)
        }

        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        // No point advertising over anything but the local network.
        parameters.includePeerToPeer = false

        // Try the configured port first, so the shortcut saved on the phone keeps working across
        // restarts. If it is taken, `stateUpdateHandler` retries with an OS-assigned one —
        // binding failures surface asynchronously, so they cannot be caught here.
        let listener: NWListener
        if preferredPort == 0 {
            listener = try NWListener(using: parameters)
        } else if let port = NWEndpoint.Port(rawValue: preferredPort) {
            listener = try NWListener(using: parameters, on: port)
        } else {
            throw RemoteError.invalidPort
        }

        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.port = listener.port?.rawValue
                ChronoLog.remote.info("Web remote listening on port \(listener.port?.rawValue ?? 0)")
            case .failed(let error):
                ChronoLog.remote.error("Web remote failed: \(error.localizedDescription, privacy: .public)")
                // Almost always "port already in use". `PortFallback` owns the rule; it is
                // tested directly, since a real bind failure cannot be provoked here —
                // `allowLocalEndpointReuse` makes a second bind of the same port succeed.
                guard let self else { return }
                switch self.fallback.handleFailure(error.localizedDescription) {
                case .retryOnAssignedPort:
                    ChronoLog.remote.info("Retrying the web remote on an OS-assigned port")
                    self.restartOnAssignedPort()
                case .surface(let message):
                    self.lastError = message
                }
            case .cancelled:
                self?.port = nil
            default:
                break
            }
        }

        listener.start(queue: queue)
        self.listener = listener
    }

    func stop() {
        listener?.cancel()
        listener = nil
        port = nil
        fallback.reset()
    }

    /// Second attempt after the configured port turned out to be in use.
    private func restartOnAssignedPort() {
        listener?.cancel()
        listener = nil
        port = nil
        do {
            try start(preferredPort: 0)
        } catch {
            lastError = error.localizedDescription
        }
    }

    var isRunning: Bool { listener != nil && port != nil }

    enum RemoteError: Error, LocalizedError {
        case invalidPort
        var errorDescription: String? { "That port could not be used." }
    }

    // MARK: - Connections

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
    }

    /// Reads until the headers are complete, then until the body is complete.
    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] chunk, _, isComplete, error in
            guard let self else { return }
            if error != nil {
                connection.cancel()
                return
            }

            var accumulated = buffer
            if let chunk { accumulated.append(chunk) }

            guard accumulated.count <= Self.maxRequestBytes else {
                self.respond(on: connection, status: 413, body: Data("too large".utf8), contentType: "text/plain")
                return
            }

            if let request = HTTPRequest(raw: accumulated) {
                self.handle(request, on: connection)
                return
            }

            if isComplete {
                connection.cancel()
                return
            }
            self.receive(on: connection, buffer: accumulated)
        }
    }

    private func handle(_ request: HTTPRequest, on connection: NWConnection) {
        switch (request.method, request.path) {
        case ("GET", "/"), ("GET", "/index.html"):
            respond(
                on: connection,
                status: 200,
                body: Data(RemoteWebAssets.indexHTML.utf8),
                contentType: "text/html; charset=utf-8"
            )

        case ("GET", "/manifest.webmanifest"):
            respond(
                on: connection,
                status: 200,
                body: Data(RemoteWebAssets.manifestJSON.utf8),
                contentType: "application/manifest+json"
            )

        case ("GET", "/icon.svg"):
            respond(
                on: connection,
                status: 200,
                body: Data(RemoteWebAssets.iconSVG.utf8),
                contentType: "image/svg+xml"
            )

        case ("GET", "/health"):
            // Unauthenticated, and deliberately says nothing beyond "a Chrono is here".
            respond(
                on: connection,
                status: 200,
                body: Data(#"{"app":"chrono","v":1}"#.utf8),
                contentType: "application/json"
            )

        case ("GET", "/state"), ("POST", "/command"):
            handleAuthenticated(request, on: connection)

        default:
            respond(on: connection, status: 404, body: Data(#"{"error":"not found"}"#.utf8), contentType: "application/json")
        }
    }

    /// Both the state read and the command write are signed; reading what you are working on is
    /// no less private than changing it.
    private func handleAuthenticated(_ request: HTTPRequest, on connection: NWConnection) {
        guard let counterText = request.headers["x-chrono-counter"],
              let counter = UInt64(counterText),
              let timestampText = request.headers["x-chrono-timestamp"],
              let timestamp = Int64(timestampText),
              let macText = request.headers["x-chrono-mac"],
              let mac = Data(base64Encoded: macText),
              let deviceID = request.headers["x-chrono-device"]
        else {
            respond(
                on: connection,
                status: 401,
                body: Data(#"{"error":"unsigned request"}"#.utf8),
                contentType: "application/json"
            )
            return
        }

        guard let commandHandler else {
            respond(on: connection, status: 503, body: Data(#"{"error":"not ready"}"#.utf8), contentType: "application/json")
            return
        }

        // The signed payload is the raw body for a command, and the path for a state read (so a
        // GET still has something unique to sign).
        let payload = request.method == "GET" ? Data(request.path.utf8) : request.body

        Task { @MainActor in
            let result = await commandHandler(payload, counter, timestamp, mac, deviceID)
            self.respond(
                on: connection,
                status: result.status,
                body: result.body,
                contentType: "application/json"
            )
        }
    }

    // MARK: - Responding

    private func respond(on connection: NWConnection, status: Int, body: Data, contentType: String) {
        var head = "HTTP/1.1 \(status) \(Self.reason(for: status))\r\n"
        head += "Content-Type: \(contentType)\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Cache-Control: no-store\r\n"
        // The page is served from, and only talks to, this origin.
        head += "Connection: close\r\n"
        head += "\r\n"

        var response = Data(head.utf8)
        response.append(body)

        connection.send(content: response, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private static func reason(for status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 413: return "Payload Too Large"
        case 503: return "Service Unavailable"
        default: return "Error"
        }
    }
}
