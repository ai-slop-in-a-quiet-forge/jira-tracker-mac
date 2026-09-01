import SwiftUI
import AppKit
import CoreImage.CIFilterBuiltins
import ChronoCore

/// Shows the QR code that pairs a phone with this Mac.
///
/// The secret rides in the URL's fragment, which browsers never transmit, so scanning the code
/// is the only time it moves — and it moves optically rather than over the network.
struct PairingView: View {
    @Environment(AppEnvironment.self) private var environment

    private var payload: PairingPayload? { environment.remote.pairingPayload() }

    var body: some View {
        VStack(spacing: Theme.Spacing.large) {
            VStack(spacing: 4) {
                Text("Pair your phone")
                    .font(.system(size: 18, weight: .semibold))
                Text("Point your phone's camera at this code.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
            .padding(.top, Theme.Spacing.section)

            if let payload, let url = payload.pairingURL() {
                qrCode(for: url)

                VStack(spacing: 6) {
                    if let host = payload.host, let port = payload.port {
                        Text("\(host):\(port)")
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                        Text("Then tap Share ▸ Add to Home Screen, and it behaves like an app.")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    } else {
                        Text("Bluetooth only")
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                        Text("Scan this from the Chrono Remote app on your iPhone — there is no web page to open.")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                }

                steps(reachesWebRemote: payload.reachesWebRemote)
                Spacer()
                footer(url: url)
            } else {
                Spacer()
                unavailable
                Spacer()
            }
        }
        .padding(Theme.Spacing.large)
        .frame(width: 520)
    }

    private func qrCode(for url: URL) -> some View {
        Group {
            if let image = Self.makeQRCode(from: url.absoluteString, side: 240) {
                Image(nsImage: image)
                    .interpolation(.none)   // keep the modules crisp
                    .padding(Theme.Spacing.medium)
                    .background(.white, in: RoundedRectangle(cornerRadius: 12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(.separator, lineWidth: 0.5)
                    )
            } else {
                EmptyStateView(
                    systemImage: "qrcode",
                    title: "Could not draw the code",
                    message: "Open this address on your phone instead: \(url.absoluteString)"
                )
            }
        }
    }

    /// The instructions differ by transport, and getting them wrong is worse than showing none:
    /// telling someone to join the same Wi-Fi when the code only pairs over Bluetooth sends
    /// them looking for a fault that is not there.
    private func steps(reachesWebRemote: Bool) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            if reachesWebRemote {
                step(1, "Make sure your phone is on the same Wi-Fi as this Mac.")
                step(2, "Scan the code and open the link.")
                step(3, "Add it to your Home Screen so it opens full-screen.")
            } else {
                step(1, "Open the Chrono Remote app on your iPhone.")
                step(2, "Tap “Scan the code” and point it at this.")
                step(3, "Keep the phone within Bluetooth range — no Wi-Fi needed.")
            }
        }
        .padding(Theme.Spacing.medium)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: Theme.cardRadius))
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: Theme.Spacing.small) {
            Text("\(number)")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 16, height: 16)
                .background(Color.accentColor, in: Circle())
            Text(text)
                .font(.system(size: 11.5))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func footer(url: URL) -> some View {
        HStack {
            Button("Copy link") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url.absoluteString, forType: .string)
                environment.show(.init(kind: .info, message: "Pairing link copied. It contains the secret — send it carefully."))
            }
            .buttonStyle(QuietButtonStyle(compact: true))
            .help("The link contains the pairing secret, so treat it like a password")

            Button("New code") {
                environment.remote.rotateSecret()
            }
            .buttonStyle(QuietButtonStyle(tint: .red, compact: true))
            .help("Unpairs every device and generates a fresh secret")

            Spacer()
            Button("Done") { WindowManager.shared.close(.pairing) }
                .buttonStyle(FilledButtonStyle(compact: true))
        }
    }

    private var unavailable: some View {
        VStack(spacing: Theme.Spacing.medium) {
            EmptyStateView(
                systemImage: "wifi.exclamationmark",
                title: "No phone remote is running",
                message: environment.engine.settings.webRemoteEnabled
                    ? (environment.remote.webError ?? "Chrono could not find a network address for this Mac. Check that Wi-Fi or Ethernet is connected, or turn on Bluetooth instead — that pairs without a network.")
                    : "Turn on the web remote or Bluetooth in Settings ▸ Phone first. Either one is enough to pair."
            )
            Button("Open Settings") { WindowManager.shared.showSettings(environment: environment) }
                .buttonStyle(FilledButtonStyle(compact: true))
        }
    }

    /// Renders a QR code with CoreImage — no dependency needed.
    static func makeQRCode(from text: String, side: CGFloat) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        // Medium correction: enough robustness for a phone camera without bloating the code.
        filter.correctionLevel = "M"

        guard let output = filter.outputImage else { return nil }
        // CoreImage emits one pixel per module, so scale up before rasterising.
        let scale = side / output.extent.width
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        let context = CIContext()
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: side, height: side))
    }
}
