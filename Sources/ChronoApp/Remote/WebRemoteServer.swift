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

    /// Cap on request size. The largest legitimate request is a signed command with a note in
    /// it; anything vastly bigger is either a bug or an attack.
    private static let maxRequestBytes = 16 * 1024

    // MARK: - Lifecycle

    func start(preferredPort: UInt16) throws {
        stop()

        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        // No point advertising over anything but the local network.
        parameters.includePeerToPeer = false

        let listener: NWListener
        if preferredPort == 0 {
            listener = try NWListener(using: parameters)
        } else {
            guard let port = NWEndpoint.Port(rawValue: preferredPort) else {
                throw RemoteError.invalidPort
            }
            listener = try NWListener(using: parameters, on: port)
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
                self?.lastError = error.localizedDescription
                ChronoLog.remote.error("Web remote failed: \(error.localizedDescription, privacy: .public)")
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

/// The smallest HTTP request parser that is correct for our purposes.
struct HTTPRequest {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data

    /// Returns `nil` while the request is still incomplete, so the caller keeps reading.
    init?(raw: Data) {
        guard let separator = raw.range(of: Data("\r\n\r\n".utf8)) else { return nil }

        let headerData = raw[raw.startIndex..<separator.lowerBound]
        guard let headerText = String(data: headerData, encoding: .utf8) else { return nil }

        var lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        lines.removeFirst()

        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        method = String(parts[0]).uppercased()
        // Strip any query string; nothing here uses one.
        path = String(parts[1]).components(separatedBy: "?")[0]

        var parsed: [String: String] = [:]
        for line in lines where line.contains(":") {
            let pieces = line.split(separator: ":", maxSplits: 1)
            guard pieces.count == 2 else { continue }
            parsed[pieces[0].trimmingCharacters(in: .whitespaces).lowercased()] =
                pieces[1].trimmingCharacters(in: .whitespaces)
        }
        headers = parsed

        let expectedLength = Int(parsed["content-length"] ?? "0") ?? 0
        let bodyStart = separator.upperBound
        let available = raw.distance(from: bodyStart, to: raw.endIndex)
        guard available >= expectedLength else { return nil }   // keep reading

        body = expectedLength > 0
            ? raw[bodyStart..<raw.index(bodyStart, offsetBy: expectedLength)]
            : Data()
    }
}
