import SwiftUI
import AppKit
import ChronoCore

/// First-run flow: explain, connect, set a couple of preferences, done.
///
/// Kept to three steps, and every one of them skippable. Chrono is useful without Jira (ad-hoc
/// tracking still works and can be filed later), so refusing to let someone in until they have
/// gone and generated an API token would be the wrong trade.
struct OnboardingView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var step = 0

    private var bind: SettingsBinding { SettingsBinding(environment: environment) }

    var body: some View {
        VStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            footer
        }
        .frame(width: 560, height: 540)
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case 0: welcome
        case 1: JiraConnectionForm(showsSkip: true) { step = 2 }
        default: preferences
        }
    }

    // MARK: - Step 0

    private var welcome: some View {
        VStack(spacing: Theme.Spacing.large) {
            Spacer()
            Image(systemName: "clock.badge.checkmark.fill")
                .font(.system(size: 52))
                .foregroundStyle(.tint)

            VStack(spacing: Theme.Spacing.small) {
                Text("Chrono")
                    .font(.system(size: 26, weight: .semibold, design: .rounded))
                Text("Time tracking for Jira that survives a normal working day.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
                feature(
                    "menubar.rectangle",
                    "Lives in your menu bar",
                    "One click to start, pause or switch task."
                )
                feature(
                    "person.2.wave.2.fill",
                    "Notices when you're on a call",
                    "If your mic goes live while a task is tracking, Chrono asks whether to pause or log it as a meeting."
                )
                feature(
                    "bolt.fill",
                    "Handles the random stuff",
                    "Capture an interruption in one click and give it a ticket later."
                )
                feature(
                    "lock.fill",
                    "Entirely local",
                    "No server, no account. Your history stays on this Mac; only worklogs go to Jira."
                )
            }
            .padding(.horizontal, Theme.Spacing.section)

            Spacer()
        }
        .padding(Theme.Spacing.section)
    }

    private func feature(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: Theme.Spacing.medium) {
            Image(systemName: symbol)
                .font(.system(size: 14))
                .foregroundStyle(.tint)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 12, weight: .semibold))
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Step 2

    private var preferences: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.section) {
                Text("A few preferences")
                    .font(.system(size: 18, weight: .semibold))

                SettingsGroup("Your day") {
                    DailyTargetField()
                    Toggle(
                        "Start Chrono when I log in",
                        isOn: bind.bind(\.launchAtLogin)
                    )
                    .onChange(of: environment.engine.settings.launchAtLogin) { _, enabled in
                        LoginItem.setEnabled(enabled)
                    }
                }

                SettingsGroup("When you step away") {
                    Toggle("Notice when I go idle", isOn: bind.bind(\.autoPauseOnIdle))
                    Toggle("Pause when the screen locks", isOn: bind.bind(\.autoPauseOnScreenLock))
                    Toggle("Pause when the Mac sleeps", isOn: bind.bind(\.autoPauseOnSleep))
                }

                SettingsGroup("Meetings and calls") {
                    Toggle("Warn me when I'm on a call while tracking", isOn: bind.bind(\.meetingDetectionEnabled))
                    Text("Chrono checks whether the microphone or camera is live. It never opens either itself, and never records anything.")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(Theme.Spacing.section)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            if step > 0 {
                Button("Back") { step -= 1 }
                    .buttonStyle(QuietButtonStyle())
            }
            Spacer()
            PageDots(count: 3, index: step)
            Spacer()
            Button(step == 2 ? "Start tracking" : "Continue") {
                if step == 2 {
                    WindowManager.shared.close(.onboarding)
                } else {
                    step += 1
                }
            }
            .buttonStyle(FilledButtonStyle())
        }
        .padding(Theme.Spacing.large)
        .background(.quaternary.opacity(0.3))
    }
}

struct PageDots: View {
    let count: Int
    let index: Int

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<count, id: \.self) { position in
                Circle()
                    .fill(position == index ? Color.accentColor : Color.secondary.opacity(0.3))
                    .frame(width: 5, height: 5)
            }
        }
    }
}
