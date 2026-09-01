import SwiftUI
import ChronoCore

/// The working day, the menu bar, and launch behaviour.
struct TrackingSettingsTab: View {
    @Environment(AppEnvironment.self) private var environment

    private var bind: SettingsBinding { SettingsBinding(environment: environment) }

    private static let weekdayNames = [
        (1, "Sun"), (2, "Mon"), (3, "Tue"), (4, "Wed"), (5, "Thu"), (6, "Fri"), (7, "Sat"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.section) {
            SettingsGroup("Your working day") {
                DailyTargetField()
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    Text("Working days").font(.system(size: 11.5))
                    HStack(spacing: 4) {
                        ForEach(Self.weekdayNames, id: \.0) { number, name in
                            WeekdayToggle(number: number, name: name)
                        }
                    }
                }
            }

            SettingsGroup(
                "Menu bar",
                footnote: "Seconds are off by default: a title that changes width every second makes everything else in the menu bar shuffle sideways."
            ) {
                Picker("Show", selection: bind.bind(\.menuBarTime)) {
                    ForEach(MenuBarTime.allCases, id: \.self) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .font(.system(size: 11.5))
                Text(environment.engine.settings.menuBarTime.explanation)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)

                Divider()
                Toggle("Show what I'm tracking, not just the time", isOn: bind.bind(\.menuBarShowsLabel))
                    .font(.system(size: 11.5))
                Toggle("Show seconds", isOn: bind.bind(\.showSecondsInMenuBar))
                    .font(.system(size: 11.5))
                if environment.engine.settings.menuBarShowsLabel {
                    Stepper(
                        value: bind.bind(\.menuBarLabelMaxLength),
                        in: 6...40
                    ) {
                        Text("Trim labels to \(environment.engine.settings.menuBarLabelMaxLength) characters")
                            .font(.system(size: 11.5))
                    }
                }
            }

            SettingsGroup("Startup", footnote: LoginItem.isSupported ? nil : "Move Chrono to your Applications folder to enable this.") {
                Toggle("Start Chrono when I log in", isOn: Binding(
                    get: { environment.engine.settings.launchAtLogin },
                    set: { enabled in
                        environment.mutateSettings { $0.launchAtLogin = enabled }
                        LoginItem.setEnabled(enabled)
                    }
                ))
                .font(.system(size: 11.5))
                .disabled(!LoginItem.isSupported)

                HStack {
                    Text("Status").font(.system(size: 11))
                    Spacer()
                    Text(LoginItem.statusDescription)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

            SettingsGroup(
                "Keyboard shortcuts",
                footnote: "Control-Option shortcuts, chosen to avoid clashing with app shortcuts."
            ) {
                shortcutRow("Show or hide the panel", "⌃⌥T")
                shortcutRow("Start or stop the timer", "⌃⌥S")
                shortcutRow("Pause or resume", "⌃⌥P")
                shortcutRow("Capture an interruption", "⌃⌥I")
            }
        }
    }

    private func shortcutRow(_ label: String, _ keys: String) -> some View {
        HStack {
            Text(label).font(.system(size: 11.5))
            Spacer()
            Text(keys)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
        }
    }
}

struct WeekdayToggle: View {
    let number: Int
    let name: String
    @Environment(AppEnvironment.self) private var environment

    private var isOn: Bool { environment.engine.settings.workdays.contains(number) }

    var body: some View {
        Button {
            environment.mutateSettings { settings in
                if settings.workdays.contains(number) {
                    settings.workdays.remove(number)
                } else {
                    settings.workdays.insert(number)
                }
            }
        } label: {
            Text(name)
                .font(.system(size: 10.5, weight: .medium))
                .frame(width: 34, height: 22)
                .background(
                    isOn ? Color.accentColor.opacity(0.85) : Color.secondary.opacity(0.12),
                    in: RoundedRectangle(cornerRadius: 6)
                )
                .foregroundStyle(isOn ? Color.white : Color.secondary)
        }
        .buttonStyle(.plain)
    }
}
