import AppKit
import Foundation
import Observation
import ChronoCore

/// Runs the phone remote over both transports and executes what the phone asks for.
///
/// Both transports are optional and off by default. Everything here is additive: with the
/// remote disabled, the Mac app behaves exactly as it otherwise would.
@MainActor
@Observable
final class RemoteCoordinator {

    /// Set by `AppEnvironment` after construction. Weak, because the environment owns this.
    weak var environment: AppEnvironment?

    private(set) var bluetoothStatus: BLEPeripheral.Status = .stopped
    private(set) var webPort: UInt16?
    private(set) var webError: String?
    /// The last command a phone sent, for the "recent activity" line in Settings — it should be
    /// visible when something else is driving your timer.
    private(set) var lastCommand: (description: String, at: Date)?
    private(set) var rejectedCommandCount = 0

    private let keychain: KeychainStore
    private let ble: BLEPeripheral
    private let web = WebRemoteServer()
    private let verifier: RemoteCommandVerifier
    /// Incremented on every state change so the phone can discard stale notifications.
    private var revision = 0

    init(keychain: KeychainStore) {
        self.keychain = keychain
        self.ble = BLEPeripheral(deviceName: Self.shortDeviceName())
        self.verifier = RemoteCommandVerifier(secret: keychain.remotePairingSecret())
        wire()
    }

    /// `Abhishek's MacBook Pro` -> `MacBook Pro`, since BLE advertisement names are tiny.
    private static func shortDeviceName() -> String {
        let full = Host.current().localizedName ?? "Mac"
        if let range = full.range(of: "’s ") ?? full.range(of: "'s ") {
            return String(full[range.upperBound...])
        }
        return full
    }

    static var deviceName: String {
        Host.current().localizedName ?? "This Mac"
    }

    // MARK: - Wiring

    private func wire() {
        ble.stateProvider = { [weak self] in
            (try? JSONEncoder().encode(self?.snapshot() ?? .disconnected)) ?? Data()
        }
        ble.infoProvider = { [weak self] in
            let info = RemoteInfo(
                deviceName: Self.deviceName,
                paired: self?.keychain.value(for: .remotePairingSecret) != nil
            )
            return (try? JSONEncoder().encode(info)) ?? Data()
        }
        ble.commandHandler = { [weak self] data in
            await self?.handleSignedEnvelope(data) ?? Data()
        }
        ble.onStatusChange = { [weak self] status in
            self?.bluetoothStatus = status
        }

        web.stateProvider = { [weak self] in
            self?.webStateJSON() ?? Data()
        }
        web.commandHandler = { [weak self] body, counter, timestamp, mac, deviceID in
            await self?.handleWebRequest(
                body: body, counter: counter, timestamp: timestamp, mac: mac, deviceID: deviceID
            ) ?? (503, Data())
        }
    }

    // MARK: - Enable / disable

    /// Brings both transports in line with the current settings. Idempotent.
    func applySettings(_ settings: TrackerSettings) {
        if settings.bluetoothRemoteEnabled {
            ble.start()
        } else if ble.isRunning {
            ble.stop()
        }

        if settings.webRemoteEnabled {
            if !web.isRunning {
                do {
                    try web.start(preferredPort: UInt16(max(0, min(settings.webRemotePort, 65_535))))
                    webError = nil
                    // The port is assigned asynchronously once the listener is ready.
                    Task { [weak self] in
                        for _ in 0..<20 {
                            try? await Task.sleep(for: .milliseconds(100))
                            if let port = self?.web.port {
                                self?.webPort = port
                                return
                            }
                        }
                        self?.webError = self?.web.lastError ?? "The remote could not start."
                    }
                } catch {
                    webError = error.localizedDescription
                }
            }
        } else if web.isRunning {
            web.stop()
            webPort = nil
        }
    }

    func stop() {
        ble.stop()
        web.stop()
        webPort = nil
    }

    var isAnyTransportActive: Bool {
        bluetoothStatus.isHealthy || webPort != nil
    }

    // MARK: - Pairing

    /// The pairing code for whichever transports are running.
    ///
    /// Deliberately not gated on the web remote. The phone stores only the secret, so a
    /// Bluetooth-only setup is pairable with no LAN address at all — and it has to be, or the
    /// transport sold as working "when you leave the building" could never be set up.
    func pairingPayload() -> PairingPayload? {
        guard isAnyTransportActive else { return nil }
        // Only advertise an address when the web remote is actually reachable at one.
        let host = webPort == nil ? nil : NetworkInterface.bestLocalAddress()
        return PairingPayload(
            host: host,
            port: host == nil ? nil : webPort.map(Int.init),
            secret: keychain.remotePairingSecret(),
            deviceName: Self.deviceName
        )
    }

    /// Invalidates every paired device.
    func rotateSecret() {
        let secret = keychain.rotateRemotePairingSecret()
        Task { await verifier.updateSecret(secret) }
        rejectedCommandCount = 0
        lastCommand = nil
    }

    // MARK: - State

    func snapshot() -> RemoteSnapshot {
        guard let environment else { return .disconnected }
        let engine = environment.engine
        let settings = engine.settings

        let status: RemoteStatus
        switch engine.status {
        case .idle: status = .idle
        case .running: status = .running
        case .paused: status = .paused
        }

        let inMeeting = settings.meetingDetectionEnabled
            && environment.activity.snapshot.meetingSignal(settings: settings) != nil

        return RemoteSnapshot(
            status: status,
            label: engine.activeTarget?.shortLabel ?? "",
            elapsed: Int(engine.currentSegmentElapsed),
            todaySeconds: Int(engine.todayRollup.workSeconds),
            targetSeconds: Int(settings.dailyTargetHours * 3600),
            pendingDrafts: environment.sync.pendingCount,
            unfiledSeconds: Int(engine.unfiledSecondsToday),
            inMeeting: inMeeting,
            revision: revision
        )
    }

    /// Richer payload for the web remote, which is not squeezed into a BLE packet.
    private struct WebRemoteState: Encodable {
        let s: Int
        let l: String
        let e: Int
        let d: Int
        let t: Int
        let q: Int
        let u: Int
        let m: Bool
        let r: Int
        let sum: String
        let name: String
        let recents: [RemoteIssueOption]
    }

    private func webStateJSON() -> Data {
        let snapshot = self.snapshot()
        var summary = ""
        if case .issue(let ref) = environment?.engine.activeTarget { summary = ref.summary }

        let recents = (environment?.engine.state.recentIssues.prefix(6) ?? []).map {
            RemoteIssueOption(key: $0.key, summary: $0.summary)
        }

        let state = WebRemoteState(
            s: snapshot.status.rawValue,
            l: snapshot.label,
            e: snapshot.elapsed,
            d: snapshot.todaySeconds,
            t: snapshot.targetSeconds,
            q: snapshot.pendingDrafts,
            u: snapshot.unfiledSeconds,
            m: snapshot.inMeeting,
            r: snapshot.revision,
            sum: summary,
            name: Self.deviceName,
            recents: Array(recents)
        )
        return (try? JSONEncoder().encode(state)) ?? Data()
    }

    /// Called whenever the timer changes, so subscribed phones update promptly.
    func publish() {
        revision += 1
        ble.publishState()
    }

    // MARK: - Command handling

    /// BLE path: the whole signed envelope arrives as one JSON blob.
    private func handleSignedEnvelope(_ data: Data) async -> Data {
        guard let envelope = try? JSONDecoder().decode(SignedEnvelope.self, from: data) else {
            rejectedCommandCount += 1
            return encode(RemoteCommandResult(accepted: false, message: "Malformed command"))
        }
        do {
            let command = try await verifier.verify(envelope)
            return encode(execute(command))
        } catch let rejection as RemoteCommandVerifier.Rejection {
            rejectedCommandCount += 1
            ChronoLog.remote.error("Rejected BLE command: \(rejection.userFacingReason, privacy: .public)")
            return encode(RemoteCommandResult(accepted: false, message: rejection.userFacingReason))
        } catch {
            rejectedCommandCount += 1
            return encode(RemoteCommandResult(accepted: false, message: "Rejected"))
        }
    }

    /// Web path: the signature arrives in headers alongside the raw body.
    private func handleWebRequest(
        body: Data,
        counter: UInt64,
        timestamp: Int64,
        mac: Data,
        deviceID: String
    ) async -> (status: Int, body: Data) {
        // A state read signs the path rather than a body; there is no command to decode.
        let isStateRead = String(decoding: body, as: UTF8.self) == "/state"

        do {
            if isStateRead {
                try await verifier.verifySignatureOnly(
                    payload: body, counter: counter, timestamp: timestamp, mac: mac, deviceID: deviceID
                )
                return (200, webStateJSON())
            }
            let command = try await verifier.verifyRequest(
                body: body, counter: counter, timestamp: timestamp, mac: mac, deviceID: deviceID
            )
            return (200, encode(execute(command)))
        } catch let rejection as RemoteCommandVerifier.Rejection {
            rejectedCommandCount += 1
            ChronoLog.remote.error("Rejected web command: \(rejection.userFacingReason, privacy: .public)")
            let status = rejection == .notPaired ? 403 : 401
            return (status, encode(RemoteCommandResult(accepted: false, message: rejection.userFacingReason)))
        } catch {
            rejectedCommandCount += 1
            return (401, encode(RemoteCommandResult(accepted: false, message: "Rejected")))
        }
    }

    private func encode(_ result: RemoteCommandResult) -> Data {
        (try? JSONEncoder().encode(result)) ?? Data()
    }

    /// Executes a verified command.
    private func execute(_ command: RemoteCommand) -> RemoteCommandResult {
        guard let environment else {
            return RemoteCommandResult(accepted: false, message: "Chrono is not ready")
        }
        lastCommand = (command.auditDescription, Date())

        // "Stop" ends a session and pushes a worklog. When the user has asked for a
        // confirmation, downgrade it to a pause instead of refusing outright — pausing is
        // always safe, and nothing is lost.
        if command.isDestructive, environment.engine.settings.remoteConfirmDestructiveActions {
            if environment.engine.isRunning {
                environment.engine.pause(reason: .remote)
                environment.notifier.post(
                    title: "Paused from your phone",
                    body: "Stopping needs confirming here. Open Chrono to log the time.",
                    category: .nudge
                )
                publish()
                return RemoteCommandResult(
                    accepted: true,
                    message: "Paused — confirm the stop on your Mac",
                    snapshot: snapshot()
                )
            }
            return RemoteCommandResult(accepted: false, message: "Confirm on your Mac")
        }

        switch command {
        case .pause:
            guard environment.engine.isRunning else {
                return RemoteCommandResult(accepted: false, message: "Nothing is running", snapshot: snapshot())
            }
            environment.engine.pause(reason: .remote)
            return accepted("Paused")

        case .resume:
            guard environment.engine.isPaused else {
                return RemoteCommandResult(accepted: false, message: "Nothing to resume", snapshot: snapshot())
            }
            environment.engine.resume(source: .remote)
            return accepted("Resumed")

        case .resumeLast:
            environment.resumeLastTarget()
            return accepted(environment.engine.isRunning ? "Resumed" : "Nothing to resume")

        case .stop:
            guard !environment.engine.status.isIdle else {
                return RemoteCommandResult(accepted: false, message: "Nothing is running", snapshot: snapshot())
            }
            environment.stop()
            return accepted("Stopped and queued for Jira")

        case .switchToMeeting:
            environment.switchToMeeting(source: .remote)
            return accepted("Logging this as a meeting")

        case .startIssue(let key):
            let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            guard !trimmed.isEmpty else {
                return RemoteCommandResult(accepted: false, message: "No issue given")
            }
            // Prefer the cached issue so the phone's list shows a real summary.
            let cached = environment.engine.state.recentIssues.first { $0.key == trimmed }
                ?? environment.engine.state.pinnedIssues.first { $0.key == trimmed }
            environment.start(issue: cached ?? IssueRef(key: trimmed), source: .remote)
            return accepted("Tracking \(trimmed)")

        case .snooze(let minutes):
            let clamped = max(5, min(minutes, 12 * 60))
            environment.activity.snooze(minutes: clamped)
            return accepted("Reminders silenced for \(clamped) minutes")

        case .note(let text):
            environment.engine.setNote(text)
            return accepted("Note saved")

        case .refresh:
            return accepted("Up to date")
        }
    }

    private func accepted(_ message: String) -> RemoteCommandResult {
        publish()
        return RemoteCommandResult(accepted: true, message: message, snapshot: snapshot())
    }
}
