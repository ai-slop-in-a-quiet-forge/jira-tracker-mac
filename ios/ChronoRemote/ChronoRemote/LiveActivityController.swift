import ActivityKit
import Foundation

/// Drives the Lock Screen and Dynamic Island presentation from the snapshots arriving over
/// Bluetooth.
///
/// ## The update budget is the whole design
///
/// ActivityKit rate-limits updates and starts dropping them if an app is greedy. A running timer
/// changes every second, so pushing every snapshot through would guarantee getting throttled —
/// and a throttled Live Activity is worse than none, because it freezes at a stale time while
/// looking authoritative.
///
/// Instead the timer ticks on-device from a date anchor (see `ChronoActivityAttributes`), and
/// this type updates the activity only when something changes that a clock cannot derive: the
/// status, the task, the meeting banner, the target. `isMeaningfullyDifferent` is where that
/// judgement lives.
///
/// Re-anchoring is the subtle case. If the app has been asleep and the Mac's elapsed count has
/// drifted from what the widget would be showing, the anchor is wrong and the Lock Screen is
/// quietly lying. So a drift beyond `driftTolerance` also counts as a change worth spending an
/// update on.
@MainActor
final class LiveActivityController {

    /// How far the locally-ticked count may drift from the Mac's before it is worth an update.
    /// Two seconds is below the threshold where anyone would notice, and comfortably above the
    /// jitter of a BLE notification arriving late.
    private static let driftTolerance = 2

    private var activity: Activity<ChronoActivityAttributes>?
    private var lastState: ChronoActivityAttributes.ContentState?

    var isRunning: Bool { activity != nil }

    /// Feed every snapshot in; this decides whether anything reaches ActivityKit.
    func apply(snapshot: RemoteSnapshot?, macName: String, connected: Bool) {
        guard let snapshot else { return }

        // An idle timer has nothing to show. Ending rather than leaving a zeroed activity on the
        // Lock Screen matters: a stopped timer that still looks present is actively misleading.
        guard snapshot.status != .idle else {
            end()
            return
        }

        let state = makeState(from: snapshot)

        guard let activity else {
            start(state: state, macName: macName, connected: connected)
            return
        }

        guard isMeaningfullyDifferent(lastState, state) || connected != (lastStaleDate == nil) else {
            return
        }
        lastState = state
        let content = ActivityContent(state: state, staleDate: staleDate(connected: connected))
        lastStaleDate = staleDate(connected: connected)
        Task { await activity.update(content) }
    }

    /// Ends the activity. Called when the timer stops, the phone is unpaired, or the app decides
    /// it can no longer vouch for what it is showing.
    func end() {
        guard let activity else { return }
        self.activity = nil
        lastState = nil
        lastStaleDate = nil
        Task { await activity.end(nil, dismissalPolicy: .immediate) }
    }

    // MARK: - Internals

    private var lastStaleDate: Date?

    private func start(state: ChronoActivityAttributes.ContentState, macName: String, connected: Bool) {
        // Requesting an activity throws if the user has switched them off for this app, or if
        // the app is not in the foreground. Neither is an error worth surfacing — the remote
        // works exactly as before without a Lock Screen presence.
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }

        let stale = staleDate(connected: connected)
        do {
            activity = try Activity.request(
                attributes: ChronoActivityAttributes(macName: macName),
                content: ActivityContent(state: state, staleDate: stale),
                pushType: nil
            )
            lastState = state
            lastStaleDate = stale
        } catch {
            activity = nil
        }
    }

    private func makeState(from snapshot: RemoteSnapshot) -> ChronoActivityAttributes.ContentState {
        let now = Date()
        let running = snapshot.status == .running
        return ChronoActivityAttributes.ContentState(
            // Anchor in the past by exactly the elapsed the Mac reported, so counting up from it
            // reproduces that number now and keeps going without further updates.
            runningSince: running ? now.addingTimeInterval(-Double(snapshot.elapsed)) : nil,
            todayCountingSince: running ? now.addingTimeInterval(-Double(snapshot.todaySeconds)) : nil,
            elapsed: snapshot.elapsed,
            todaySeconds: snapshot.todaySeconds,
            targetSeconds: snapshot.targetSeconds,
            label: snapshot.label,
            status: snapshot.status,
            inMeeting: snapshot.inMeeting
        )
    }

    /// While connected the content is trustworthy indefinitely, because the Mac pushes a
    /// notification whenever anything changes. While disconnected it is only a guess, so it is
    /// marked stale shortly after — the Lock Screen then dims it rather than presenting a
    /// possibly-paused timer as definitely running.
    private func staleDate(connected: Bool) -> Date? {
        connected ? nil : Date().addingTimeInterval(120)
    }

    private func isMeaningfullyDifferent(
        _ old: ChronoActivityAttributes.ContentState?,
        _ new: ChronoActivityAttributes.ContentState
    ) -> Bool {
        guard let old else { return true }

        if old.status != new.status { return true }
        if old.label != new.label { return true }
        if old.inMeeting != new.inMeeting { return true }
        if old.targetSeconds != new.targetSeconds { return true }

        // Everything below is derivable from a clock, so it is only worth an update when the
        // clock has drifted from the truth.
        if drifted(anchor: old.runningSince, against: new.elapsed) { return true }
        if drifted(anchor: old.todayCountingSince, against: new.todaySeconds) { return true }

        return false
    }

    /// Whether counting up from `anchor` would now show something meaningfully different from
    /// the seconds the Mac just reported.
    private func drifted(anchor: Date?, against reported: Int) -> Bool {
        guard let anchor else { return false }
        let predicted = Int(Date().timeIntervalSince(anchor).rounded())
        return abs(predicted - reported) > Self.driftTolerance
    }
}
