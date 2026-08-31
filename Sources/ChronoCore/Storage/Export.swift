import Foundation

/// Exports tracked time as CSV.
///
/// Present because a time tracker that cannot get your data back out is a trap. The output is
/// deliberately boring and spreadsheet-friendly: ISO 8601 timestamps, one row per segment, and
/// RFC 4180 quoting so a summary containing a comma or a newline cannot corrupt the file.
public enum Export {

    public static let filenameDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    /// One row per segment.
    public static func segmentsCSV(
        _ segments: [WorkSegment],
        drafts: [WorklogDraft] = [],
        calendar: Calendar = .current
    ) -> String {
        // Which segments have made it to Jira, so the export can say so.
        var stateBySegment: [UUID: String] = [:]
        for draft in drafts {
            for id in draft.segmentIDs {
                stateBySegment[id] = draft.state.label
            }
        }

        var rows: [String] = [
            "date,start,end,duration_seconds,duration_hours,issue_key,description,category,note,source,trimmed_idle_seconds,sync_state"
        ]

        for segment in segments.sorted(by: { $0.start < $1.start }) {
            guard let end = segment.end else { continue }
            let duration = segment.closedDuration
            let hours = String(format: "%.4f", duration / 3600)

            rows.append([
                filenameDateFormatter.string(from: segment.start),
                timestampFormatter.string(from: segment.start),
                timestampFormatter.string(from: end),
                String(Int(duration)),
                hours,
                segment.target.issueKey ?? "",
                segment.target.displayLabel,
                segment.target.adhoc?.category.rawValue ?? "issue",
                segment.note ?? "",
                segment.source.rawValue,
                String(Int(segment.trimmedIdle)),
                stateBySegment[segment.id] ?? "Not queued",
            ].map(escape).joined(separator: ","))
        }

        return rows.joined(separator: "\n") + "\n"
    }

    /// One row per issue per day — the shape a timesheet reviewer or a finance team wants.
    public static func dailyTotalsCSV(
        _ segments: [WorkSegment],
        calendar: Calendar = .current,
        asOf now: Date
    ) -> String {
        struct Key: Hashable {
            let day: Date
            let target: String
        }

        let pieces = segments
            .filter { $0.end != nil }
            .flatMap { $0.splitAcrossDays(calendar: calendar, asOf: now) }

        var totals: [Key: (seconds: TimeInterval, label: String, issueKey: String)] = [:]
        for piece in pieces {
            let key = Key(day: calendar.startOfDay(for: piece.start), target: piece.target.id)
            var entry = totals[key] ?? (0, piece.target.displayLabel, piece.target.issueKey ?? "")
            entry.seconds += piece.closedDuration
            totals[key] = entry
        }

        var rows: [String] = ["date,issue_key,description,duration_seconds,duration_hours,jira_format"]
        for (key, value) in totals.sorted(by: { ($0.key.day, $0.value.label) < ($1.key.day, $1.value.label) }) {
            rows.append([
                filenameDateFormatter.string(from: key.day),
                value.issueKey,
                value.label,
                String(Int(value.seconds)),
                String(format: "%.4f", value.seconds / 3600),
                DurationFormat.jira(value.seconds),
            ].map(escape).joined(separator: ","))
        }
        return rows.joined(separator: "\n") + "\n"
    }

    /// RFC 4180: wrap in quotes when the value contains a comma, quote, CR or LF, and double
    /// any embedded quotes.
    static func escape(_ field: String) -> String {
        guard field.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else {
            return field
        }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
