import Foundation
import Testing
@testable import ChronoCore

@Suite("Editing entry times")
@MainActor
struct SegmentEditTests {

    /// Three back-to-back entries: 09:00–10:00, 10:00–11:00, 11:00–12:00.
    private func engineWithThreeEntries() throws -> (TrackingEngine, [UUID]) {
        let engine = try Fixture.engine(clock: MutableClock(Fixture.referenceDate))
        var ids: [UUID] = []
        for index in 0..<3 {
            let start = Fixture.referenceDate.addingTimeInterval(Double(index) * 3_600)
            let segment = try #require(
                engine.backfill(
                    target: Fixture.issue("CYM-\(index + 1)"),
                    start: start,
                    end: start.addingTimeInterval(3_600)
                )
            )
            ids.append(segment.id)
        }
        return (engine, ids)
    }

    private func segment(_ engine: TrackingEngine, _ id: UUID) -> WorkSegment? {
        engine.state.segments.first { $0.id == id }
    }

    // MARK: - Bounds

    @Test("The first entry of the day has no lower bound")
    func firstEntryIsOpenEnded() throws {
        let (engine, ids) = try engineWithThreeEntries()
        let bounds = try #require(engine.bounds(forSegment: ids[0]))
        #expect(bounds.earliestStart == nil)
        #expect(bounds.latestEnd == Fixture.referenceDate.addingTimeInterval(3_600))
    }

    @Test("A middle entry is bounded on both sides by its neighbours")
    func middleEntryIsBoundedBothWays() throws {
        let (engine, ids) = try engineWithThreeEntries()
        let bounds = try #require(engine.bounds(forSegment: ids[1]))
        #expect(bounds.earliestStart == Fixture.referenceDate.addingTimeInterval(3_600))
        #expect(bounds.latestEnd == Fixture.referenceDate.addingTimeInterval(7_200))
    }

    @Test("The last entry has no upper bound while nothing is running")
    func lastEntryIsOpenEnded() throws {
        let (engine, ids) = try engineWithThreeEntries()
        let bounds = try #require(engine.bounds(forSegment: ids[2]))
        #expect(bounds.latestEnd == nil)
    }

    @Test("A running timer caps the last entry")
    func runningTimerIsACeiling() throws {
        // The open segment is not in `segments`, so without this the last entry could be
        // stretched over time that is still accruing.
        let clock = MutableClock(Fixture.referenceDate.addingTimeInterval(14_400))
        let engine = try Fixture.engine(clock: clock)
        let id = try #require(
            engine.backfill(
                target: Fixture.issue("CYM-1"),
                start: Fixture.referenceDate,
                end: Fixture.referenceDate.addingTimeInterval(3_600)
            )
        ).id
        _ = engine.start(Fixture.issue("CYM-9"))

        let bounds = try #require(engine.bounds(forSegment: id))
        #expect(bounds.latestEnd == Fixture.referenceDate.addingTimeInterval(14_400))
    }

    @Test("An unknown id has no bounds")
    func unknownID() throws {
        let (engine, _) = try engineWithThreeEntries()
        #expect(engine.bounds(forSegment: UUID()) == nil)
    }

    // MARK: - Applying an edit

    @Test("A correction inside the available window is applied")
    func editWithinBounds() throws {
        let (engine, ids) = try engineWithThreeEntries()
        let newStart = Fixture.referenceDate.addingTimeInterval(3_600 + 600)   // 10:10
        let newEnd = Fixture.referenceDate.addingTimeInterval(7_200 - 600)     // 10:50

        #expect(engine.editSegmentTimes(id: ids[1], start: newStart, end: newEnd) == .applied)
        let edited = try #require(segment(engine, ids[1]))
        #expect(edited.start == newStart)
        #expect(edited.end == newEnd)
    }

    @Test("Reaching back into the previous entry is refused, and says how far back is allowed")
    func refusesOverlapWithPrevious() throws {
        let (engine, ids) = try engineWithThreeEntries()
        let tooEarly = Fixture.referenceDate.addingTimeInterval(1_800)   // 09:30, inside entry one

        let outcome = engine.editSegmentTimes(
            id: ids[1],
            start: tooEarly,
            end: Fixture.referenceDate.addingTimeInterval(7_200)
        )
        #expect(outcome == .rejected(.overlapsPrevious(
            earliestAllowedStart: Fixture.referenceDate.addingTimeInterval(3_600)
        )))
        // And nothing moved.
        #expect(segment(engine, ids[1])?.start == Fixture.referenceDate.addingTimeInterval(3_600))
    }

    @Test("Reaching forward into the next entry is refused, and says how far forward is allowed")
    func refusesOverlapWithNext() throws {
        let (engine, ids) = try engineWithThreeEntries()
        let tooLate = Fixture.referenceDate.addingTimeInterval(9_000)   // 11:30, inside entry three

        let outcome = engine.editSegmentTimes(
            id: ids[1],
            start: Fixture.referenceDate.addingTimeInterval(3_600),
            end: tooLate
        )
        #expect(outcome == .rejected(.overlapsNext(
            latestAllowedEnd: Fixture.referenceDate.addingTimeInterval(7_200)
        )))
        #expect(segment(engine, ids[1])?.end == Fixture.referenceDate.addingTimeInterval(7_200))
    }

    @Test("Touching a neighbour exactly is allowed")
    func backToBackIsFine() throws {
        // Entries that abut are normal — only genuine overlap is a problem.
        let (engine, ids) = try engineWithThreeEntries()
        let outcome = engine.editSegmentTimes(
            id: ids[1],
            start: Fixture.referenceDate.addingTimeInterval(3_600),
            end: Fixture.referenceDate.addingTimeInterval(7_200)
        )
        #expect(outcome == .applied)
    }

    @Test("A backwards or zero-length entry is refused rather than clamped")
    func refusesEndBeforeStart() throws {
        // `updateSegment` silently clamps this; an explicit edit must say so, or the user is
        // handed a value they never chose.
        let (engine, ids) = try engineWithThreeEntries()
        let start = Fixture.referenceDate.addingTimeInterval(5_000)

        #expect(engine.editSegmentTimes(id: ids[1], start: start, end: start) == .rejected(.endNotAfterStart))
        #expect(
            engine.editSegmentTimes(id: ids[1], start: start, end: start.addingTimeInterval(-60))
                == .rejected(.endNotAfterStart)
        )
    }

    @Test("An unknown id is refused")
    func refusesUnknownID() throws {
        let (engine, _) = try engineWithThreeEntries()
        let outcome = engine.editSegmentTimes(
            id: UUID(),
            start: Fixture.referenceDate,
            end: Fixture.referenceDate.addingTimeInterval(60)
        )
        #expect(outcome == .rejected(.notFound))
    }

    @Test("The running segment cannot be edited this way")
    func refusesOpenSegment() throws {
        // Its times belong to the clock; stopping and backdating are the operations for it.
        let engine = try Fixture.engine(clock: MutableClock(Fixture.referenceDate))
        _ = engine.start(Fixture.issue("CYM-1"))
        let openID = try #require(engine.state.openSegment()?.id)

        let outcome = engine.editSegmentTimes(
            id: openID,
            start: Fixture.referenceDate,
            end: Fixture.referenceDate.addingTimeInterval(60)
        )
        #expect(outcome == .rejected(.segmentIsOpen))
    }

    @Test("An edit survives a reload")
    func editIsPersisted() throws {
        let (engine, ids) = try engineWithThreeEntries()
        let newEnd = Fixture.referenceDate.addingTimeInterval(7_200 - 900)
        #expect(engine.editSegmentTimes(
            id: ids[1],
            start: Fixture.referenceDate.addingTimeInterval(3_600),
            end: newEnd
        ) == .applied)

        engine.flush()
        #expect(segment(engine, ids[1])?.end == newEnd)
    }

    // MARK: - SegmentBounds itself

    @Test("Bounds reject what the engine rejects")
    func boundsAllows() {
        let start = Fixture.referenceDate
        let bounds = SegmentBounds(
            earliestStart: start,
            latestEnd: start.addingTimeInterval(3_600)
        )
        #expect(bounds.allows(start: start, end: start.addingTimeInterval(3_600)))
        #expect(bounds.allows(start: start.addingTimeInterval(-1), end: start.addingTimeInterval(60)) == false)
        #expect(bounds.allows(start: start, end: start.addingTimeInterval(3_601)) == false)
        #expect(bounds.allows(start: start, end: start) == false)
    }

    @Test("Unbounded on both sides allows anything forwards")
    func boundsUnbounded() {
        let bounds = SegmentBounds(earliestStart: nil, latestEnd: nil)
        #expect(bounds.allows(start: Fixture.referenceDate, end: Fixture.referenceDate.addingTimeInterval(1)))
        #expect(bounds.allows(start: Fixture.referenceDate, end: Fixture.referenceDate) == false)
    }
}
