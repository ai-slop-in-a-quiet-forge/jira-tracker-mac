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

    var body: some View {
        Group {
            if store.isPaired {
                RemoteView()
            } else {
                PairingIntroView()
            }
        }
        .onChange(of: store.isPaired) { _, paired in
            if paired { client.start() } else { client.stop() }
        }
        .onAppear { if store.isPaired { client.start() } }
    }
}
