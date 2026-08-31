import Foundation

/// Duration formatting, shared by the menu bar, the panels, the phone remote and CSV export.
///
/// The menu bar is the fussy consumer here: it needs a *monospace-stable*, very short
/// string, because a title that changes width every second makes the whole menu bar
/// jitter as other items shuffle sideways.
public enum DurationFormat {
    /// `1:04:09` while under a day, `0:07` for short runs. Used in panels.
    public static func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        let (h, m, s) = (total / 3600, (total % 3600) / 60, total % 60)
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }

    /// `2:14` — hours and minutes only, fixed width. Used in the menu bar so the title
    /// does not resize once per second.
    public static func compact(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        return String(format: "%d:%02d", total / 3600, (total % 3600) / 60)
    }

    /// `2h 14m`, `14m`, `45s` — the human-readable form used in notifications and summaries.
    public static func humane(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        if total < 60 { return "\(total)s" }
        let (h, m) = (total / 3600, (total % 3600) / 60)
        if h == 0 { return "\(m)m" }
        if m == 0 { return "\(h)h" }
        return "\(h)h \(m)m"
    }

    /// Jira's own worklog shorthand, e.g. `2h 15m`. Jira accepts `timeSpentSeconds`
    /// directly, but this is what we show the user when previewing what will be logged.
    public static func jira(_ seconds: TimeInterval) -> String {
        let minutes = max(0, Int(seconds.rounded()) / 60)
        let (h, m) = (minutes / 60, minutes % 60)
        switch (h, m) {
        case (0, 0): return "0m"
        case (0, _): return "\(m)m"
        case (_, 0): return "\(h)h"
        default: return "\(h)h \(m)m"
        }
    }
}

public extension Date {
    /// Start of the calendar day in a given calendar — the boundary all daily rollups use.
    func startOfDay(_ calendar: Calendar = .current) -> Date {
        calendar.startOfDay(for: self)
    }

    func isSameDay(as other: Date, calendar: Calendar = .current) -> Bool {
        calendar.isDate(self, inSameDayAs: other)
    }

    /// Jira wants worklog timestamps as `2024-05-21T09:13:00.000+0530` — ISO 8601 with
    /// milliseconds and a *colon-less* timezone offset, which `ISO8601DateFormatter`
    /// will not produce. Hence the hand-rolled formatter.
    var jiraTimestamp: String {
        Date.jiraFormatter.string(from: self)
    }

    private static let jiraFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSZZZ"
        return f
    }()
}
