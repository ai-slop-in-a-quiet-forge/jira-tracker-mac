import Foundation
import Testing
@testable import ChronoCore

@Suite("Meeting detection")
struct MeetingSignalTests {

    private func snapshot(
        mic: Bool = false,
        camera: Bool = false,
        frontmost: String? = nil,
        running: Set<String> = [],
        browser: Bool = false
    ) -> ActivitySnapshot {
        ActivitySnapshot(
            timestamp: Fixture.referenceDate,
            idleSeconds: 5,
            microphoneInUse: mic,
            cameraInUse: camera,
            frontmostBundleID: frontmost,
            runningMeetingApps: running,
            browserRunning: browser
        )
    }

    @Test("Microphone alone is not a meeting — dictation and Voice Memos hold the mic open")
    func micAloneIsNotEnough() {
        let signal = snapshot(mic: true).meetingSignal(settings: Settings())
        #expect(signal == nil)
    }

    @Test("Microphone plus a running meeting app is a strong signal")
    func micPlusMeetingApp() throws {
        let signal = try #require(
            snapshot(mic: true, running: ["us.zoom.xos"]).meetingSignal(settings: Settings())
        )
        #expect(signal.confidence == .strong)
        #expect(signal.appName == "Zoom")
    }

    @Test("Microphone plus a browser covers meetings held in a tab")
    func micPlusBrowser() throws {
        let signal = try #require(
            snapshot(mic: true, browser: true).meetingSignal(settings: Settings())
        )
        #expect(signal.confidence == .strong)
    }

    @Test("Microphone and camera together are certain, whatever is running")
    func micAndCameraIsCertain() throws {
        let signal = try #require(
            snapshot(mic: true, camera: true).meetingSignal(settings: Settings())
        )
        #expect(signal.confidence == .certain)
    }

    @Test("A frontmost meeting app alone counts only when the user opted in")
    func frontmostAppIsOptIn() {
        var settings = Settings()
        let snap = snapshot(frontmost: "com.microsoft.teams2", running: ["com.microsoft.teams2"])

        #expect(snap.meetingSignal(settings: settings) == nil, "off by default")

        settings.detectViaFrontmostApp = true
        let signal = snap.meetingSignal(settings: settings)
        #expect(signal?.confidence == .weak)
        #expect(signal?.appName == "Microsoft Teams")
    }

    @Test("Detection is skipped entirely when disabled or the screen is locked")
    func detectionRespectsGuards() {
        var settings = Settings()
        settings.meetingDetectionEnabled = false
        #expect(snapshot(mic: true, camera: true).meetingSignal(settings: settings) == nil)

        var locked = snapshot(mic: true, camera: true)
        locked.screenLocked = true
        #expect(locked.meetingSignal(settings: Settings()) == nil)
    }
}

@Suite("Intervention policy")
struct InterventionPolicyTests {

    private func context(_ status: TrackingStatus, pendingDrafts: Int = 0, unfiled: TimeInterval = 0) -> InterventionContext {
        InterventionContext(
            status: status,
            continuousWorkSeconds: 0,
            unfiledSeconds: unfiled,
            unsettledSeconds: 0,
            pendingDraftCount: pendingDrafts
        )
    }

    private func running(since offset: TimeInterval = -600) -> TrackingStatus {
        .running(target: Fixture.issue("CYM-1"), since: Fixture.referenceDate.addingTimeInterval(offset))
    }

    @Test("Idle beyond the threshold raises an idle prompt")
    func idleRaisesPrompt() {
        var memory = InterventionMemory()
        var settings = Settings()
        settings.idleThresholdSeconds = 300

        let snap = ActivitySnapshot(timestamp: Fixture.referenceDate, idleSeconds: 400)
        let result = InterventionPolicy.evaluate(
            snapshot: snap, context: context(running()), settings: settings, memory: &memory
        )

        guard case .idleDetected(_, let seconds) = result else {
            Issue.record("expected an idle prompt, got \(result)")
            return
        }
        #expect(seconds == 400)
    }

    @Test("The idle prompt does not repeat within its cooldown")
    func idleCooldown() {
        var memory = InterventionMemory()
        let settings = Settings()
        let snap = ActivitySnapshot(timestamp: Fixture.referenceDate, idleSeconds: 400)

        let first = InterventionPolicy.evaluate(
            snapshot: snap, context: context(running()), settings: settings, memory: &memory
        )
        #expect(first.isNone == false)

        // Ten seconds later, still idle.
        var later = snap
        later.timestamp = Fixture.referenceDate.addingTimeInterval(10)
        later.idleSeconds = 410
        let second = InterventionPolicy.evaluate(
            snapshot: later, context: context(running()), settings: settings, memory: &memory
        )
        #expect(second.isNone, "a second prompt ten seconds later would be intolerable")
    }

    @Test("A meeting must persist past the grace period before interrupting")
    func meetingNeedsGracePeriod() {
        var memory = InterventionMemory()
        var settings = Settings()
        settings.meetingGraceSeconds = 45
        settings.idleThresholdSeconds = 100_000   // keep idle out of the way

        func snap(at offset: TimeInterval) -> ActivitySnapshot {
            ActivitySnapshot(
                timestamp: Fixture.referenceDate.addingTimeInterval(offset),
                idleSeconds: 2,
                microphoneInUse: true,
                cameraInUse: true
            )
        }

        // A two-second blip is a notification sound, not a meeting.
        #expect(InterventionPolicy.evaluate(
            snapshot: snap(at: 0), context: context(running()), settings: settings, memory: &memory
        ).isNone)
        #expect(InterventionPolicy.evaluate(
            snapshot: snap(at: 2), context: context(running()), settings: settings, memory: &memory
        ).isNone)

        // Past the grace period it earns an interruption.
        let result = InterventionPolicy.evaluate(
            snapshot: snap(at: 60), context: context(running()), settings: settings, memory: &memory
        )
        guard case .meetingDetected(_, let signal, _) = result else {
            Issue.record("expected a meeting prompt, got \(result)")
            return
        }
        #expect(signal.confidence == .certain)
    }

    @Test("A dropped meeting signal resets, so two calls are not treated as one")
    func meetingSignalResets() {
        var memory = InterventionMemory()
        var settings = Settings()
        settings.meetingGraceSeconds = 45
        settings.idleThresholdSeconds = 100_000

        let inCall = ActivitySnapshot(
            timestamp: Fixture.referenceDate, idleSeconds: 2, microphoneInUse: true, cameraInUse: true
        )
        _ = InterventionPolicy.evaluate(
            snapshot: inCall, context: context(running()), settings: settings, memory: &memory
        )
        #expect(memory.meetingSignalSince != nil)

        var quiet = inCall
        quiet.timestamp = Fixture.referenceDate.addingTimeInterval(10)
        quiet.microphoneInUse = false
        quiet.cameraInUse = false
        _ = InterventionPolicy.evaluate(
            snapshot: quiet, context: context(running()), settings: settings, memory: &memory
        )
        #expect(memory.meetingSignalSince == nil, "the continuity clock must restart")
    }

    @Test("Already tracking against the meeting bucket produces no meeting prompt")
    func noPromptWhenAlreadyOnMeetingBucket() {
        var memory = InterventionMemory()
        var settings = Settings()
        settings.meetingGraceSeconds = 1
        settings.idleThresholdSeconds = 100_000

        let status = TrackingStatus.running(
            target: Fixture.adhoc(.meeting), since: Fixture.referenceDate.addingTimeInterval(-600)
        )
        var snap = ActivitySnapshot(
            timestamp: Fixture.referenceDate, idleSeconds: 2, microphoneInUse: true, cameraInUse: true
        )
        _ = InterventionPolicy.evaluate(snapshot: snap, context: context(status), settings: settings, memory: &memory)
        snap.timestamp = Fixture.referenceDate.addingTimeInterval(120)

        let result = InterventionPolicy.evaluate(
            snapshot: snap, context: context(status), settings: settings, memory: &memory
        )
        #expect(result.isNone, "the user is already doing the right thing")
    }

    @Test("A runaway session outranks everything else")
    func runawayHasTopPriority() {
        var memory = InterventionMemory()
        var settings = Settings()
        settings.runawaySessionHours = 5

        // Idle *and* in a meeting *and* running for nine hours.
        let snap = ActivitySnapshot(
            timestamp: Fixture.referenceDate,
            idleSeconds: 9999,
            microphoneInUse: true,
            cameraInUse: true
        )
        let result = InterventionPolicy.evaluate(
            snapshot: snap,
            context: context(running(since: -9 * 3600)),
            settings: settings,
            memory: &memory
        )

        guard case .runawaySession = result else {
            Issue.record("expected the runaway warning, got \(result)")
            return
        }
    }

    @Test("Nothing fires while the screen is locked or the machine is asleep")
    func silentWhileLocked() {
        var memory = InterventionMemory()
        var snap = ActivitySnapshot(timestamp: Fixture.referenceDate, idleSeconds: 9999)
        snap.screenLocked = true

        #expect(InterventionPolicy.evaluate(
            snapshot: snap, context: context(running()), settings: Settings(), memory: &memory
        ).isNone)
    }

    @Test("Snoozing suppresses every intervention until it expires")
    func snoozeSuppressesEverything() {
        var memory = InterventionMemory()
        memory.snooze(until: Fixture.referenceDate.addingTimeInterval(600))

        let snap = ActivitySnapshot(timestamp: Fixture.referenceDate, idleSeconds: 9999)
        #expect(InterventionPolicy.evaluate(
            snapshot: snap, context: context(running(since: -9 * 3600)), settings: Settings(), memory: &memory
        ).isNone)

        // After it expires, normal service resumes.
        var later = snap
        later.timestamp = Fixture.referenceDate.addingTimeInterval(700)
        #expect(InterventionPolicy.evaluate(
            snapshot: later, context: context(running(since: -9 * 3600)), settings: Settings(), memory: &memory
        ).isNone == false)
    }

    @Test("Working with nothing tracked eventually nudges")
    func forgotToStart() {
        var memory = InterventionMemory()
        var settings = Settings()
        settings.forgotToStartAfterMinutes = 10
        // Reference date is a Tuesday 09:00, comfortably inside working hours.

        var snap = ActivitySnapshot(timestamp: Fixture.referenceDate, idleSeconds: 3)
        _ = InterventionPolicy.evaluate(snapshot: snap, context: context(.idle), settings: settings, memory: &memory)
        #expect(memory.untrackedActiveSince != nil)

        snap.timestamp = Fixture.referenceDate.addingTimeInterval(11 * 60)
        let result = InterventionPolicy.evaluate(
            snapshot: snap, context: context(.idle), settings: settings, memory: &memory
        )
        guard case .forgotToStart = result else {
            Issue.record("expected a forgot-to-start nudge, got \(result)")
            return
        }
    }

    @Test("End-of-day review fires once, and only with something to review")
    func endOfDayReview() {
        var memory = InterventionMemory()
        var settings = Settings()
        settings.endOfDayReviewHour = 18
        settings.nudgeEnabled = false

        let calendar = Calendar.current
        let evening = calendar.date(bySettingHour: 18, minute: 30, second: 0, of: Fixture.referenceDate)!
        let snap = ActivitySnapshot(timestamp: evening, idleSeconds: 5)

        // Nothing outstanding: no prompt.
        #expect(InterventionPolicy.evaluate(
            snapshot: snap, context: context(.idle), settings: settings, memory: &memory
        ).isNone)

        var withWork = InterventionMemory()
        let result = InterventionPolicy.evaluate(
            snapshot: snap,
            context: context(.idle, pendingDrafts: 2, unfiled: 1800),
            settings: settings,
            memory: &withWork
        )
        guard case .endOfDayReview(let unfiled, _, let pending) = result else {
            Issue.record("expected an end-of-day review, got \(result)")
            return
        }
        #expect(unfiled == 1800)
        #expect(pending == 2)

        // Second evaluation the same day is silent.
        #expect(InterventionPolicy.evaluate(
            snapshot: snap,
            context: context(.idle, pendingDrafts: 2, unfiled: 1800),
            settings: settings,
            memory: &withWork
        ).isNone)
    }
}
