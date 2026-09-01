import Foundation

/// One thing worth knowing about a week.
///
/// ## Why findings rather than a dashboard
///
/// #12 named the risk precisely: "the risk here is building a dashboard nobody reads." A grid of
/// tiles is read once, on the day it ships. What survives is a short list of statements that were
/// not already obvious, and the way to get there is to let each one *decline to appear*.
///
/// So every insight has a threshold. A week where nothing was fragmented says nothing about
/// fragmentation — it does not render "0 context switches" in a box. A week where nothing stands
/// out produces an empty list, which is itself the honest answer and takes no space.
///
/// The second rule is that every line has to be actionable or at least surprising. "You worked
/// 31h" is neither; the timesheet already says so directly above. "14h 45m inside your working
/// hours is unaccounted for" is a thing someone might do something about.
public struct WeekInsight: Sendable, Equatable, Identifiable {

    public enum Kind: String, Sendable, Equatable {
        /// One issue dominated the week.
        case concentration
        /// Tracked work with no Jira issue behind it.
        case unticketed
        /// A day with a lot of switching between targets.
        case fragmentation
        /// Wall-clock time inside the working span that nothing accounts for.
        case unaccounted
        /// Tracked total against the configured target.
        case target
    }

    /// How much attention the line deserves. Only two levels on purpose: anything finer becomes a
    /// severity taxonomy nobody calibrates.
    public enum Tone: Sendable, Equatable {
        case neutral
        case attention
    }

    public let kind: Kind
    public let tone: Tone
    public let headline: String
    public let detail: String

    public var id: String { kind.rawValue }

    public init(kind: Kind, tone: Tone, headline: String, detail: String) {
        self.kind = kind
        self.tone = tone
        self.headline = headline
        self.detail = detail
    }
}

public enum WeekInsights {

    /// Time below which a finding is noise rather than news.
    private static let minimumNotableSeconds: TimeInterval = 1_800
    /// Switching less than this in a day is just normal work.
    private static let minimumNotableSwitches = 8
    /// A single issue has to reach this share of the week before it is worth remarking on.
    private static let concentrationThreshold = 0.25
    /// Unticketed work below this share is not worth a line of its own.
    private static let unticketedThreshold = 0.05
    /// Unaccounted wall-clock time below this is measurement noise, not a gap.
    private static let minimumUnaccountedSeconds: TimeInterval = 3_600

    /// Everything worth saying about `week`, most important first.
    ///
    /// `targetHours` and `workdays` come from settings so the target line can be honest about
    /// how many working days the week actually contained.
    ///
    /// `asOf` is passed in rather than read from the clock, for the same reason `TrackingEngine`
    /// takes a `Clock`: a function that reaches for `Date()` cannot be tested against a week that
    /// is not the current one.
    public static func build(
        for week: WeekRollup,
        targetHours: Double,
        workdays: Set<Int>,
        asOf now: Date,
        calendar: Calendar = .current
    ) -> [WeekInsight] {
        var insights: [WeekInsight] = []
        let tracked = week.workSeconds
        guard tracked > 0 else { return [] }

        if let insight = concentration(week, tracked: tracked) { insights.append(insight) }
        if let insight = unticketed(week, tracked: tracked) { insights.append(insight) }
        if let insight = fragmentation(week, calendar: calendar) { insights.append(insight) }
        if let insight = unaccounted(week) { insights.append(insight) }
        if let insight = target(
            week,
            targetHours: targetHours,
            workdays: workdays,
            asOf: now,
            calendar: calendar
        ) {
            insights.append(insight)
        }
        return insights
    }

    // MARK: - Individual findings

    private static func concentration(_ week: WeekRollup, tracked: TimeInterval) -> WeekInsight? {
        // Totals are per-day, so the same issue across five days has to be summed before it can
        // be compared with the week.
        var byTarget: [String: (label: String, seconds: TimeInterval)] = [:]
        for day in week.days {
            for total in day.totals {
                var entry = byTarget[total.target.id] ?? (total.target.displayLabel, 0)
                entry.seconds += total.seconds
                byTarget[total.target.id] = entry
            }
        }
        guard let top = byTarget.values.max(by: { $0.seconds < $1.seconds }) else { return nil }
        let share = top.seconds / tracked
        guard share >= concentrationThreshold, top.seconds >= minimumNotableSeconds else { return nil }

        return WeekInsight(
            kind: .concentration,
            tone: .neutral,
            headline: "\(top.label) took \(DurationFormat.humane(top.seconds))",
            detail: "\(percent(share)) of everything you tracked this week."
        )
    }

    private static func unticketed(_ week: WeekRollup, tracked: TimeInterval) -> WeekInsight? {
        let unticketed = week.unloggableSeconds
        let share = unticketed / tracked
        guard unticketed >= minimumNotableSeconds, share >= unticketedThreshold else { return nil }

        return WeekInsight(
            kind: .unticketed,
            tone: .attention,
            headline: "\(DurationFormat.humane(unticketed)) never got a ticket",
            detail: "\(percent(share)) of tracked time cannot be logged to Jira until it has an issue."
        )
    }

    private static func fragmentation(_ week: WeekRollup, calendar: Calendar) -> WeekInsight? {
        // The worst day rather than a weekly average: an average spreads one chaotic Tuesday
        // across five days until it looks like nothing happened.
        guard let worst = week.days
            .filter({ $0.workSeconds > 0 })
            .max(by: { $0.contextSwitches < $1.contextSwitches }),
            worst.contextSwitches >= minimumNotableSwitches
        else { return nil }

        let perSwitch = worst.workSeconds / Double(worst.contextSwitches)
        return WeekInsight(
            kind: .fragmentation,
            tone: .attention,
            headline: "\(weekdayName(worst.day, calendar: calendar)) was your most fragmented day",
            detail: "\(worst.contextSwitches) changes of task across "
                + "\(DurationFormat.humane(worst.workSeconds)) — about one every "
                + "\(DurationFormat.humane(perSwitch))."
        )
    }

    private static func unaccounted(_ week: WeekRollup) -> WeekInsight? {
        // Summed per day deliberately: the gap between first and last activity only means
        // something within a single day.
        let unaccounted = week.days.reduce(0.0) { $0 + $1.untrackedWithinSpanSeconds }
        guard unaccounted >= minimumUnaccountedSeconds else { return nil }

        return WeekInsight(
            kind: .unaccounted,
            tone: .neutral,
            headline: "\(DurationFormat.humane(unaccounted)) is unaccounted for",
            detail: "Time between your first and last activity each day that no timer was "
                + "running. Breaks and meetings you did not track both land here."
        )
    }

    private static func target(
        _ week: WeekRollup,
        targetHours: Double,
        workdays: Set<Int>,
        asOf now: Date,
        calendar: Calendar
    ) -> WeekInsight? {
        guard targetHours > 0 else { return nil }

        // Only days that are both a working day *and* have started count towards the target;
        // otherwise every Monday reports a 32-hour shortfall.
        let relevantDays = week.days.filter { day in
            workdays.contains(calendar.component(.weekday, from: day.day))
                && (day.workSeconds > 0 || day.day < calendar.startOfDay(for: now))
        }
        guard !relevantDays.isEmpty else { return nil }

        let expected = Double(relevantDays.count) * targetHours * 3600
        let difference = week.workSeconds - expected
        guard abs(difference) >= minimumNotableSeconds else { return nil }

        let dayWord = relevantDays.count == 1 ? "day" : "days"
        return WeekInsight(
            kind: .target,
            tone: difference < 0 ? .attention : .neutral,
            headline: difference < 0
                ? "\(DurationFormat.humane(-difference)) under target"
                : "\(DurationFormat.humane(difference)) over target",
            detail: "\(DurationFormat.humane(week.workSeconds)) tracked across "
                + "\(relevantDays.count) working \(dayWord), against \(DurationFormat.humane(expected))."
        )
    }

    // MARK: - Formatting

    private static func percent(_ fraction: Double) -> String {
        "\(Int((fraction * 100).rounded()))%"
    }

    private static func weekdayName(_ date: Date, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.setLocalizedDateFormatFromTemplate("EEEE")
        return formatter.string(from: date)
    }
}
