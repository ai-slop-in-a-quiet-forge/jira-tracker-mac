import SwiftUI
import AppKit
import ChronoCore

/// Idle handling, meeting detection and reminders — plus a live sensor readout so the user can
/// verify detection actually works on their machine rather than taking our word for it.
struct InterruptionSettingsTab: View {
    @Environment(AppEnvironment.self) private var environment

    private var bind: SettingsBinding { SettingsBinding(environment: environment) }
    private var settings: TrackerSettings { environment.engine.settings }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.section) {
            SettingsGroup(
                "When you go idle",
                footnote: "Chrono watches for keyboard and mouse inactivity system-wide. It cannot see what you type — only that you stopped."
            ) {
                Picker("After", selection: bind.bind(\.idleThresholdSeconds)) {
                    Text("2 minutes").tag(120)
                    Text("5 minutes").tag(300)
                    Text("10 minutes").tag(600)
                    Text("15 minutes").tag(900)
                    Text("30 minutes").tag(1800)
                }
                .font(.system(size: 11.5))

                Picker("Then", selection: bind.bind(\.idleDefaultAction)) {
                    ForEach(IdleAction.allCases, id: \.self) { action in
                        Text(action.title).tag(action)
                    }
                }
                .pickerStyle(.radioGroup)
                .font(.system(size: 11.5))

                Divider()
                Toggle("Pause when the screen locks", isOn: bind.bind(\.autoPauseOnScreenLock))
                    .font(.system(size: 11.5))
                Toggle("Pause when the Mac goes to sleep", isOn: bind.bind(\.autoPauseOnSleep))
                    .font(.system(size: 11.5))
                Text("Chrono never resumes on its own after a pause — waking your Mac is not the same as going back to the task, and silently resuming would log time you did not work.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            SettingsGroup(
                "Meetings and calls",
                footnote: "Microphone activity alone is never treated as a meeting — dictation and a dozen menu bar utilities hold the input open. Chrono needs audio or video capture *plus* a meeting app or browser running."
            ) {
                Toggle("Warn me when I'm on a call while tracking", isOn: bind.bind(\.meetingDetectionEnabled))
                    .font(.system(size: 12, weight: .medium))

                if settings.meetingDetectionEnabled {
                    Divider()
                    Toggle("Use microphone activity", isOn: bind.bind(\.detectViaMicrophone))
                        .font(.system(size: 11.5))
                    Toggle("Use camera activity", isOn: bind.bind(\.detectViaCamera))
                        .font(.system(size: 11.5))
                    Toggle("Use screen sharing", isOn: bind.bind(\.detectViaScreenSharing))
                        .font(.system(size: 11.5))
                        .help("Catches presenting while muted. Detected from Zoom's capture process — needs no Screen Recording permission, and only apps that use a separate capture process can be seen this way")
                    Toggle("Also treat a meeting app being in front as a call", isOn: bind.bind(\.detectViaFrontmostApp))
                        .font(.system(size: 11.5))
                        .help("Weaker signal — off by default because Teams is always open")

                    Divider()
                    Picker("Ignore blips shorter than", selection: bind.bind(\.meetingGraceSeconds)) {
                        Text("15 seconds").tag(15)
                        Text("30 seconds").tag(30)
                        Text("45 seconds").tag(45)
                        Text("1 minute").tag(60)
                        Text("2 minutes").tag(120)
                    }
                    .font(.system(size: 11.5))

                    Picker("When a call is detected", selection: bind.bind(\.meetingDefaultAction)) {
                        ForEach(MeetingAction.allCases, id: \.self) { action in
                            Text(action.title).tag(action)
                        }
                    }
                    .pickerStyle(.radioGroup)
                    .font(.system(size: 11.5))
                }
            }

            if settings.meetingDetectionEnabled {
                SensorDiagnostics()
                MeetingAppList()
            }

            SettingsGroup("Reminders") {
                Toggle("Check in periodically while tracking", isOn: bind.bind(\.nudgeEnabled))
                    .font(.system(size: 11.5))
                if settings.nudgeEnabled {
                    Picker("Every", selection: bind.bind(\.nudgeIntervalMinutes)) {
                        Text("30 minutes").tag(30)
                        Text("45 minutes").tag(45)
                        Text("1 hour").tag(60)
                        Text("2 hours").tag(120)
                    }
                    .font(.system(size: 11.5))
                }

                Divider()
                Toggle("Tell me when I'm working with no timer running", isOn: bind.bind(\.forgotToStartNudgeEnabled))
                    .font(.system(size: 11.5))
                if settings.forgotToStartNudgeEnabled {
                    Picker("After", selection: bind.bind(\.forgotToStartAfterMinutes)) {
                        Text("5 minutes").tag(5)
                        Text("10 minutes").tag(10)
                        Text("20 minutes").tag(20)
                        Text("30 minutes").tag(30)
                    }
                    .font(.system(size: 11.5))
                }

                Divider()
                Toggle("Suggest a break", isOn: bind.bind(\.breakReminderEnabled))
                    .font(.system(size: 11.5))
                Toggle("Ask me to wrap up at the end of the day", isOn: bind.bind(\.endOfDayReviewEnabled))
                    .font(.system(size: 11.5))
                if settings.endOfDayReviewEnabled {
                    Picker("From", selection: bind.bind(\.endOfDayReviewHour)) {
                        ForEach([16, 17, 18, 19, 20, 21], id: \.self) { hour in
                            Text("\(hour):00").tag(hour)
                        }
                    }
                    .font(.system(size: 11.5))
                }
            }
        }
    }
}

/// Live sensor readout. The honest way to prove meeting detection works: start a call and watch
/// these flip.
struct SensorDiagnostics: View {
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        SettingsGroup(
            "What Chrono can see right now",
            footnote: "Updates every few seconds. Start a call and watch these change — that is the whole detection mechanism, with nothing hidden."
        ) {
            ForEach(environment.activity.diagnostics(), id: \.label) { row in
                HStack {
                    Text(row.label)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(row.value)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                }
            }
            Divider()
            Button("Check now") { environment.activity.poll() }
                .buttonStyle(QuietButtonStyle(compact: true))
        }
    }
}

/// Which apps count as meeting apps.
struct MeetingAppList: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var newBundleID = ""

    var body: some View {
        SettingsGroup(
            "Apps that mean 'call'",
            footnote: "Bundle identifiers. Chrono ships with the common ones; add anything your team uses."
        ) {
            ForEach(environment.engine.settings.meetingAppBundleIDs, id: \.self) { bundleID in
                HStack(spacing: Theme.Spacing.small) {
                    Circle()
                        .fill(environment.activity.snapshot.runningMeetingApps.contains(bundleID)
                              ? Color.green : Color.secondary.opacity(0.3))
                        .frame(width: 6, height: 6)
                        .help(environment.activity.snapshot.runningMeetingApps.contains(bundleID)
                              ? "Running now" : "Not running")
                    Text(MeetingAppCatalog.displayName(forBundleID: bundleID))
                        .font(.system(size: 11.5))
                    Text(bundleID)
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(.tertiary)
                    Spacer()
                    Button {
                        environment.mutateSettings { settings in
                            settings.meetingAppBundleIDs.removeAll { $0 == bundleID }
                        }
                    } label: {
                        Image(systemName: "minus.circle").font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            }

            Divider()
            HStack(spacing: Theme.Spacing.small) {
                TextField("com.example.app", text: $newBundleID)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11, design: .monospaced))
                Button("Add") {
                    let value = newBundleID.trimmingCharacters(in: .whitespaces)
                    guard !value.isEmpty else { return }
                    environment.mutateSettings { settings in
                        guard !settings.meetingAppBundleIDs.contains(value) else { return }
                        settings.meetingAppBundleIDs.append(value)
                    }
                    newBundleID = ""
                }
                .buttonStyle(QuietButtonStyle(compact: true))
                .disabled(newBundleID.isEmpty)

                Button("Add frontmost app") {
                    guard let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else { return }
                    environment.mutateSettings { settings in
                        guard !settings.meetingAppBundleIDs.contains(bundleID) else { return }
                        settings.meetingAppBundleIDs.append(bundleID)
                    }
                }
                .buttonStyle(QuietButtonStyle(compact: true))
                .help("Adds whichever app was in front before you opened Settings")
            }
        }
    }
}
