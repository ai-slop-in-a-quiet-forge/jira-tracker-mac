import ActivityKit
import SwiftUI
import WidgetKit

/// The Lock Screen and Notification Centre presentation.
///
/// Every duration here is rendered with `Text(timerInterval:)` or `ProgressView(timerInterval:)`
/// while the timer is running, so the numbers advance on their own with no updates from the app.
/// See `ChronoActivityAttributes` for why that matters.
struct ChronoLockScreenView: View {
    let context: ActivityViewContext<ChronoActivityAttributes>

    private var state: ChronoActivityAttributes.ContentState { context.state }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            elapsed
            if state.targetSeconds > 0 {
                todayProgress
            }
        }
        .padding()
        // Stale content is dimmed rather than hidden: a timer that is probably still running is
        // more useful than a blank card, as long as it does not claim more certainty than it has.
        .opacity(context.isStale ? 0.55 : 1)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: state.inMeeting ? "person.2.wave.2.fill" : statusIcon)
                .foregroundStyle(state.inMeeting ? .orange : statusColor)
            Text(state.label.isEmpty ? "Untitled task" : state.label)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
            Spacer(minLength: 0)
            Text(context.isStale ? "Out of range" : statusText)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var elapsed: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if state.isTicking, let since = state.runningSince {
                Text(timerInterval: state.countUpRange(from: since), countsDown: false)
                    .font(.system(size: 34, weight: .semibold, design: .rounded))
                    .monospacedDigit()
            } else {
                Text(chronoClock(state.elapsed))
                    .font(.system(size: 34, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var todayProgress: some View {
        VStack(alignment: .leading, spacing: 4) {
            if state.isTicking, let range = state.targetRange {
                // Fills itself as the day goes on; no updates needed to keep it honest.
                ProgressView(timerInterval: range, countsDown: false) {
                    EmptyView()
                } currentValueLabel: {
                    EmptyView()
                }
                .progressViewStyle(.linear)
                .tint(state.inMeeting ? .orange : .green)
            } else {
                ProgressView(value: state.staticProgress)
                    .progressViewStyle(.linear)
                    .tint(.secondary)
            }

            HStack(spacing: 4) {
                Text("Today")
                Spacer()
                // Ticks alongside the bar. A frozen number next to a moving bar reads as a bug,
                // and would drift further from the truth the longer the app goes unopened.
                if state.isTicking, let since = state.todayCountingSince {
                    Text(timerInterval: state.countUpRange(from: since), countsDown: false)
                        .monospacedDigit()
                        .frame(maxWidth: 62, alignment: .trailing)
                } else {
                    Text(chronoClock(state.todaySeconds))
                        .monospacedDigit()
                }
                Text("of \(chronoClock(state.targetSeconds))")
                    .monospacedDigit()
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
    }

    private var statusIcon: String {
        switch state.status {
        case .running: return "play.fill"
        case .paused: return "pause.fill"
        case .idle: return "stop.fill"
        }
    }

    private var statusColor: Color {
        switch state.status {
        case .running: return .green
        case .paused: return .yellow
        case .idle: return .secondary
        }
    }

    private var statusText: String {
        if state.inMeeting && state.status == .running { return "On a call" }
        switch state.status {
        case .running: return "Tracking"
        case .paused: return "Paused"
        case .idle: return "Stopped"
        }
    }
}
