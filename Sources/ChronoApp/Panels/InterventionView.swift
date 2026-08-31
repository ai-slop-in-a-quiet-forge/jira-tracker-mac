import SwiftUI
import ChronoCore

/// The floating prompt: "your timer is still running — do something about it".
///
/// Copy matters more than layout here. Each prompt states what is happening, *why* Chrono
/// thinks so, and offers the reversible option as the default. Nothing is phrased as a
/// telling-off, because the whole situation — a call landing mid-task — is completely normal.
struct InterventionView: View {
    let intervention: Intervention
    let onChoice: (InterventionChoice) -> Void

    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            header
            if let detail { detailRow(detail) }
            actions
        }
        .padding(Theme.Spacing.large)
        .frame(width: 380)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(.separator.opacity(0.7), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.18), radius: 18, y: 6)
        .padding(6)   // room for the shadow inside the borderless panel
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.medium) {
            Image(systemName: presentation.symbol)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(presentation.tint)
                .frame(width: 26)

            VStack(alignment: .leading, spacing: 3) {
                Text(presentation.title)
                    .font(.system(size: 13, weight: .semibold))
                Text(presentation.body)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            Button {
                InterventionPresenter.shared.dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .help("Dismiss")
        }
    }

    /// The task the prompt is about, so there is never any doubt what will be affected.
    private var detail: TrackingTarget? {
        switch intervention {
        case .idleDetected(let target, _),
             .meetingDetected(let target, _, _),
             .runawaySession(let target, _),
             .pausedTooLong(let target, _):
            return target
        default:
            return nil
        }
    }

    private func detailRow(_ target: TrackingTarget) -> some View {
        HStack(spacing: Theme.Spacing.small) {
            TargetIcon(target: target)
            Text(target.displayLabel)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
            TimerText(seconds: environment.engine.activeTargetTodayElapsed, size: 12, showSeconds: false)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, Theme.Spacing.small)
        .padding(.vertical, 6)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Actions

    private var actions: some View {
        HStack(spacing: Theme.Spacing.small) {
            ForEach(Array(presentation.choices.enumerated()), id: \.offset) { index, choice in
                Button(choice.label) { onChoice(choice.value) }
                    .buttonStyle(
                        index == 0
                            ? AnyButtonStyle(FilledButtonStyle(tint: presentation.tint, compact: true))
                            : AnyButtonStyle(QuietButtonStyle(compact: true))
                    )
                    .help(choice.help ?? "")
            }
            Spacer(minLength: 0)
            if presentation.showsSnooze {
                Menu {
                    Button("30 minutes") { onChoice(.snooze(minutes: 30)) }
                    Button("1 hour") { onChoice(.snooze(minutes: 60)) }
                    Button("Rest of the day") { onChoice(.snooze(minutes: 8 * 60)) }
                } label: {
                    Image(systemName: "bell.slash")
                        .font(.system(size: 10, weight: .semibold))
                }
                .menuStyle(.borderlessButton)
                .frame(width: 26)
                .help("Silence reminders")
            }
        }
    }

    // MARK: - Copy

    private struct Choice {
        let label: String
        let value: InterventionChoice
        var help: String?
    }

    private struct Presentation {
        let symbol: String
        let tint: Color
        let title: String
        let body: String
        let choices: [Choice]
        var showsSnooze = true
    }

    private var presentation: Presentation {
        switch intervention {
        case .idleDetected(_, let seconds):
            return Presentation(
                symbol: "moon.zzz.fill",
                tint: .orange,
                title: "You've been away \(DurationFormat.humane(seconds))",
                body: "The timer kept running. What should happen to that time?",
                choices: [
                    Choice(label: "Discard & pause", value: .idleDiscardAndPause,
                           help: "Remove the idle time and stop the clock"),
                    Choice(label: "Keep it", value: .idleKeep,
                           help: "Count it as work — you were thinking, not typing"),
                    Choice(label: "Discard, keep going", value: .idleDiscard,
                           help: "Remove the idle time but keep tracking"),
                ]
            )

        case .meetingDetected(_, let signal, _):
            return Presentation(
                symbol: "person.2.wave.2.fill",
                tint: .blue,
                title: "You're in \(signal.appName)",
                body: "Your task is still being tracked — \(signal.reason). Move this time to a meeting instead?",
                choices: [
                    Choice(label: "Log as meeting", value: .meetingSwitch,
                           help: "Switch to your meeting bucket and come back afterwards"),
                    Choice(label: "Pause", value: .meetingPause,
                           help: "Stop the clock until the call ends"),
                    Choice(label: "Keep tracking", value: .meetingKeep,
                           help: "This call is part of the task"),
                ]
            )

        case .runawaySession(_, let elapsed):
            return Presentation(
                symbol: "exclamationmark.triangle.fill",
                tint: .red,
                title: "Running for \(DurationFormat.humane(elapsed))",
                body: "That is unusually long for one sitting. Was the timer left on?",
                choices: [
                    Choice(label: "Stop & log", value: .stopAndLog),
                    Choice(label: "It's genuine", value: .keepGoing),
                ],
                showsSnooze: false
            )

        case .endOfDayReview(let unfiled, let unsettled, let pending):
            var parts: [String] = []
            if unfiled > 0 { parts.append("\(DurationFormat.humane(unfiled)) with no issue") }
            if unsettled > 0 { parts.append("\(DurationFormat.humane(unsettled)) not yet drafted") }
            if pending > 0 { parts.append(pending == 1 ? "1 worklog queued" : "\(pending) worklogs queued") }
            return Presentation(
                symbol: "moon.stars.fill",
                tint: .purple,
                title: "Wrap up your day?",
                body: parts.isEmpty ? "Everything is logged." : parts.joined(separator: " · "),
                choices: [Choice(label: "Review my day", value: .openTimesheet)]
            )

        case .pausedTooLong(_, let seconds):
            return Presentation(
                symbol: "pause.circle.fill",
                tint: .orange,
                title: "Still paused after \(DurationFormat.humane(seconds))",
                body: "Resume it, or stop and log what you have so far.",
                choices: [Choice(label: "Review my day", value: .openTimesheet)]
            )

        case .takeABreak(let seconds):
            return Presentation(
                symbol: "cup.and.saucer.fill",
                tint: .green,
                title: "\(DurationFormat.humane(seconds)) without a break",
                body: "Worth stepping away for a few minutes.",
                choices: [Choice(label: "Thanks", value: .keepGoing)]
            )

        case .stillTracking(_, let elapsed), .forgotToStart(let elapsed):
            return Presentation(
                symbol: "clock.badge.questionmark",
                tint: .accentColor,
                title: "Check your timer",
                body: DurationFormat.humane(elapsed),
                choices: [Choice(label: "Open Chrono", value: .openTimesheet)]
            )

        case .none:
            return Presentation(
                symbol: "checkmark", tint: .green, title: "", body: "", choices: []
            )
        }
    }
}

/// Type-erased button style, so the first action in a row can be filled and the rest quiet
/// without duplicating the whole row.
struct AnyButtonStyle: ButtonStyle {
    private let makeBodyClosure: (Configuration) -> AnyView

    init<S: ButtonStyle>(_ style: S) {
        makeBodyClosure = { configuration in
            AnyView(style.makeBody(configuration: configuration))
        }
    }

    func makeBody(configuration: Configuration) -> some View {
        makeBodyClosure(configuration)
    }
}
