import Foundation

/// Which clock the menu bar shows.
///
/// The session time answers "how long on this task", the day total answers "how much have I done
/// today" — and someone working to a daily target mostly wants the second. Showing both is the
/// honest compromise for people who want each for a different reason, at the cost of width.
public enum MenuBarTime: String, Codable, Sendable, CaseIterable, Equatable {
    /// Time on the active target today. The long-standing behaviour.
    case session
    /// Everything logged today, across every target.
    case dayTotal
    /// Session first, then the day: `1:23 · 5:40`.
    case both

    public var title: String {
        switch self {
        case .session: return "This task"
        case .dayTotal: return "Today's total"
        case .both: return "Both"
        }
    }

    public var explanation: String {
        switch self {
        case .session: return "Time on what you are tracking right now."
        case .dayTotal: return "Everything logged today, across every task."
        case .both: return "This task, then today's total."
        }
    }

    /// Builds the time portion of the menu bar title.
    ///
    /// ## Why the width matters
    ///
    /// The status item is laid out from this string, so anything that changes width redraws the
    /// whole right-hand side of the menu bar and shoves every other icon sideways. `compact`
    /// gives `h:mm`, whose width only changes when the hour count gains a digit — once a day at
    /// worst, rather than once a second. The separator is a fixed-width middle dot for the same
    /// reason; a slash with spaces around it drifts with the font.
    ///
    /// Seconds are opt-in and deliberately apply only to the session clock: a day total ticking
    /// its seconds column is pure noise, and it would double the rate at which the bar reflows.
    public static func title(
        for mode: MenuBarTime,
        session: TimeInterval,
        dayTotal: TimeInterval,
        showSeconds: Bool
    ) -> String {
        let sessionText = showSeconds ? DurationFormat.clock(session) : DurationFormat.compact(session)
        switch mode {
        case .session:
            return sessionText
        case .dayTotal:
            return DurationFormat.compact(dayTotal)
        case .both:
            return "\(sessionText) · \(DurationFormat.compact(dayTotal))"
        }
    }
}
