import Foundation
import Testing
@testable import ChronoCore

@Suite("Calendar events")
struct CalendarEventTests {

    private let base = Fixture.referenceDate   // 2026-03-10 09:00

    private func event(
        _ title: String,
        offsetMinutes: Double,
        lengthMinutes: Double,
        allDay: Bool = false
    ) -> CalendarEvent {
        let start = base.addingTimeInterval(offsetMinutes * 60)
        return CalendarEvent(
            id: "\(title)-\(offsetMinutes)",
            title: title,
            start: start,
            end: start.addingTimeInterval(lengthMinutes * 60),
            calendarTitle: "Work",
            accountName: "someone@example.com",
            isAllDay: allDay
        )
    }

    // MARK: - Which event am I in

    @Test("Picks the event covering the instant")
    func picksCoveringEvent() {
        let events = [event("Standup", offsetMinutes: 0, lengthMinutes: 15)]
        let match = CalendarMatching.event(covering: base.addingTimeInterval(300), in: events)
        #expect(match?.title == "Standup")
    }

    @Test("Nothing is returned outside every event")
    func nothingWhenFree() {
        let events = [event("Standup", offsetMinutes: 0, lengthMinutes: 15)]
        #expect(CalendarMatching.event(covering: base.addingTimeInterval(3_600), in: events) == nil)
    }

    @Test("The end is exclusive, so back-to-back meetings do not both match")
    func endIsExclusive() {
        let first = event("Standup", offsetMinutes: 0, lengthMinutes: 30)
        let second = event("Review", offsetMinutes: 30, lengthMinutes: 30)
        let atBoundary = base.addingTimeInterval(30 * 60)
        let match = CalendarMatching.event(covering: atBoundary, in: [first, second])
        #expect(match?.title == "Review")
    }

    @Test("All-day events are never treated as meetings")
    func ignoresAllDay() {
        // "Alice on leave" describes a day, not something you are in.
        let events = [event("Alice on leave", offsetMinutes: -540, lengthMinutes: 1_440, allDay: true)]
        #expect(CalendarMatching.event(covering: base, in: events) == nil)
    }

    @Test("The shortest overlapping meeting wins")
    func shortestWins() {
        // A two-hour focus block should not swallow the standup inside it.
        let block = event("Focus time", offsetMinutes: 0, lengthMinutes: 120)
        let standup = event("Standup", offsetMinutes: 30, lengthMinutes: 15)
        let match = CalendarMatching.event(covering: base.addingTimeInterval(35 * 60), in: [block, standup])
        #expect(match?.title == "Standup")
    }

    @Test("Equal-length overlaps resolve stably, not by input order")
    func stableTieBreak() {
        let a = event("Alpha", offsetMinutes: 0, lengthMinutes: 30)
        let b = event("Beta", offsetMinutes: 0, lengthMinutes: 30)
        let instant = base.addingTimeInterval(600)
        let forwards = CalendarMatching.event(covering: instant, in: [a, b])
        let backwards = CalendarMatching.event(covering: instant, in: [b, a])
        #expect(forwards == backwards)
        #expect(forwards?.title == "Alpha")
    }

    @Test("A later start breaks a length tie, since the newer thing is what you joined")
    func laterStartWins() {
        let earlier = event("Earlier", offsetMinutes: 0, lengthMinutes: 60)
        let later = event("Later", offsetMinutes: 30, lengthMinutes: 60)
        let match = CalendarMatching.event(covering: base.addingTimeInterval(45 * 60), in: [earlier, later])
        #expect(match?.title == "Later")
    }

    // MARK: - What did I forget to track

    @Test("An entirely untracked meeting is offered")
    func offersUntracked() {
        let meeting = event("Retro", offsetMinutes: 0, lengthMinutes: 60)
        let untracked = CalendarMatching.untrackedEvents([meeting], trackedRanges: [])
        #expect(untracked.map(\.title) == ["Retro"])
    }

    @Test("A fully tracked meeting is not offered")
    func skipsTracked() {
        let meeting = event("Retro", offsetMinutes: 0, lengthMinutes: 60)
        let untracked = CalendarMatching.untrackedEvents(
            [meeting],
            trackedRanges: [(meeting.start, meeting.end)]
        )
        #expect(untracked.isEmpty)
    }

    @Test("Joining a few minutes late still counts as tracked")
    func partialCoverageCounts() {
        // A meeting is not forgotten because the timer started two minutes in.
        let meeting = event("Retro", offsetMinutes: 0, lengthMinutes: 60)
        let untracked = CalendarMatching.untrackedEvents(
            [meeting],
            trackedRanges: [(meeting.start.addingTimeInterval(120), meeting.end)]
        )
        #expect(untracked.isEmpty)
    }

    @Test("A meeting only dipped into is still offered")
    func lowCoverageStillOffered() {
        let meeting = event("Retro", offsetMinutes: 0, lengthMinutes: 60)
        let untracked = CalendarMatching.untrackedEvents(
            [meeting],
            trackedRanges: [(meeting.start, meeting.start.addingTimeInterval(300))]   // 5 of 60
        )
        #expect(untracked.map(\.title) == ["Retro"])
    }

    @Test("Coverage adds up across several tracked stretches")
    func coverageAccumulates() {
        // Paused in the middle and resumed: two segments, together most of the meeting.
        let meeting = event("Workshop", offsetMinutes: 0, lengthMinutes: 60)
        let untracked = CalendarMatching.untrackedEvents(
            [meeting],
            trackedRanges: [
                (meeting.start, meeting.start.addingTimeInterval(1_200)),
                (meeting.start.addingTimeInterval(1_500), meeting.end),
            ]
        )
        #expect(untracked.isEmpty)
    }

    @Test("Tracked time outside the meeting does not count towards it")
    func overlapIsClamped() {
        let meeting = event("Retro", offsetMinutes: 60, lengthMinutes: 30)
        let untracked = CalendarMatching.untrackedEvents(
            [meeting],
            trackedRanges: [(base, base.addingTimeInterval(3_600))]   // all before it starts
        )
        #expect(untracked.map(\.title) == ["Retro"])
    }

    @Test("All-day events are never offered for backfill")
    func neverBackfillAllDay() {
        // Nobody wants "Bank holiday" backfilled as eight hours.
        let holiday = event("Bank holiday", offsetMinutes: 0, lengthMinutes: 1_440, allDay: true)
        #expect(CalendarMatching.untrackedEvents([holiday], trackedRanges: []).isEmpty)
    }

    @Test("Zero-length events are ignored")
    func ignoresZeroLength() {
        let blip = event("Reminder", offsetMinutes: 0, lengthMinutes: 0)
        #expect(CalendarMatching.untrackedEvents([blip], trackedRanges: []).isEmpty)
    }

    @Test("Offers come back in the order they happened")
    func sortedByStart() {
        let late = event("Late", offsetMinutes: 120, lengthMinutes: 30)
        let early = event("Early", offsetMinutes: 0, lengthMinutes: 30)
        let untracked = CalendarMatching.untrackedEvents([late, early], trackedRanges: [])
        #expect(untracked.map(\.title) == ["Early", "Late"])
    }
}

@Suite("Calendar-named targets")
struct CalendarTargetTests {

    private func event(id: String, title: String) -> CalendarEvent {
        CalendarEvent(
            id: id,
            title: title,
            start: Fixture.referenceDate,
            end: Fixture.referenceDate.addingTimeInterval(1_800),
            calendarTitle: "Work",
            accountName: "someone@example.com"
        )
    }

    @Test("Rejoining the same meeting reuses the same target")
    func stableAcrossRejoins() {
        // The rollup groups by `TrackingTarget.id`. A fresh UUID each time would split one
        // meeting into two timesheet rows.
        let first = AdhocRef.forCalendarEvent(event(id: "abc-123", title: "Standup"))
        let second = AdhocRef.forCalendarEvent(event(id: "abc-123", title: "Standup"))
        #expect(first.id == second.id)
        #expect(TrackingTarget.adhoc(first).id == TrackingTarget.adhoc(second).id)
    }

    @Test("Different meetings get different targets")
    func distinctEvents() {
        let standup = AdhocRef.forCalendarEvent(event(id: "abc-123", title: "Standup"))
        let retro = AdhocRef.forCalendarEvent(event(id: "def-456", title: "Retro"))
        #expect(standup.id != retro.id)
    }

    @Test("A renamed event keeps its identity")
    func renameKeepsIdentity() {
        // Titles change; the identifier is what EventKit considers the same event.
        let before = AdhocRef.forCalendarEvent(event(id: "abc-123", title: "Standup"))
        let after = AdhocRef.forCalendarEvent(event(id: "abc-123", title: "Daily standup"))
        #expect(before.id == after.id)
        #expect(after.label == "Daily standup")
    }

    @Test("The target is labelled with the event and categorised as a meeting")
    func labelling() {
        let target = AdhocRef.forCalendarEvent(event(id: "abc-123", title: "Sprint review"))
        #expect(target.label == "Sprint review")
        #expect(target.category == .meeting)
        #expect(TrackingTarget.adhoc(target).displayLabel == "Sprint review")
    }

    @Test("The derived id is a well-formed version 5 UUID")
    func wellFormedUUID() {
        let id = AdhocRef.stableID(for: "abc-123")
        let text = id.uuidString
        // Version nibble and variant bits, so this is a real name-based UUID.
        #expect(text[text.index(text.startIndex, offsetBy: 14)] == "5")
        // `uuidString` is upper case, so compare case-insensitively.
        let variant = text[text.index(text.startIndex, offsetBy: 19)]
        #expect("89AB".contains(variant.uppercased()))
    }
}
