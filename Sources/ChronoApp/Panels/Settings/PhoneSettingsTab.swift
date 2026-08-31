import SwiftUI
import ChronoCore

/// The optional phone remote.
///
/// Framed honestly as a bonus: the copy makes clear the Mac app is complete without it, because
/// a feature that looks mandatory but needs Xcode would be a bad first impression.
struct PhoneSettingsTab: View {
    @Environment(AppEnvironment.self) private var environment

    private var bind: SettingsBinding { SettingsBinding(environment: environment) }
    private var settings: TrackerSettings { environment.engine.settings }
    private var remote: RemoteCoordinator { environment.remote }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.section) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Control Chrono from your phone")
                    .font(.system(size: 18, weight: .semibold))
                Text("Entirely optional. Everything on this Mac works without it — this is for the times you walk away from your desk mid-task and want to hit pause from the corridor.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            SettingsGroup(
                "Over your local network",
                footnote: "Your Mac serves a small web page that your phone opens in Safari. Nothing is installed, nothing expires, and no traffic leaves your network."
            ) {
                Toggle("Enable the phone web remote", isOn: Binding(
                    get: { settings.webRemoteEnabled },
                    set: { enabled in
                        environment.mutateSettings { $0.webRemoteEnabled = enabled }
                        remote.applySettings(environment.engine.settings)
                    }
                ))
                .font(.system(size: 12, weight: .medium))

                if settings.webRemoteEnabled {
                    Divider()
                    statusRow(
                        label: "Status",
                        value: remote.webPort.map { "Listening on port \($0)" } ?? (remote.webError ?? "Starting…"),
                        healthy: remote.webPort != nil
                    )
                    if let payload = remote.pairingPayload() {
                        statusRow(label: "Address", value: "\(payload.host):\(payload.port)", healthy: true)
                    }
                    Button("Show the pairing code…") {
                        WindowManager.shared.showPairing(environment: environment)
                    }
                    .buttonStyle(FilledButtonStyle(compact: true))
                    .disabled(remote.webPort == nil)
                }
            }

            SettingsGroup(
                "Over Bluetooth",
                footnote: "For the companion iOS app, which talks to this Mac directly over Bluetooth LE — no Wi-Fi needed, so it keeps working when you leave the building. Build it from the ios/ folder in the repository."
            ) {
                Toggle("Advertise over Bluetooth LE", isOn: Binding(
                    get: { settings.bluetoothRemoteEnabled },
                    set: { enabled in
                        environment.mutateSettings { $0.bluetoothRemoteEnabled = enabled }
                        remote.applySettings(environment.engine.settings)
                    }
                ))
                .font(.system(size: 12, weight: .medium))

                if settings.bluetoothRemoteEnabled {
                    Divider()
                    statusRow(
                        label: "Status",
                        value: remote.bluetoothStatus.description,
                        healthy: remote.bluetoothStatus.isHealthy
                    )
                }
            }

            SettingsGroup(
                "Safety",
                footnote: "Every command must be signed with the pairing secret, which only ever reaches your phone through the QR code. Replays are rejected by a counter and a two-minute freshness window."
            ) {
                Toggle("Ask me before a phone can stop a timer", isOn: bind.bind(\.remoteConfirmDestructiveActions))
                    .font(.system(size: 11.5))
                    .help("A phone can always pause; stopping also pushes a worklog to Jira")

                if let last = remote.lastCommand {
                    Divider()
                    statusRow(
                        label: "Last phone command",
                        value: "\(last.description) · \(last.at.formatted(date: .omitted, time: .shortened))",
                        healthy: true
                    )
                }
                if remote.rejectedCommandCount > 0 {
                    statusRow(
                        label: "Rejected commands",
                        value: "\(remote.rejectedCommandCount)",
                        healthy: false
                    )
                }

                Divider()
                Button("Unpair every device") {
                    remote.rotateSecret()
                    environment.show(.init(kind: .info, message: "Paired devices removed. Re-scan to pair again."))
                }
                .buttonStyle(QuietButtonStyle(tint: .red, compact: true))
                .help("Replaces the pairing secret, which immediately invalidates every paired phone")
            }
        }
    }

    private func statusRow(label: String, value: String, healthy: Bool) -> some View {
        HStack(spacing: Theme.Spacing.small) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
            Circle()
                .fill(healthy ? Color.green : Color.orange)
                .frame(width: 6, height: 6)
            Text(value)
                .font(.system(size: 11, weight: .medium))
        }
    }
}
