import ActivityKit
import Foundation

/// What the Lock Screen and Dynamic Island show, and the contract between the app and the
/// widget extension. Compiled into both targets, for the same reason `RemoteProtocol.swift` is
/// compiled into both the Mac and iOS apps: one definition on disk cannot drift from itself.
///
/// ## Why this stores dates rather than the seconds the Mac sent
///
/// `RemoteSnapshot.elapsed` is an integer count of seconds, correct at the instant the Mac sent
/// it. Rendering that directly would need an update per second, and ActivityKit budgets updates
/// — a Live Activity that asks for one every second gets throttled and then ignored, so the
/// timer would visibly stall.
///
/// So the app converts each snapshot into an *anchor*: the instant the count started, which is
/// `now - elapsed`. SwiftUI's `Text(timerInterval:)` and `ProgressView(timerInterval:)` then
/// advance on their own, on-device, with no further updates at all. The activity is updated only
/// when something actually changes — a pause, a resume, a different task, a meeting starting.
///
/// The anchors are optional rather than always-present because a paused timer must *not* tick.
/// When `runningSince` is nil the views fall back to the static `elapsed`, which is exactly the
/// frozen value a paused timer should show.
struct ChronoActivityAttributes: ActivityAttributes {

    struct ContentState: Codable, Hashable {
        /// Non-nil only while running: the instant to count up from. `now - elapsed` at the
        /// moment the snapshot arrived.
        let runningSince: Date?
        /// Non-nil only while running: the instant today's total should count up from, so the
        /// daily progress advances without updates too.
        let todayCountingSince: Date?

        /// Seconds on the current segment, authoritative when not running.
        let elapsed: Int
        /// Seconds logged today, authoritative when not running.
        let todaySeconds: Int
        /// The daily target, for the progress ring. Zero means "no target set" and the ring
        /// is hidden rather than drawn full or empty, either of which would be a lie.
        let targetSeconds: Int

        /// The issue key or bucket name. Already capped at 40 characters upstream.
        let label: String
        let status: RemoteStatus
        /// The Mac believes you are on a call while this is still tracking — the whole reason
        /// to glance at the Lock Screen.
        let inMeeting: Bool

        /// True when there is a live count to render rather than a frozen number.
        var isTicking: Bool { status == .running && runningSince != nil }

        /// The range a counting-up `Text(timerInterval:)` needs. The upper bound only has to be
        /// far enough away not to be reached; a day is comfortably beyond any real segment and
        /// avoids `distantFuture`, which some formatters render oddly.
        func countUpRange(from anchor: Date) -> ClosedRange<Date> {
            anchor...anchor.addingTimeInterval(24 * 3600)
        }

        /// The range for the daily progress ring: from when today's total started counting to
        /// when it would reach the target. `ProgressView(timerInterval:)` fills it as time
        /// passes, so the ring advances with no updates.
        var targetRange: ClosedRange<Date>? {
            guard targetSeconds > 0, let start = todayCountingSince else { return nil }
            return start...start.addingTimeInterval(TimeInterval(targetSeconds))
        }

        /// Fraction of the daily target reached, for the frozen (not running) case.
        var staticProgress: Double {
            guard targetSeconds > 0 else { return 0 }
            return min(1, Double(todaySeconds) / Double(targetSeconds))
        }
    }

    /// Shown so a glance tells you *which* Mac is being tracked, which matters as soon as
    /// someone has two.
    let macName: String
}

/// Formats a duration the way the app already does elsewhere: `1:23:45`, or `12:34` under an
/// hour. Lives here rather than in a view so the app and both widget presentations agree.
func chronoClock(_ seconds: Int) -> String {
    let total = max(0, seconds)
    let hours = total / 3600
    let minutes = (total % 3600) / 60
    let secs = total % 60
    if hours > 0 {
        return String(format: "%d:%02d:%02d", hours, minutes, secs)
    }
    return String(format: "%d:%02d", minutes, secs)
}
