import Foundation
import Testing
@testable import ChronoCore

@Suite("CSV export")
struct ExportTests {

    // MARK: - RFC 4180 quoting
    //
    // The existing CSV code had no tests, and quoting is exactly where this kind of thing breaks.

    @Test("Plain values are not quoted")
    func escapeLeavesPlainValuesAlone() {
        #expect(Export.escape("CYM-123") == "CYM-123")
        #expect(Export.escape("") == "")
        #expect(Export.escape("a b c") == "a b c")
    }

    @Test("A comma forces quoting")
    func escapeQuotesCommas() {
        #expect(Export.escape("Parser, rewritten") == "\"Parser, rewritten\"")
    }

    @Test("Embedded quotes are doubled, not stripped")
    func escapeDoublesQuotes() {
        // The classic corruption: a summary containing a quote silently shifting every
        // following column by one.
        #expect(Export.escape("the \"fast\" path") == "\"the \"\"fast\"\" path\"")
    }

    @Test("Newlines force quoting so a note cannot start a new record")
    func escapeQuotesNewlines() {
        #expect(Export.escape("line one\nline two") == "\"line one\nline two\"")
        #expect(Export.escape("carriage\rreturn") == "\"carriage\rreturn\"")
    }

    @Test("A value that is only a quote still round trips")
    func escapeBareQuote() {
        #expect(Export.escape("\"") == "\"\"\"\"")
    }

    // MARK: - Tempo

    // Uses the shared `Fixture` helpers so these tests build segments the same way the rest
    // of the suite does.

    private let day = Fixture.referenceDate

    private func issueSegment(_ key: String, offsetHours: Double = 0, minutes: Double, note: String? = nil) -> WorkSegment {
        Fixture.segment(
            Fixture.issue(key),
            from: day.addingTimeInterval(offsetHours * 3_600),
            minutes: minutes,
            note: note
        )
    }

    @Test("Writes the columns Tempo's importer reads")
    func tempoHeader() {
        let result = TempoExport.csv([], workerAccountID: "acc-1", asOf: day)
        let header = result.csv.split(separator: "\n").first
        #expect(header == "Issue Key,Worker,Started Date,Started Time,Time Spent (seconds),Description")
        #expect(result.rowCount == 0)
    }

    @Test("Time on one issue is summed per day")
    func tempoAggregatesPerIssuePerDay() {
        let result = TempoExport.csv(
            [
                issueSegment("CYM-1", minutes: 30),
                issueSegment("CYM-1", offsetHours: 1, minutes: 15),
                issueSegment("CYM-2", minutes: 10),
            ],
            workerAccountID: "acc-1",
            asOf: day
        )

        let rows = result.csv.split(separator: "\n").dropFirst()
        #expect(result.rowCount == 2)
        #expect(rows.contains { $0.hasPrefix("CYM-1,acc-1,2026-03-10,09:00:00,2700,") })
        #expect(rows.contains { $0.hasPrefix("CYM-2,acc-1,2026-03-10,09:00:00,600,") })
    }

    @Test("The started time is the earliest start of that day, not the last")
    func tempoUsesEarliestStart() {
        let result = TempoExport.csv(
            [
                issueSegment("CYM-1", offsetHours: 2, minutes: 10),
                issueSegment("CYM-1", minutes: 10),
            ],
            workerAccountID: "acc-1",
            asOf: day
        )
        #expect(result.csv.contains("09:00:00"))
        #expect(!result.csv.contains("11:00:00"))
    }

    @Test("Ad-hoc time is reported as skipped rather than exported without an issue")
    func tempoSkipsAdhoc() {
        // Tempo logs against an issue. Dropping this silently would produce a short timesheet
        // that nobody notices until payroll.
        let result = TempoExport.csv(
            [
                issueSegment("CYM-1", minutes: 30),
                Fixture.segment(Fixture.adhoc(.interruption), from: day, minutes: 20),
            ],
            workerAccountID: "acc-1",
            asOf: day
        )

        #expect(result.rowCount == 1)
        #expect(result.skippedSeconds == 1_200)
        #expect(result.hasSkipped)
        #expect(result.skippedLabels == [Fixture.adhoc(.interruption).displayLabel])
        #expect(!result.csv.contains(Fixture.adhoc(.interruption).displayLabel))
    }

    @Test("Notes become the description, de-duplicated")
    func tempoJoinsNotes() {
        let result = TempoExport.csv(
            [
                issueSegment("CYM-1", minutes: 10, note: "pairing"),
                issueSegment("CYM-1", offsetHours: 1, minutes: 10, note: "pairing"),
                issueSegment("CYM-1", offsetHours: 2, minutes: 10, note: "review"),
            ],
            workerAccountID: "acc-1",
            asOf: day
        )
        #expect(result.csv.contains("pairing; review"))
    }

    @Test("A note containing a comma cannot shift the columns")
    func tempoQuotesNotes() {
        let result = TempoExport.csv(
            [issueSegment("CYM-1", minutes: 10, note: "fixed parser, then tests")],
            workerAccountID: "acc-1",
            asOf: day
        )
        #expect(result.csv.contains("\"fixed parser, then tests\""))
    }

    @Test("A missing worker leaves the column empty rather than guessing")
    func tempoWithoutAccountID() {
        // Tempo will reject the file with a clear message; inventing a worker id would import
        // someone else's time against their name.
        let result = TempoExport.csv(
            [issueSegment("CYM-1", minutes: 10)],
            workerAccountID: nil,
            asOf: day
        )
        #expect(result.csv.contains("CYM-1,,2026-03-10"))
    }

    @Test("Open segments are excluded")
    func tempoIgnoresRunningSegments() {
        let running = WorkSegment(target: Fixture.issue("CYM-9"), start: day, end: nil)
        let result = TempoExport.csv([running], workerAccountID: "acc-1", asOf: day)
        #expect(result.rowCount == 0)
    }
}
