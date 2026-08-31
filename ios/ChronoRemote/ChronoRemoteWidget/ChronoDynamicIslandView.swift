import ActivityKit
import SwiftUI
import WidgetKit

/// The Dynamic Island presentations.
///
/// Three sizes with very different budgets. The compact and minimal forms are a few points wide,
/// so they carry one thing each: is it running, and for how long. The expanded form is the only
/// one with room to explain itself.
///
/// The meeting case earns the accent colour in every size. It is the one state where a glance
/// should provoke an action — the Mac thinks you are on a call while a task is still tracking.
// Not a `@ViewBuilder`: `DynamicIsland` is its own result type, not a `View`, so the builder
// cannot construct it and the function returns one directly.
func chronoDynamicIsland(context: ActivityViewContext<ChronoActivityAttributes>) -> DynamicIsland {
    let state = context.state

    return DynamicIsland {
        DynamicIslandExpandedRegion(.leading) {
            Label {
                Text(state.label.isEmpty ? "Untitled" : state.label)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
            } icon: {
                Image(systemName: state.inMeeting ? "person.2.wave.2.fill" : "timer")
                    .foregroundStyle(state.inMeeting ? .orange : .green)
            }
        }

        DynamicIslandExpandedRegion(.trailing) {
            chronoTickingTime(state: state)
                .font(.title3.weight(.semibold).monospacedDigit())
                .foregroundStyle(state.isTicking ? .primary : .secondary)
                .frame(maxWidth: 96, alignment: .trailing)
        }

        DynamicIslandExpandedRegion(.bottom) {
            if state.inMeeting && state.status == .running {
                Text("On a call — \(state.label.isEmpty ? "a task" : state.label) is still tracking")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else if context.isStale {
                Text("Out of range of \(context.attributes.macName)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else if state.targetSeconds > 0 {
                chronoTodayBar(state: state)
            }
        }
    } compactLeading: {
        Image(systemName: state.inMeeting ? "person.2.wave.2.fill" : "timer")
            .foregroundStyle(state.inMeeting ? .orange : .green)
    } compactTrailing: {
        chronoTickingTime(state: state)
            .font(.caption.monospacedDigit())
            // Without a width the ticking text resizes the island as digits change.
            .frame(maxWidth: 54, alignment: .trailing)
    } minimal: {
        Image(systemName: state.status == .running ? "timer" : "pause.fill")
            .foregroundStyle(state.inMeeting ? .orange : (state.status == .running ? .green : .yellow))
    }
    .keylineTint(state.inMeeting ? .orange : .green)
}

/// The elapsed time, ticking on its own while running and frozen when not.
@ViewBuilder
func chronoTickingTime(state: ChronoActivityAttributes.ContentState) -> some View {
    if state.isTicking, let since = state.runningSince {
        Text(timerInterval: state.countUpRange(from: since), countsDown: false)
    } else {
        Text(chronoClock(state.elapsed))
    }
}

@ViewBuilder
func chronoTodayBar(state: ChronoActivityAttributes.ContentState) -> some View {
    if state.isTicking, let range = state.targetRange {
        ProgressView(timerInterval: range, countsDown: false) {
            EmptyView()
        } currentValueLabel: {
            EmptyView()
        }
        .progressViewStyle(.linear)
        .tint(.green)
    } else {
        ProgressView(value: state.staticProgress)
            .progressViewStyle(.linear)
            .tint(.secondary)
    }
}
