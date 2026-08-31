import SwiftUI
import AppKit
import ChronoCore

/// The menu bar popover: the surface the user sees dozens of times a day.
///
/// Structured so the answer to "what am I tracking and how is my day going" is readable in a
/// glance without scrolling, and starting a different task is one click from there.
struct PanelView: View {
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        VStack(spacing: 0) {
            if let flash = environment.flash {
                FlashBanner(flash: flash) { environment.dismissFlash() }
            }

            VStack(spacing: Theme.Spacing.medium) {
                NowTrackingCard()
                DaySummary()
            }
            .padding(.horizontal, Theme.Spacing.large)
            .padding(.top, Theme.Spacing.large)
            .padding(.bottom, Theme.Spacing.medium)

            Divider()
            PanelList()
            Divider()
            PanelFooter()
        }
        .frame(width: Theme.panelWidth)
        .background(.regularMaterial)
        .onAppear { environment.engine.tick() }
    }
}

// MARK: - Flash banner

struct FlashBanner: View {
    let flash: AppEnvironment.Flash
    let onDismiss: () -> Void

    private var tint: Color {
        switch flash.kind {
        case .success: return .green
        case .warning: return .orange
        case .failure: return .red
        case .info: return .accentColor
        }
    }

    private var symbol: String {
        switch flash.kind {
        case .success: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .failure: return "xmark.octagon.fill"
        case .info: return "info.circle.fill"
        }
    }

    var body: some View {
        HStack(spacing: Theme.Spacing.small) {
            Image(systemName: symbol).font(.system(size: 11))
            Text(flash.message).font(.system(size: 11, weight: .medium))
            Spacer(minLength: 0)
            Button(action: onDismiss) {
                Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
            }
            .buttonStyle(.plain)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, Theme.Spacing.large)
        .padding(.vertical, Theme.Spacing.small)
        .background(tint.opacity(0.12))
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}

// MARK: - Now tracking

/// The hero card: what is running, for how long, and the controls to change that.
struct NowTrackingCard: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var noteDraft = ""
    @State private var showingNoteField = false
    @FocusState private var noteFocused: Bool

    private var engine: TrackingEngine { environment.engine }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
                switch engine.status {
                case .idle:
                    idleState
                case .running(let target, _):
                    activeState(target: target, running: true)
                case .paused(let target, _):
                    activeState(target: target, running: false)
                }
            }
        }
    }

    // MARK: Idle

    private var idleState: some View {
        HStack(spacing: Theme.Spacing.medium) {
            Image(systemName: "clock")
                .font(.system(size: 20))
                .foregroundStyle(.tertiary)
            VStack(alignment: .leading, spacing: 2) {
                Text("Not tracking")
                    .font(.system(size: 13, weight: .semibold))
                Text(engine.state.recentIssues.first.map { "Last: \($0.key)" } ?? "Pick something below to start")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if let recent = engine.state.recentIssues.first {
                Button("Resume \(recent.key)") { environment.start(issue: recent) }
                    .buttonStyle(FilledButtonStyle(compact: true))
            }
        }
    }

    // MARK: Running / paused

    private func activeState(target: TrackingTarget, running: Bool) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            HStack(alignment: .top, spacing: Theme.Spacing.small) {
                StatusDot(running: running)
                    .padding(.top, 4)

                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 5) {
                        TargetIcon(target: target, size: 11)
                        Text(target.shortLabel)
                            .font(.system(size: 12.5, weight: .semibold))
                        if !running {
                            Chip(text: "Paused", systemImage: "pause.fill", tint: .orange)
                        }
                        if environment.canReturnFromMeeting {
                            Button("Back to work") { environment.returnFromMeeting() }
                                .buttonStyle(QuietButtonStyle(tint: .accentColor, compact: true))
                        }
                    }
                    if case .issue(let ref) = target, !ref.summary.isEmpty {
                        Text(ref.summary)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }

            HStack(alignment: .firstTextBaseline) {
                TimerText(
                    seconds: running ? engine.currentSegmentElapsed : engine.activeTargetTodayElapsed,
                    size: 30,
                    showSeconds: engine.settings.showSecondsInMenuBar || running
                )
                .foregroundStyle(running ? Color.primary : Color.secondary)

                if engine.activeTargetTodayElapsed > engine.currentSegmentElapsed + 1 {
                    Text("· \(DurationFormat.humane(engine.activeTargetTodayElapsed)) today")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                }

                Spacer(minLength: 0)
                controls(running: running)
            }

            noteRow(target: target)
        }
    }

    private func controls(running: Bool) -> some View {
        HStack(spacing: Theme.Spacing.tight) {
            Button {
                environment.togglePauseResume()
            } label: {
                Image(systemName: running ? "pause.fill" : "play.fill")
            }
            .buttonStyle(IconButtonStyle(tint: running ? .orange : .accentColor))
            .help(running ? "Pause (keeps the task selected)" : "Resume")

            Button {
                environment.stop()
            } label: {
                Image(systemName: "stop.fill")
            }
            .buttonStyle(IconButtonStyle(tint: .red))
            .help("Stop and log the time")

            Menu {
                Button("Add 5 minutes to the start") { _ = environment.engine.backdateStart(by: 300) }
                Button("Add 15 minutes to the start") { _ = environment.engine.backdateStart(by: 900) }
                Divider()
                Button("Discard this session") { environment.engine.discardOpenSegment() }
                if case .adhoc = environment.engine.activeTarget {
                    Divider()
                    Button("Assign this to an issue…") {
                        WindowManager.shared.showTimesheet(environment: environment)
                    }
                }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .frame(width: 22)
            .help("More")
        }
    }

    /// The note becomes the Jira worklog comment. Collapsed until asked for, so the card stays
    /// calm when there is nothing to say.
    private func noteRow(target: TrackingTarget) -> some View {
        Group {
            if showingNoteField || !(engine.state.openSegmentNote ?? "").isEmpty {
                HStack(spacing: Theme.Spacing.small) {
                    Image(systemName: "text.alignleft")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                    TextField("What are you doing? (becomes the worklog comment)", text: $noteDraft)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11))
                        .focused($noteFocused)
                        .onSubmit { engine.setNote(noteDraft) }
                        .onChange(of: noteDraft) { _, newValue in engine.setNote(newValue) }
                }
                .padding(.horizontal, Theme.Spacing.small)
                .padding(.vertical, 5)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 7))
            } else {
                Button {
                    showingNoteField = true
                    noteFocused = true
                } label: {
                    Label("Add a note", systemImage: "text.alignleft")
                        .font(.system(size: 10.5))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
            }
        }
        .onAppear { noteDraft = engine.state.openSegmentNote ?? "" }
        .onChange(of: target.id) { _, _ in
            noteDraft = engine.state.openSegmentNote ?? ""
            showingNoteField = false
        }
    }
}

/// Pulsing dot for the running state; static for paused.
struct StatusDot: View {
    let running: Bool
    @State private var pulsing = false

    var body: some View {
        Circle()
            .fill(running ? Color.accentColor : Color.orange)
            .frame(width: 7, height: 7)
            .overlay(
                Circle()
                    .stroke(running ? Color.accentColor : Color.orange, lineWidth: 1)
                    .scaleEffect(pulsing ? 2.2 : 1)
                    .opacity(pulsing ? 0 : 0.7)
            )
            .onAppear {
                guard running else { return }
                withAnimation(.easeOut(duration: 1.6).repeatForever(autoreverses: false)) {
                    pulsing = true
                }
            }
    }
}

// MARK: - Day summary

struct DaySummary: View {
    @Environment(AppEnvironment.self) private var environment

    private var rollup: DayRollup { environment.engine.todayRollup }
    private var targetHours: Double { environment.engine.settings.dailyTargetHours }

    var body: some View {
        VStack(spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.small) {
                Text(DurationFormat.humane(rollup.workSeconds))
                    .font(.system(size: 12, weight: .semibold))
                    .monospacedDigit()
                Text("of \(DurationFormat.humane(targetHours * 3600)) today")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)

                Spacer(minLength: 0)

                if rollup.unloggableSeconds > 0 {
                    Button {
                        WindowManager.shared.showTimesheet(environment: environment)
                    } label: {
                        Chip(
                            text: "\(DurationFormat.humane(rollup.unloggableSeconds)) unfiled",
                            systemImage: "questionmark.circle.fill",
                            tint: .orange
                        )
                    }
                    .buttonStyle(.plain)
                    .help("Tracked time with no Jira issue yet — click to assign it")
                }
                if rollup.contextSwitches >= 8 {
                    Chip(
                        text: "\(rollup.contextSwitches) switches",
                        systemImage: "arrow.left.arrow.right",
                        tint: .secondary
                    )
                    .help("How fragmented today has been")
                }
            }

            DayProgressBar(
                workSeconds: rollup.workSeconds,
                targetSeconds: targetHours * 3600,
                unfiledSeconds: rollup.unloggableSeconds
            )
        }
    }
}

// MARK: - Footer

struct PanelFooter: View {
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        HStack(spacing: Theme.Spacing.small) {
            ConnectionBadge()

            Spacer(minLength: 0)

            if let until = environment.activity.snoozedUntil {
                Button {
                    environment.activity.cancelSnooze()
                } label: {
                    Chip(
                        text: "Muted until \(until.formatted(date: .omitted, time: .shortened))",
                        systemImage: "bell.slash.fill",
                        tint: .orange
                    )
                }
                .buttonStyle(.plain)
                .help("Reminders are silenced — click to re-enable")
            }

            Button {
                WindowManager.shared.showTimesheet(environment: environment)
            } label: {
                Label("Timesheet", systemImage: "calendar")
                    .font(.system(size: 11))
            }
            .buttonStyle(QuietButtonStyle(compact: true))

            Menu {
                Button("Settings…") { WindowManager.shared.showSettings(environment: environment) }
                Button("Phone remote…") { WindowManager.shared.showPairing(environment: environment) }
                Divider()
                Button("Sync to Jira now") {
                    Task { await environment.sync.sync(force: true) }
                }
                .disabled(environment.sync.pendingCount == 0)
                Button("Refresh issue list") {
                    environment.issues.invalidateCache()
                    Task { await environment.issues.loadFilter(environment.issues.activeFilter) }
                }
                Divider()
                Button("Quit Chrono") { NSApp.terminate(nil) }
            } label: {
                Image(systemName: "gearshape")
            }
            .menuStyle(.borderlessButton)
            .frame(width: 24)
        }
        .padding(.horizontal, Theme.Spacing.large)
        .padding(.vertical, Theme.Spacing.small)
    }
}

/// Jira connection state, with the sync queue folded in.
struct ConnectionBadge: View {
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        Button {
            if case .connected = environment.connection.state {
                Task { await environment.sync.sync(force: true) }
            } else {
                WindowManager.shared.showSettings(environment: environment)
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: environment.connection.state.symbolName)
                    .font(.system(size: 9.5))
                Text(environment.sync.statusSummary)
                    .font(.system(size: 10.5))
            }
            .foregroundStyle(tint)
        }
        .buttonStyle(.plain)
        .help(helpText)
    }

    private var tint: Color {
        if environment.sync.needsReauthentication { return .red }
        switch environment.connection.state {
        case .connected: return environment.sync.pendingCount > 0 ? .orange : .secondary
        case .unauthorized: return .red
        case .offline: return .orange
        case .connecting, .unconfigured: return .secondary
        }
    }

    private var helpText: String {
        switch environment.connection.state {
        case .connected(let user): return "Connected to Jira as \(user.displayName). Click to sync now."
        case .unauthorized(let reason): return reason
        case .offline(let reason): return "\(reason) Work is queued locally and will sync when Jira is reachable."
        case .connecting: return "Connecting to Jira…"
        case .unconfigured: return "Click to connect Chrono to Jira."
        }
    }
}
