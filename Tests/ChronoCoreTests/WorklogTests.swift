import Foundation
import Testing
@testable import ChronoCore

@Suite("Worklog drafting")
struct WorklogBuilderTests {

    @Test("Rounding modes", arguments: [
        (610.0, 15, RoundingMode.nearest, 900),   // 10m10s -> 15m
        (400.0, 15, RoundingMode.nearest, 0),     // 6m40s  -> 0 (nearest quarter is zero)
        (400.0, 15, RoundingMode.up, 900),
        (1300.0, 15, RoundingMode.down, 900),    // 21m40s -> 15m (20m is not a multiple of 15)
        (95.0, 1, RoundingMode.nearest, 120),
        (95.0, 0, RoundingMode.nearest, 95),      // 0 = don't round
    ])
    func rounding(seconds: Double, minutes: Int, mode: RoundingMode, expected: Int) {
        #expect(WorklogBuilder.round(seconds: seconds, minutes: minutes, mode: mode) == expected)
    }

    @Test("Rounding applies to the daily total, not to each fragment")
    func roundingAppliesToTotal() {
        var settings = Settings()
        settings.roundingMinutes = 15
        settings.roundingMode = .up
        settings.minimumLoggableSeconds = 60

        // Twelve 90-second fragments. Rounded individually and up, that would invent 3 hours.
        let start = Fixture.referenceDate
        let segments = (0..<12).map { index in
            Fixture.segment(
                Fixture.issue("CYM-1"),
                from: start.addingTimeInterval(Double(index) * 300),
                minutes: 1.5
            )
        }

        let drafts = WorklogBuilder.buildDrafts(
            from: segments, settings: settings, coveredSegmentIDs: [], now: start
        )

        #expect(drafts.count == 1)
        // 18 minutes of real work rounds up to 30, not to 12 x 15 = 180.
        #expect(drafts[0].seconds == 1800)
    }

    @Test("One draft per issue per day")
    func groupsByIssueAndDay() {
        let settings = Settings()
        let day1 = Fixture.referenceDate
        let day2 = day1.addingTimeInterval(86_400)

        let segments = [
            Fixture.segment(Fixture.issue("CYM-1"), from: day1, minutes: 30),
            Fixture.segment(Fixture.issue("CYM-1"), from: day1.addingTimeInterval(7200), minutes: 30),
            Fixture.segment(Fixture.issue("CYM-2"), from: day1.addingTimeInterval(3600), minutes: 30),
            Fixture.segment(Fixture.issue("CYM-1"), from: day2, minutes: 45),
        ]

        let drafts = WorklogBuilder.buildDrafts(
            from: segments, settings: settings, coveredSegmentIDs: [], now: day2
        )

        #expect(drafts.count == 3)
        let cym1Day1 = drafts.first { $0.issueKey == "CYM-1" && $0.seconds == 3600 }
        #expect(cym1Day1 != nil, "two 30m stretches on the same day merge into one 1h worklog")
        #expect(drafts.contains { $0.issueKey == "CYM-1" && $0.seconds == 2700 })
        #expect(drafts.contains { $0.issueKey == "CYM-2" && $0.seconds == 1800 })
    }

    @Test("Time below the minimum is not logged and not consumed")
    func belowMinimumRollsForward() {
        var settings = Settings()
        settings.minimumLoggableSeconds = 300

        let start = Fixture.referenceDate
        let short = Fixture.segment(Fixture.issue("CYM-1"), from: start, minutes: 1)

        let first = WorklogBuilder.buildDrafts(
            from: [short], settings: settings, coveredSegmentIDs: [], now: start
        )
        #expect(first.isEmpty, "one minute is below the threshold")

        // Later the same day, more work on the same issue arrives.
        let more = Fixture.segment(Fixture.issue("CYM-1"), from: start.addingTimeInterval(3600), minutes: 10)
        let second = WorklogBuilder.buildDrafts(
            from: [short, more], settings: settings, coveredSegmentIDs: [], now: start
        )
        #expect(second.count == 1)
        #expect(second[0].seconds == 660, "the earlier minute must not be lost")
    }

    @Test("Ad-hoc time is never drafted")
    func adhocIsNotDrafted() {
        let drafts = WorklogBuilder.buildDrafts(
            from: [Fixture.segment(Fixture.adhoc(.call), from: Fixture.referenceDate, minutes: 45)],
            settings: Settings(),
            coveredSegmentIDs: [],
            now: Fixture.referenceDate
        )
        #expect(drafts.isEmpty)
    }

    @Test("Covered segments are skipped")
    func coveredSegmentsSkipped() {
        let segment = Fixture.segment(Fixture.issue("CYM-1"), from: Fixture.referenceDate, minutes: 60)
        let drafts = WorklogBuilder.buildDrafts(
            from: [segment],
            settings: Settings(),
            coveredSegmentIDs: [segment.id],
            now: Fixture.referenceDate
        )
        #expect(drafts.isEmpty)
    }

    @Test("A session over midnight is split so each day is logged on its own date")
    func splitsAcrossMidnight() {
        let calendar = Calendar.current
        // 23:30 for 90 minutes.
        let lateStart = calendar.date(
            bySettingHour: 23, minute: 30, second: 0, of: Fixture.referenceDate
        )!
        let segment = Fixture.segment(Fixture.issue("CYM-1"), from: lateStart, minutes: 90)

        let drafts = WorklogBuilder.buildDrafts(
            from: [segment],
            settings: Settings(),
            coveredSegmentIDs: [],
            now: lateStart.addingTimeInterval(5400)
        )

        #expect(drafts.count == 2, "one worklog per calendar day")
        #expect(drafts.map(\.seconds).sorted() == [1800, 3600])
    }

    @Test("Notes become the comment, de-duplicated in first-seen order")
    func commentDeduplication() {
        var settings = Settings()
        settings.includeNoteAsComment = true
        let start = Fixture.referenceDate

        let segments = [
            Fixture.segment(Fixture.issue("CYM-1"), from: start, minutes: 20, note: "Fixing the parser"),
            Fixture.segment(Fixture.issue("CYM-1"), from: start.addingTimeInterval(1800), minutes: 20, note: "Fixing the parser"),
            Fixture.segment(Fixture.issue("CYM-1"), from: start.addingTimeInterval(3600), minutes: 20, note: "Writing tests"),
        ]

        let drafts = WorklogBuilder.buildDrafts(
            from: segments, settings: settings, coveredSegmentIDs: [], now: start
        )
        #expect(drafts[0].comment == "Fixing the parser\nWriting tests")
    }

    @Test("Open segments are ignored — a running timer has not finished producing time")
    func openSegmentsIgnored() {
        let open = WorkSegment(target: Fixture.issue("CYM-1"), start: Fixture.referenceDate, end: nil)
        let drafts = WorklogBuilder.buildDrafts(
            from: [open], settings: Settings(), coveredSegmentIDs: [], now: Fixture.referenceDate.addingTimeInterval(3600)
        )
        #expect(drafts.isEmpty)
    }
}

@Suite("Worklog sync queue")
struct WorklogSyncQueueTests {

    private func draft(seconds: Int = 3600, attempts: Int = 0, lastAttempt: Date? = nil) -> WorklogDraft {
        WorklogDraft(
            issueKey: "CYM-1",
            started: Fixture.referenceDate,
            seconds: seconds,
            comment: "work",
            attempts: attempts,
            createdAt: Fixture.referenceDate,
            lastAttemptAt: lastAttempt
        )
    }

    @Test("A pending draft is submitted and marked done")
    func submitsPendingDraft() async throws {
        let jira = FakeJira()
        let queue = WorklogSyncQueue(api: jira, accountID: "acct-1", clock: MutableClock(Fixture.referenceDate))

        let outcome = await queue.process(drafts: [draft()], settings: Settings())

        #expect(outcome.updated.count == 1)
        #expect(outcome.updated[0].state == .submitted)
        #expect(outcome.submittedSeconds == 3600)
        #expect(await jira.createCallCount == 1)
    }

    @Test("A network failure is recorded as retryable and does not lose the draft")
    func networkFailureIsRetryable() async throws {
        let jira = FakeJira()
        await jira.scheduleFailures([.transport("offline")])
        let queue = WorklogSyncQueue(api: jira, accountID: "acct-1", clock: MutableClock(Fixture.referenceDate))

        let outcome = await queue.process(drafts: [draft()], settings: Settings())

        #expect(outcome.updated[0].state == .failed(.network))
        #expect(outcome.updated[0].isRetryable)
        #expect(outcome.updated[0].attempts == 1)
        #expect(outcome.blockingError != nil)
    }

    @Test("An auth failure is not retryable and stops the run early")
    func authFailureStopsRun() async throws {
        let jira = FakeJira()
        await jira.scheduleFailures([.http(status: 401, message: "bad token")])
        let queue = WorklogSyncQueue(api: jira, accountID: "acct-1", clock: MutableClock(Fixture.referenceDate))

        let outcome = await queue.process(drafts: [draft(), draft(seconds: 1800)], settings: Settings())

        #expect(outcome.updated.count == 1, "the second draft would fail identically, so it is not attempted")
        #expect(outcome.updated[0].state == .failed(.authentication))
        #expect(outcome.updated[0].isRetryable == false)
    }

    @Test("A retry after an ambiguous timeout adopts the existing worklog instead of duplicating")
    func retryDoesNotDoubleLog() async throws {
        let jira = FakeJira()
        let clock = MutableClock(Fixture.referenceDate)
        let queue = WorklogSyncQueue(api: jira, accountID: "acct-1", clock: clock)

        // Jira committed the worklog but the response never arrived.
        let pending = draft()
        await jira.seedExisting(
            JiraWorklog(
                id: "already-there",
                issueKey: "CYM-1",
                started: pending.started,
                seconds: pending.seconds,
                authorAccountID: "acct-1",
                comment: "work"
            )
        )

        // The draft is on its second attempt, so the duplicate check runs.
        let outcome = await queue.process(
            drafts: [draft(attempts: 1, lastAttempt: Fixture.referenceDate.addingTimeInterval(-3600))],
            settings: Settings()
        )

        #expect(outcome.updated[0].state == .submitted)
        #expect(outcome.updated[0].remoteWorklogID == "already-there")
        #expect(await jira.createCallCount == 0, "must not POST a second worklog")
    }

    @Test("A worklog by someone else is not mistaken for ours")
    func othersWorklogsIgnored() async throws {
        let jira = FakeJira()
        let pending = draft(attempts: 1, lastAttempt: Fixture.referenceDate.addingTimeInterval(-3600))
        await jira.seedExisting(
            JiraWorklog(
                id: "colleague",
                issueKey: "CYM-1",
                started: pending.started,
                seconds: pending.seconds,
                authorAccountID: "someone-else",
                comment: ""
            )
        )
        let queue = WorklogSyncQueue(api: jira, accountID: "acct-1", clock: MutableClock(Fixture.referenceDate))

        let outcome = await queue.process(drafts: [pending], settings: Settings())

        #expect(outcome.updated[0].state == .submitted)
        #expect(await jira.createCallCount == 1, "our time still needs logging")
    }

    @Test("Backoff defers a recently-attempted draft, and force overrides it")
    func backoffIsRespected() async throws {
        let jira = FakeJira()
        let clock = MutableClock(Fixture.referenceDate)
        let queue = WorklogSyncQueue(api: jira, accountID: "acct-1", clock: clock)

        // Attempted one second ago with 3 attempts behind it: nowhere near due.
        let recent = WorklogDraft(
            issueKey: "CYM-1",
            started: Fixture.referenceDate,
            seconds: 3600,
            state: .failed(.network),
            attempts: 3,
            createdAt: Fixture.referenceDate,
            lastAttemptAt: Fixture.referenceDate.addingTimeInterval(-1)
        )

        let deferred = await queue.process(drafts: [recent], settings: Settings())
        #expect(deferred.updated.isEmpty)
        #expect(await jira.createCallCount == 0)

        let forced = await queue.process(drafts: [recent], settings: Settings(), force: true)
        #expect(forced.updated.count == 1)
        #expect(await jira.createCallCount == 1)
    }

    @Test("If the duplicate check itself fails, we submit rather than silently drop time")
    func unverifiableStateFavoursSubmitting() async throws {
        let jira = FakeJira()
        await jira.setWorklogLookupFails(true)
        let queue = WorklogSyncQueue(api: jira, accountID: "acct-1", clock: MutableClock(Fixture.referenceDate))

        let outcome = await queue.process(
            drafts: [draft(attempts: 1, lastAttempt: Fixture.referenceDate.addingTimeInterval(-3600))],
            settings: Settings()
        )

        #expect(outcome.updated[0].state == .submitted)
        #expect(await jira.createCallCount == 1)
    }

    @Test("Backoff grows with attempts and is capped")
    func backoffGrowsAndCaps() {
        let base = draft()
        var previous: TimeInterval = 0
        for attempts in 0...10 {
            var d = base
            d.attempts = attempts
            let delay = d.nextRetryDelay()
            #expect(delay >= previous)
            #expect(delay <= 30 * 60, "backoff must never exceed the 30 minute ceiling")
            previous = delay
        }
    }
}
