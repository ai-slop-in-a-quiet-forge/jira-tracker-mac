import Foundation
import Testing
@testable import ChronoCore

@Suite("Tracking engine state machine")
@MainActor
struct EngineTests {

    @Test("Starting from idle opens a running segment")
    func startFromIdle() throws {
        let clock = MutableClock(Fixture.referenceDate)
        let engine = try Fixture.engine(clock: clock)

        engine.start(Fixture.issue("CYM-1"))

        #expect(engine.isRunning)
        #expect(engine.activeTarget?.issueKey == "CYM-1")
        clock.advance(by: 90)
        engine.tick()
        #expect(engine.currentSegmentElapsed == 90)
    }

    @Test("Pause closes the segment but keeps the selection, and resume opens a new one")
    func pauseKeepsSelection() throws {
        let clock = MutableClock(Fixture.referenceDate)
        let engine = try Fixture.engine(clock: clock)

        engine.start(Fixture.issue("CYM-1"))
        clock.advance(by: 600)
        engine.pause()

        #expect(engine.isPaused)
        #expect(engine.activeTarget?.issueKey == "CYM-1", "pausing must not deselect the task")
        #expect(engine.state.segments.count == 1)
        #expect(engine.state.segments[0].closedDuration == 600)

        // Time spent paused must not accrue.
        clock.advance(by: 3600)
        engine.tick()
        #expect(engine.currentSegmentElapsed == 0)

        engine.resume()
        clock.advance(by: 120)
        engine.tick()
        #expect(engine.isRunning)
        #expect(engine.state.segments.count == 1, "resuming opens a new segment, it does not close one")
        #expect(engine.currentSegmentElapsed == 120)
    }

    @Test("Starting the already-running task is a no-op rather than a restart")
    func startSameTargetIsIdempotent() throws {
        let clock = MutableClock(Fixture.referenceDate)
        let engine = try Fixture.engine(clock: clock)

        engine.start(Fixture.issue("CYM-1"))
        clock.advance(by: 300)
        engine.start(Fixture.issue("CYM-1"))

        engine.tick()
        #expect(engine.currentSegmentElapsed == 300, "restarting the same task would lose 5 minutes")
        #expect(engine.state.segments.isEmpty)
    }

    @Test("Starting the paused task resumes it instead of orphaning it")
    func startPausedTargetResumes() throws {
        let clock = MutableClock(Fixture.referenceDate)
        let engine = try Fixture.engine(clock: clock)

        engine.start(Fixture.issue("CYM-1"))
        clock.advance(by: 60)
        engine.pause()
        clock.advance(by: 60)
        engine.start(Fixture.issue("CYM-1"))

        #expect(engine.isRunning)
        #expect(engine.state.segments.count == 1)
    }

    @Test("Switching tasks closes the old segment and opens a new one atomically")
    func switchingTasks() throws {
        let clock = MutableClock(Fixture.referenceDate)
        let engine = try Fixture.engine(clock: clock)

        engine.start(Fixture.issue("CYM-1"))
        clock.advance(by: 1800)
        engine.start(Fixture.issue("CYM-2"))

        #expect(engine.state.segments.count == 1)
        #expect(engine.state.segments[0].target.issueKey == "CYM-1")
        #expect(engine.state.segments[0].closedDuration == 1800)
        #expect(engine.activeTarget?.issueKey == "CYM-2")
        #expect(engine.isRunning, "there must be no gap where nothing is tracked")
    }

    @Test("Stopping settles every unsubmitted segment, not just the current task")
    func stopSettlesEverything() throws {
        let clock = MutableClock(Fixture.referenceDate)
        let engine = try Fixture.engine(clock: clock)

        engine.start(Fixture.issue("CYM-1"))
        clock.advance(by: 3600)
        engine.start(Fixture.issue("CYM-2"))
        clock.advance(by: 1800)
        let drafts = engine.stop()

        #expect(engine.status == .idle)
        #expect(drafts.count == 2, "A → B → stop must leave nothing stranded")
        #expect(Set(drafts.map(\.issueKey)) == ["CYM-1", "CYM-2"])
        #expect(drafts.first { $0.issueKey == "CYM-1" }?.seconds == 3600)
        #expect(drafts.first { $0.issueKey == "CYM-2" }?.seconds == 1800)
    }

    @Test("Stopping twice does not draft the same time again")
    func settlingIsIdempotent() throws {
        let clock = MutableClock(Fixture.referenceDate)
        let engine = try Fixture.engine(clock: clock)

        engine.start(Fixture.issue("CYM-1"))
        clock.advance(by: 3600)
        _ = engine.stop()
        let again = engine.settle()

        #expect(again.isEmpty)
        #expect(engine.state.drafts.count == 1)
    }

    @Test("Discarding the open segment throws the time away without logging it")
    func discardOpenSegment() throws {
        let clock = MutableClock(Fixture.referenceDate)
        let engine = try Fixture.engine(clock: clock)

        engine.start(Fixture.issue("CYM-1"))
        clock.advance(by: 900)
        engine.discardOpenSegment()

        #expect(engine.state.segments.isEmpty)
        #expect(engine.isPaused)
        #expect(engine.activeTarget?.issueKey == "CYM-1")
    }

    @Test("Sub-second segments are dropped as double-click noise")
    func tinySegmentsDropped() throws {
        let clock = MutableClock(Fixture.referenceDate)
        let engine = try Fixture.engine(clock: clock)

        engine.start(Fixture.issue("CYM-1"))
        clock.advance(by: 0.2)
        engine.pause()

        #expect(engine.state.segments.isEmpty)
    }

    // MARK: - Idle

    @Test("Discarding idle time trims the tail and keeps the timer running")
    func idleDiscardKeepsRunning() throws {
        let clock = MutableClock(Fixture.referenceDate)
        let engine = try Fixture.engine(clock: clock)

        engine.start(Fixture.issue("CYM-1"))
        clock.advance(by: 1800)          // 20 min work + 10 min idle
        engine.resolveIdle(.discard, idleSeconds: 600)

        #expect(engine.isRunning, "'discard' means keep working, just without the idle time")
        #expect(engine.state.segments.count == 1)
        #expect(engine.state.segments[0].closedDuration == 1200)
        #expect(engine.state.segments[0].trimmedIdle == 600)
    }

    @Test("Idle discard-and-pause trims the tail and stops the clock")
    func idleDiscardAndPause() throws {
        let clock = MutableClock(Fixture.referenceDate)
        let engine = try Fixture.engine(clock: clock)

        engine.start(Fixture.issue("CYM-1"))
        clock.advance(by: 1800)
        engine.resolveIdle(.discardAndPause, idleSeconds: 600)

        #expect(engine.isPaused)
        #expect(engine.state.segments[0].closedDuration == 1200)
    }

    @Test("Keeping idle time leaves the segment untouched")
    func idleKeep() throws {
        let clock = MutableClock(Fixture.referenceDate)
        let engine = try Fixture.engine(clock: clock)

        engine.start(Fixture.issue("CYM-1"))
        clock.advance(by: 1800)
        engine.resolveIdle(.keep, idleSeconds: 600)
        engine.tick()

        #expect(engine.isRunning)
        #expect(engine.state.segments.isEmpty, "nothing should have been closed")
        #expect(engine.currentSegmentElapsed == 1800)
    }

    @Test("Idle longer than the segment cannot rewind past its start")
    func idleCannotProduceNegativeTime() throws {
        let clock = MutableClock(Fixture.referenceDate)
        let engine = try Fixture.engine(clock: clock)

        engine.start(Fixture.issue("CYM-1"))
        clock.advance(by: 120)
        engine.resolveIdle(.discardAndPause, idleSeconds: 9999)

        // The whole segment was idle, so it collapses to nothing rather than going negative.
        #expect(engine.state.segments.allSatisfy { $0.closedDuration >= 0 })
        #expect(engine.state.segments.reduce(0) { $0 + $1.closedDuration } == 0)
    }

    // MARK: - Backdating and editing

    @Test("Backdating the start extends the running segment")
    func backdateStart() throws {
        let clock = MutableClock(Fixture.referenceDate)
        let engine = try Fixture.engine(clock: clock)

        engine.start(Fixture.issue("CYM-1"))
        clock.advance(by: 60)
        #expect(engine.backdateStart(by: 600))
        engine.tick()

        #expect(engine.currentSegmentElapsed == 660)
    }

    @Test("Backdating cannot overlap the previous segment")
    func backdateRefusesOverlap() throws {
        let clock = MutableClock(Fixture.referenceDate)
        let engine = try Fixture.engine(clock: clock)

        engine.start(Fixture.issue("CYM-1"))
        clock.advance(by: 600)
        engine.start(Fixture.issue("CYM-2"))   // closes CYM-1 at +600
        clock.advance(by: 60)

        #expect(engine.backdateStart(by: 3600) == false, "would double-count time already on CYM-1")
    }

    @Test("Backfilled time lands in history and can be drafted")
    func backfill() throws {
        let clock = MutableClock(Fixture.referenceDate)
        let engine = try Fixture.engine(clock: clock)

        let start = Fixture.referenceDate.addingTimeInterval(-7200)
        let segment = engine.backfill(
            target: Fixture.issue("CYM-9"),
            start: start,
            end: start.addingTimeInterval(1800),
            note: "Forgot to track the standup"
        )

        #expect(segment != nil)
        #expect(engine.state.segments.count == 1)
        let drafts = engine.settle()
        #expect(drafts.count == 1)
        #expect(drafts[0].seconds == 1800)
        #expect(drafts[0].comment == "Forgot to track the standup")
    }

    @Test("Backfill rejects an end before the start")
    func backfillRejectsInverted() throws {
        let clock = MutableClock(Fixture.referenceDate)
        let engine = try Fixture.engine(clock: clock)
        let result = engine.backfill(
            target: Fixture.issue("CYM-9"),
            start: Fixture.referenceDate,
            end: Fixture.referenceDate.addingTimeInterval(-60)
        )
        #expect(result == nil)
    }

    // MARK: - Ad-hoc reconciliation

    @Test("Assigning an ad-hoc bucket to an issue makes its time loggable, timestamps intact")
    func assignAdhocToIssue() throws {
        let clock = MutableClock(Fixture.referenceDate)
        let engine = try Fixture.engine(clock: clock)

        let bucketID = UUID()
        engine.start(Fixture.adhoc(.meeting, id: bucketID))
        clock.advance(by: 2700)
        engine.pause()

        #expect(engine.settle().isEmpty, "ad-hoc time has no issue, so it cannot be drafted yet")
        #expect(engine.unfiledSecondsToday == 2700)

        let changed = engine.assign(adhocID: bucketID, to: IssueRef(key: "CYM-50", summary: "Ceremonies"))
        #expect(changed >= 1)

        let drafts = engine.settle()
        #expect(drafts.count == 1)
        #expect(drafts[0].issueKey == "CYM-50")
        #expect(drafts[0].seconds == 2700, "reassignment must not alter the recorded duration")
        #expect(drafts[0].started == Fixture.referenceDate, "nor the original start time")
    }

    @Test("Retargeting a segment releases the draft that claimed it")
    func retargetReleasesDraft() throws {
        let clock = MutableClock(Fixture.referenceDate)
        let engine = try Fixture.engine(clock: clock)

        engine.start(Fixture.issue("CYM-1"))
        clock.advance(by: 3600)
        _ = engine.stop()
        #expect(engine.state.drafts.count == 1)

        let segmentID = engine.state.segments[0].id
        engine.retarget(segmentID: segmentID, to: Fixture.issue("CYM-2"))

        #expect(engine.state.drafts.isEmpty, "the stale draft must not survive a retarget")
        let redrafted = engine.settle()
        #expect(redrafted.count == 1)
        #expect(redrafted[0].issueKey == "CYM-2")
    }

    @Test("Releasing a draft frees its segments to be drafted again")
    func releaseDraft() throws {
        let clock = MutableClock(Fixture.referenceDate)
        let engine = try Fixture.engine(clock: clock)

        engine.start(Fixture.issue("CYM-1"))
        clock.advance(by: 3600)
        let drafts = engine.stop()
        engine.releaseDraft(id: drafts[0].id)

        #expect(engine.settle().count == 1)
    }

    @Test("A discarded draft keeps its segments claimed so it does not reappear")
    func discardedDraftStaysGone() throws {
        let clock = MutableClock(Fixture.referenceDate)
        let engine = try Fixture.engine(clock: clock)

        engine.start(Fixture.issue("CYM-1"))
        clock.advance(by: 3600)
        let drafts = engine.stop()
        engine.discardDraft(id: drafts[0].id)

        #expect(engine.settle().isEmpty)
        #expect(engine.state.drafts[0].state == .discarded)
    }

    // MARK: - Crash recovery

    @Test("A timer running at a crash is recovered up to the last heartbeat, not to now")
    func crashRecoveryUsesHeartbeat() throws {
        let clock = MutableClock(Fixture.referenceDate)
        let store = try Fixture.tempStore()

        // Session one: start tracking, heartbeat for an hour, then vanish without stopping.
        let first = TrackingEngine(store: store, clock: clock)
        first.start(Fixture.issue("CYM-1"))
        clock.advance(by: 3600)
        first.tick()
        store.flush()

        // Sixteen hours later the machine is opened again.
        clock.advance(by: 16 * 3600)
        let second = TrackingEngine(store: store, clock: clock)

        let proposal = try #require(second.pendingRecovery)
        #expect(proposal.target.issueKey == "CYM-1")
        #expect(proposal.confidentSeconds == 3600, "only the heartbeat-backed hour is trustworthy")
        #expect(proposal.unknownSeconds == 16 * 3600)
        #expect(second.isRunning == false, "the clock must not keep accruing while we ask")

        second.resolveRecovery(.keepUntilLastActivity)
        #expect(second.state.segments.count == 1)
        #expect(second.state.segments[0].closedDuration == 3600)
        #expect(second.state.segments[0].source == .recovered)
        #expect(second.status == .idle)
    }

    @Test("Discarding a recovered session logs nothing")
    func crashRecoveryDiscard() throws {
        let clock = MutableClock(Fixture.referenceDate)
        let store = try Fixture.tempStore()

        let first = TrackingEngine(store: store, clock: clock)
        first.start(Fixture.issue("CYM-1"))
        clock.advance(by: 3600)
        first.tick()
        store.flush()

        clock.advance(by: 20 * 3600)
        let second = TrackingEngine(store: store, clock: clock)
        second.resolveRecovery(.discard)

        #expect(second.state.segments.isEmpty)
        #expect(second.state.drafts.isEmpty)
    }

    @Test("An immediate relaunch just keeps running instead of nagging")
    func immediateRelaunchDoesNotPrompt() throws {
        let clock = MutableClock(Fixture.referenceDate)
        let store = try Fixture.tempStore()

        let first = TrackingEngine(store: store, clock: clock)
        first.start(Fixture.issue("CYM-1"))
        clock.advance(by: 300)
        first.tick()
        store.flush()

        clock.advance(by: 10)   // relaunched a moment later
        let second = TrackingEngine(store: store, clock: clock)

        #expect(second.pendingRecovery == nil)
        #expect(second.isRunning)
    }

    // MARK: - Persistence round trip

    @Test("State survives a relaunch")
    func statePersists() throws {
        let clock = MutableClock(Fixture.referenceDate)
        let store = try Fixture.tempStore()

        let first = TrackingEngine(store: store, clock: clock)
        first.start(Fixture.issue("CYM-7", "Persisted work"))
        clock.advance(by: 600)
        first.pause()
        first.setNote("halfway through")
        first.flush()

        let second = TrackingEngine(store: store, clock: clock)
        #expect(second.isPaused)
        #expect(second.activeTarget?.issueKey == "CYM-7")
        #expect(second.state.segments.count == 1)
        #expect(second.state.openSegmentNote == "halfway through")
    }
}
