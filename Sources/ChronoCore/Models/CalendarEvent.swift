import CryptoKit
import Foundation

/// A calendar event, reduced to the little Chrono needs.
///
/// Exactly four things are carried: when it runs, what it is called, and which calendar it came
/// from. No attendees, no notes, no location, no organiser, no identifiers that could be
/// correlated with anything. The constraint in #14 was "only title and time", and the way to keep
/// that promise is for the richer type never to cross into ChronoCore at all — the EventKit
/// object is reduced at the boundary and the rest of the app cannot see what was dropped.
public struct CalendarEvent: Sendable, Equatable, Identifiable, Hashable {
    /// Stable across refreshes so a backfill offer does not duplicate.
    public let id: String
    public let title: String
    public let start: Date
    public let end: Date
    /// The calendar's own name ("Work", "Personal"), shown so it is obvious where a title came
    /// from — and, with a Google account, that Chrono is reading it.
    public let calendarTitle: String
    /// The account the calendar belongs to (iCloud, a Google address, Exchange).
    public let accountName: String
    public let isAllDay: Bool

    public init(
        id: String,
        title: String,
        start: Date,
        end: Date,
        calendarTitle: String,
        accountName: String,
        isAllDay: Bool = false
    ) {
        self.id = id
        self.title = title
        self.start = start
        self.end = end
        self.calendarTitle = calendarTitle
        self.accountName = accountName
        self.isAllDay = isAllDay
    }

    public var duration: TimeInterval { max(0, end.timeIntervalSince(start)) }

    public func covers(_ instant: Date) -> Bool {
        instant >= start && instant < end
    }

    public func overlaps(start otherStart: Date, end otherEnd: Date) -> Bool {
        start < otherEnd && otherStart < end
    }
}

public enum CalendarMatching {

    /// The event that best describes what someone is in at `instant`.
    ///
    /// All-day events are excluded outright: "Alice on leave" or "Q3 planning week" describe a
    /// day, not a meeting, and labelling an hour of work with one would be worse than leaving it
    /// unlabelled.
    ///
    /// When real meetings overlap — a double-booking, or a long block with a short call inside it
    /// — the **shortest** wins. The specific thing is nearly always the one you are actually in,
    /// and a two-hour "Focus time" block should not swallow the fifteen-minute standup sitting
    /// inside it. Ties break on the later start, then on title, so the answer is stable rather
    /// than dependent on the order EventKit happened to return.
    public static func event(covering instant: Date, in events: [CalendarEvent]) -> CalendarEvent? {
        events
            .filter { !$0.isAllDay && $0.covers(instant) }
            .min { left, right in
                if left.duration != right.duration { return left.duration < right.duration }
                if left.start != right.start { return left.start > right.start }
                return left.title < right.title
            }
    }

    /// Events with no tracked time against them, for offering a backfill.
    ///
    /// "Untracked" is judged by *coverage*, not by exact match: a meeting is not forgotten
    /// because the tracked segment started two minutes late. An event counts as tracked once
    /// `minimumCoverage` of it overlaps something already recorded, which defaults to half —
    /// enough that joining late or leaving early still counts, while a meeting you dipped into
    /// for a moment and then abandoned is still offered.
    ///
    /// All-day events are never offered: nobody wants "Bank holiday" backfilled as eight hours.
    public static func untrackedEvents(
        _ events: [CalendarEvent],
        trackedRanges: [(start: Date, end: Date)],
        minimumCoverage: Double = 0.5
    ) -> [CalendarEvent] {
        events
            .filter { event in
                guard !event.isAllDay, event.duration > 0 else { return false }
                let covered = trackedRanges.reduce(0.0) { total, range in
                    let overlapStart = max(event.start, range.start)
                    let overlapEnd = min(event.end, range.end)
                    return total + max(0, overlapEnd.timeIntervalSince(overlapStart))
                }
                return covered / event.duration < minimumCoverage
            }
            .sorted { $0.start < $1.start }
    }
}

public extension AdhocRef {

    /// An ad-hoc target named after a calendar event.
    ///
    /// The id is **derived from the event's identifier** rather than freshly generated, because
    /// `TrackingTarget.id` is `adhoc:<uuid>` and the rollup groups by it. A random id would make
    /// every rejoin of the same meeting a separate row — leave the standup, come back, and the
    /// timesheet would show "Standup" twice with the time split between them.
    static func forCalendarEvent(_ event: CalendarEvent, category: AdhocCategory = .meeting) -> AdhocRef {
        AdhocRef(id: Self.stableID(for: event.id), label: event.title, category: category)
    }

    /// A UUID that is always the same for the same event identifier.
    ///
    /// Hashed rather than parsed: EventKit identifiers are not UUIDs, and for a recurring meeting
    /// they carry an occurrence suffix, so this keeps whatever distinction EventKit itself makes
    /// between occurrences.
    static func stableID(for eventIdentifier: String) -> UUID {
        var bytes = Array(SHA256.hash(data: Data(eventIdentifier.utf8)).prefix(16))
        // Stamp version 5 and the RFC 4122 variant, so this is a well-formed name-based UUID
        // rather than 16 arbitrary bytes wearing a UUID's clothes.
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}
