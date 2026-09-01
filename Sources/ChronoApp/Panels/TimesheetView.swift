import SwiftUI
import AppKit
import ChronoCore

/// The review surface: what you did, what still needs a ticket, and what has reached Jira.
///
/// This is where the "ad-hoc time" promise is kept. Capturing an interruption in one click is
/// only half the feature; the other half is being able to sit down at the end of the day and
/// give those fragments a ticket without having lost their timestamps.
struct TimesheetView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var selectedDay = Date()

    private var engine: TrackingEngine { environment.engine }

    private var rollup: DayRollup {
        DayRollup.build(segments: engine.state.allSegments(), day: selectedDay, asOf: Date())
    }

    var body: some View {
        HSplitView {
            sidebar
                .frame(minWidth: 210, idealWidth: 230, maxWidth: 280)
            detail
                .frame(minWidth: 560)
        }
        .frame(minWidth: 860, minHeight: 560)
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            WeekStrip(selectedDay: $selectedDay)
                .padding(Theme.Spacing.medium)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
                    weekTotals
                    queueSummary
                }
                .padding(Theme.Spacing.medium)
            }
        }
        .background(.quaternary.opacity(0.2))
    }

    private var weekTotals: some View {
        let week = WeekRollup.build(
            segments: engine.state.allSegments(),
            weekContaining: selectedDay,
            asOf: Date()
        )
        let target = engine.settings.dailyTargetHours
            * Double(max(1, engine.settings.workdays.count))

        return VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            SectionHeader(title: "This week")
            HStack(alignment: .firstTextBaseline) {
                Text(DurationFormat.humane(week.workSeconds))
                    .font(.system(size: 17, weight: .semibold))
                    .monospacedDigit()
                Text("of \(DurationFormat.humane(target * 3600))")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
            DayProgressBar(
                workSeconds: week.workSeconds,
                targetSeconds: target * 3600,
                unfiledSeconds: week.unloggableSeconds
            )
            if week.unloggableSeconds > 0 {
                Chip(
                    text: "\(DurationFormat.humane(week.unloggableSeconds)) needs a ticket",
                    systemImage: "questionmark.circle.fill",
                    tint: .orange
                )
            }
        }
    }

    private var queueSummary: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            SectionHeader(title: "Jira")
            HStack(spacing: 6) {
                Image(systemName: environment.connection.state.symbolName)
                    .font(.system(size: 10))
                Text(environment.connection.state.summary)
                    .font(.system(size: 11))
            }
            .foregroundStyle(.secondary)

            Text(environment.sync.statusSummary)
                .font(.system(size: 11, weight: .medium))

            if environment.sync.pendingCount > 0 {
                Button("Send \(environment.sync.pendingCount) to Jira") {
                    Task { await environment.sync.sync(force: true) }
                }
                .buttonStyle(FilledButtonStyle(compact: true))
                .disabled(environment.sync.isSyncing)
            }
            if let error = environment.sync.lastError {
                Text(error)
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Detail

    private var detail: some View {
        VStack(alignment: .leading, spacing: 0) {
            dayHeader
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.section) {
                    UnfiledTimeSection(day: selectedDay)
                    DayEntriesSection(day: selectedDay)
                    UntrackedMeetingsSection(day: selectedDay)

                    WorklogQueueSection(day: selectedDay)
                }
                .padding(Theme.Spacing.large)
            }
        }
    }

    private var dayHeader: some View {
        HStack(alignment: .center, spacing: Theme.Spacing.medium) {
            VStack(alignment: .leading, spacing: 2) {
                Text(selectedDay.formatted(.dateTime.weekday(.wide).day().month(.wide)))
                    .font(.system(size: 15, weight: .semibold))
                HStack(spacing: 6) {
                    Text(DurationFormat.humane(rollup.workSeconds))
                        .font(.system(size: 11, weight: .medium))
                        .monospacedDigit()
                    if rollup.breakSeconds > 0 {
                        Text("· \(DurationFormat.humane(rollup.breakSeconds)) break")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    if let first = rollup.firstActivity, let last = rollup.lastActivity {
                        Text("· \(first.formatted(date: .omitted, time: .shortened))–\(last.formatted(date: .omitted, time: .shortened))")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    if rollup.untrackedWithinSpanSeconds > 300 {
                        Chip(
                            text: "\(DurationFormat.humane(rollup.untrackedWithinSpanSeconds)) untracked",
                            systemImage: "circle.dotted",
                            tint: .secondary
                        )
                        .help("Gaps between your first and last tracked activity")
                    }
                }
            }

            Spacer()

            ProgressRing(progress: rollup.progress(towardHours: engine.settings.dailyTargetHours))
                .frame(width: 28, height: 28)

            BackfillButton(day: selectedDay)
        }
        .padding(Theme.Spacing.large)
    }
}

// MARK: - Week strip

/// Seven-day picker with per-day bars, so a light day is visible at a glance.
struct WeekStrip: View {
    @Binding var selectedDay: Date
    @Environment(AppEnvironment.self) private var environment

    private var week: WeekRollup {
        WeekRollup.build(
            segments: environment.engine.state.allSegments(),
            weekContaining: selectedDay,
            asOf: Date()
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            HStack {
                Button {
                    shift(by: -7)
                } label: {
                    Image(systemName: "chevron.left").font(.system(size: 10, weight: .semibold))
                }
                .buttonStyle(.plain)

                Spacer()
                Text(week.weekStart.formatted(.dateTime.month(.abbreviated).day()) + " –")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                Text((week.days.last?.day ?? week.weekStart).formatted(.dateTime.month(.abbreviated).day()))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                Spacer()

                Button {
                    shift(by: 7)
                } label: {
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
                }
                .buttonStyle(.plain)
            }

            HStack(spacing: 3) {
                ForEach(week.days, id: \.day) { day in
                    DayColumn(
                        rollup: day,
                        target: environment.engine.settings.dailyTargetHours * 3600,
                        isSelected: Calendar.current.isDate(day.day, inSameDayAs: selectedDay),
                        isToday: Calendar.current.isDateInToday(day.day)
                    ) {
                        selectedDay = day.day
                    }
                }
            }

            Button("Today") { selectedDay = Date() }
                .buttonStyle(QuietButtonStyle(compact: true))
                .disabled(Calendar.current.isDateInToday(selectedDay))
        }
    }

    private func shift(by days: Int) {
        guard let moved = Calendar.current.date(byAdding: .day, value: days, to: selectedDay) else { return }
        selectedDay = moved
    }
}

struct DayColumn: View {
    let rollup: DayRollup
    let target: TimeInterval
    let isSelected: Bool
    let isToday: Bool
    let onTap: () -> Void

    private var fraction: Double {
        guard target > 0 else { return 0 }
        return min(1, rollup.workSeconds / target)
    }

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 3) {
                Text(rollup.day.formatted(.dateTime.weekday(.narrow)))
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(isToday ? Color.accentColor : .secondary)

                // Bars are drawn bottom-up, so the week reads like a small chart.
                GeometryReader { geometry in
                    VStack(spacing: 0) {
                        Spacer(minLength: 0)
                        RoundedRectangle(cornerRadius: 2)
                            .fill(rollup.unloggableSeconds > 0 ? Color.orange : Color.accentColor)
                            .frame(height: max(fraction > 0 ? 3 : 0, geometry.size.height * fraction))
                    }
                }
                .frame(height: 30)

                Text("\(Calendar.current.component(.day, from: rollup.day))")
                    .font(.system(size: 9.5, weight: isSelected ? .bold : .regular))
            }
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity)
            .background(
                isSelected ? Color.primary.opacity(0.08) : Color.clear,
                in: RoundedRectangle(cornerRadius: 6)
            )
        }
        .buttonStyle(.plain)
        .help("\(DurationFormat.humane(rollup.workSeconds)) on \(rollup.day.formatted(date: .abbreviated, time: .omitted))")
    }
}
