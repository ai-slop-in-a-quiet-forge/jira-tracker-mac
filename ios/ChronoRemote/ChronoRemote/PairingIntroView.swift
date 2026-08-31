import SwiftUI

/// First-run pairing: scan the same QR code the Mac shows for the web remote.
///
/// Reusing one code for both transports means there is a single pairing concept to explain, and
/// the secret only ever moves optically.
struct PairingIntroView: View {
    @Environment(PairingStore.self) private var store
    @State private var scanning = false
    @State private var failure: String?

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "qrcode.viewfinder")
                .font(.system(size: 64))
                .foregroundStyle(.blue)

            VStack(spacing: 8) {
                Text("Pair with your Mac")
                    .font(.title2.weight(.semibold))
                Text("On your Mac, open Chrono ▸ Settings ▸ Phone and show the pairing code. Then scan it here.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal)

            if let failure {
                Text(failure)
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }

            Spacer()

            Button {
                failure = nil
                scanning = true
            } label: {
                Text("Scan the code").frame(maxWidth: .infinity)
            }
            .buttonStyle(BigButton(tint: .blue))
            .padding(.horizontal)

            Text("Once paired, this app talks to your Mac over Bluetooth — no Wi-Fi needed.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
                .padding(.bottom)
        }
        .background(Color.black.ignoresSafeArea())
        .sheet(isPresented: $scanning) {
            QRScannerView { scanned in
                scanning = false
                guard let parsed = PairingStore.parse(pairingURL: scanned) else {
                    failure = "That does not look like a Chrono pairing code."
                    return
                }
                store.store(secret: parsed.secret, macName: parsed.name)
            }
        }
    }
}
