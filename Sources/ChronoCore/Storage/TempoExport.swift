import Foundation

/// Exports tracked time in the column layout Tempo's worklog importer expects.
///
/// Kept apart from `Export` because the constraints are different in kind. The generic CSVs
/// describe *everything Chrono knows* and are meant to be read by a person or a spreadsheet;
/// this one has to satisfy an importer, so it carries only the columns Tempo reads and has to
/// leave out anything Tempo cannot accept.
///
/// ## Ad-hoc time cannot be exported
///
/// Tempo logs against a Jira issue. Chrono also tracks ad-hoc buckets — interruptions, meetings,
/// admin — which by definition have no issue key. Those rows are dropped rather than invented,
/// and the amount dropped is reported, because a silently shorter timesheet is precisely the
/// kind of error nobody notices until payroll.
public enum TempoExport {

    /// The result of building a Tempo CSV, including what could not be included.
    public struct Result: Sendable, Equatable {
        public let csv: String
        /// Rows written, excluding the header.
        public let rowCount: Int
        /// Time that had no issue key and so could not be exported.
        public let skippedSeconds: TimeInterval
        /// The ad-hoc buckets that were dropped, for naming them in the UI.
        public let skippedLabels: [String]

        public var hasSkipped: Bool { skippedSeconds > 0 }
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    /// One row per issue per day, which is the shape a timesheet is reviewed and imported in —
    /// and it matches how Chrono aggregates worklogs when it submits them itself, so an imported
    /// timesheet and a submitted one agree.
    ///
    /// - Parameter workerAccountID: the Jira account id the worklogs belong to. Tempo requires a
    ///   worker on every row; when Chrono has not connected to Jira yet the column is left empty
    ///   rather than guessed, and Tempo will reject the file with a clear message.
    public static func csv(
        _ segments: [WorkSegment],
        workerAccountID: String?,
        calendar: Calendar = .current,
        asOf now: Date
    ) -> Result {
        struct Key: Hashable {
            let day: Date
            let issueKey: String
        }
        struct Entry {
            var seconds: TimeInterval = 0
            var earliestStart: Date
            var notes: [String] = []
        }

        let pieces = segments
            .filter { $0.end != nil }
            .flatMap { $0.splitAcrossDays(calendar: calendar, asOf: now) }

        var entries: [Key: Entry] = [:]
        var skippedSeconds: TimeInterval = 0
        var skippedLabels: Set<String> = []

        for piece in pieces {
            guard let issueKey = piece.target.issueKey, !issueKey.isEmpty else {
                skippedSeconds += piece.closedDuration
                skippedLabels.insert(piece.target.displayLabel)
                continue
            }

            let key = Key(day: calendar.startOfDay(for: piece.start), issueKey: issueKey)
            var entry = entries[key] ?? Entry(earliestStart: piece.start)
            entry.seconds += piece.closedDuration
            entry.earliestStart = min(entry.earliestStart, piece.start)
            if let note = piece.note, !note.isEmpty, !entry.notes.contains(note) {
                entry.notes.append(note)
            }
            entries[key] = entry
        }

        var rows: [String] = ["Issue Key,Worker,Started Date,Started Time,Time Spent (seconds),Description"]

        let ordered = entries.sorted { left, right in
            (left.key.day, left.key.issueKey) < (right.key.day, right.key.issueKey)
        }
        for (key, entry) in ordered {
            rows.append([
                key.issueKey,
                workerAccountID ?? "",
                dateFormatter.string(from: key.day),
                timeFormatter.string(from: entry.earliestStart),
                // Whole seconds: Tempo stores integer seconds, and a decimal hours column
                // reintroduces the rounding error this avoids.
                String(Int(entry.seconds.rounded())),
                entry.notes.joined(separator: "; "),
            ].map(Export.escape).joined(separator: ","))
        }

        return Result(
            csv: rows.joined(separator: "\n") + "\n",
            rowCount: ordered.count,
            skippedSeconds: skippedSeconds,
            skippedLabels: skippedLabels.sorted()
        )
    }
}
