import SwiftUI

@main
struct ChronoRemoteApp: App {
    @State private var store = PairingStore()
    @State private var client: BLEClient

    init() {
        let store = PairingStore()
        _store = State(initialValue: store)
        _client = State(initialValue: BLEClient(store: store))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .environment(client)
                .preferredColorScheme(.dark)
        }
    }
}

struct RootView: View {
    @Environment(PairingStore.self) private var store
    @Environment(BLEClient.self) private var client
    /// Owned here rather than by `BLEClient` so the transport stays free of UI concerns — the
    /// same reason `ChronoCore` has no AppKit in it.
    @State private var liveActivity = LiveActivityController()

    var body: some View {
        Group {
            if store.isPaired {
                RemoteView()
            } else {
                PairingIntroView()
            }
        }
        .onChange(of: store.isPaired) { _, paired in
            if paired {
                client.start()
            } else {
                client.stop()
                // An unpaired phone cannot learn that the timer stopped, so leaving a Live
                // Activity behind would strand a frozen timer on the Lock Screen forever.
                liveActivity.end()
            }
        }
        .onAppear { if store.isPaired { client.start() } }
        // `snapshot` changes only when the Mac pushes a notification, not on every local tick,
        // and the controller throttles further. Both matter: ActivityKit drops updates from an
        // app that asks too often.
        .onChange(of: client.snapshot) { _, snapshot in
            liveActivity.apply(
                snapshot: snapshot,
                macName: store.macName,
                connected: client.connection.isConnected
            )
        }
        // Losing the Mac does not stop the timer, but it does mean this phone can no longer
        // vouch for what it is showing — the activity is marked stale rather than ended.
        .onChange(of: client.connection) { _, _ in
            liveActivity.apply(
                snapshot: client.snapshot,
                macName: store.macName,
                connected: client.connection.isConnected
            )
        }
    }
}
