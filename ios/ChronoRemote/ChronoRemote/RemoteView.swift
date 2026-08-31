import SwiftUI

/// The remote itself. Big targets, one obvious action, readable at arm's length while walking
/// down a corridor — which is the actual usage context.
struct RemoteView: View {
    @Environment(PairingStore.self) private var store
    @Environment(BLEClient.self) private var client
    @State private var showingUnpairConfirmation = false

    private var snapshot: RemoteSnapshot? { client.snapshot }
    private var isRunning: Bool { snapshot?.status == .running }
    private var isPaused: Bool { snapshot?.status == .paused }
    // Treat "no snapshot yet" as idle: before the first notification arrives there is
    // nothing running as far as this phone knows.
    private var isIdle: Bool { (snapshot?.status ?? .idle) == .idle }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    connectionRow
                    if let snapshot, snapshot.inMeeting, isRunning {
                        meetingBanner(snapshot: snapshot)
                    }
                    statusCard
                    controls
                    if let message = client.lastMessage {
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(.orange)
                            .multilineTextAlignment(.center)
                    }
                }
                .padding()
            }
            .background(Color.black.ignoresSafeArea())
            .navigationTitle("Chrono")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Unpair") { showingUnpairConfirmation = true }
                        .font(.footnote)
                }
            }
            .confirmationDialog(
                "Unpair from \(store.macName)?",
                isPresented: $showingUnpairConfirmation,
                titleVisibility: .visible
            ) {
                Button("Unpair", role: .destructive) { store.unpair() }
                Button("Cancel", role: .cancel) {}
            }
        }
    }

    // MARK: - Pieces

    private var connectionRow: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(client.connection.isConnected ? .green : .orange)
                .frame(width: 9, height: 9)
            Text(client.connection.description)
                .font(.footnote)
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    private func meetingBanner(snapshot: RemoteSnapshot) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "person.2.wave.2.fill")
            Text("Your Mac thinks you're on a call, and \(snapshot.label.isEmpty ? "a task" : snapshot.label) is still tracking.")
                .font(.subheadline)
            Spacer(minLength: 0)
        }
        .padding()
        .foregroundStyle(.orange)
        .background(.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: 14))
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(statusLabel.uppercased())
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            Text(snapshot?.label.isEmpty == false ? snapshot!.label : "Nothing selected")
                .font(.title2.weight(.semibold))

            Text(clock(isRunning ? client.displayElapsed : (snapshot?.elapsed ?? 0)))
                .font(.system(size: 58, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(isPaused ? .orange : (isIdle ? .secondary : .primary))
                .contentTransition(.numericText())

            if let snapshot {
                HStack(spacing: 12) {
                    ProgressView(
                        value: Double(snapshot.todaySeconds),
                        total: Double(max(1, snapshot.targetSeconds))
                    )
                    .tint(.blue)
                    Text("\(humane(snapshot.todaySeconds)) / \(humane(snapshot.targetSeconds))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .padding(.top, 4)

                if snapshot.pendingDrafts > 0 || snapshot.unfiledSeconds > 0 {
                    HStack(spacing: 10) {
                        if snapshot.pendingDrafts > 0 {
                            Label("\(snapshot.pendingDrafts) queued", systemImage: "arrow.up.circle")
                        }
                        if snapshot.unfiledSeconds > 0 {
                            Label("\(humane(snapshot.unfiledSeconds)) unfiled", systemImage: "questionmark.circle")
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(Color(white: 0.09), in: RoundedRectangle(cornerRadius: 20))
    }

    private var statusLabel: String {
        if isRunning { return "Tracking" }
        if isPaused { return "Paused" }
        return "Not tracking"
    }

    private var controls: some View {
        VStack(spacing: 10) {
            Button {
                if isRunning { act(.pause) }
                else if isPaused { act(.resume) }
                else { act(.resumeLast) }
            } label: {
                Text(isRunning ? "Pause" : (isPaused ? "Resume" : "Resume last task"))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(BigButton(tint: .blue))

            HStack(spacing: 10) {
                Button {
                    act(.switchToMeeting)
                } label: {
                    VStack(spacing: 2) {
                        Text("Meeting")
                        Text("log this as a call").font(.caption2).opacity(0.7)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(BigButton(tint: .orange.opacity(0.25), foreground: .orange))
                .disabled(isIdle)

                Button {
                    act(.stop)
                } label: {
                    VStack(spacing: 2) {
                        Text("Stop")
                        Text("log the time").font(.caption2).opacity(0.7)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(BigButton(tint: .red.opacity(0.22), foreground: .red))
                .disabled(isIdle)
            }

            Button {
                act(.snooze(minutes: 30))
            } label: {
                Text("Silence reminders for 30 min").frame(maxWidth: .infinity)
            }
            .buttonStyle(BigButton(tint: Color(white: 0.13), foreground: .primary))
        }
        .disabled(!client.connection.isConnected)
        .opacity(client.connection.isConnected ? 1 : 0.5)
    }

    private func act(_ command: RemoteCommand) {
        client.optimistically(apply: command)
        client.send(command)
    }

    // MARK: - Formatting

    private func clock(_ seconds: Int) -> String {
        let total = max(0, seconds)
        let (h, m, s) = (total / 3600, (total % 3600) / 60, total % 60)
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }

    private func humane(_ seconds: Int) -> String {
        let total = max(0, seconds)
        if total < 60 { return "\(total)s" }
        let (h, m) = (total / 3600, (total % 3600) / 60)
        if h == 0 { return "\(m)m" }
        if m == 0 { return "\(h)h" }
        return "\(h)h \(m)m"
    }
}

struct BigButton: ButtonStyle {
    var tint: Color
    var foreground: Color = .white

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(foreground)
            .padding(.vertical, 18)
            .background(tint.opacity(configuration.isPressed ? 0.7 : 1), in: RoundedRectangle(cornerRadius: 16))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
    }
}
