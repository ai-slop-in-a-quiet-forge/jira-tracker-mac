import Foundation

/// Read-only aggregations over segments, used by the panel header, the timesheet and the
/// phone remote. All pure functions of the segment list, so nothing here can drift out of
/// sync with the underlying history.
public struct DayRollup: Sendable, Equatable {
    public let day: Date
    public let totals: [TargetTotal]
    /// Time on real work — excludes break buckets.
    public let workSeconds: TimeInterval
    public let breakSeconds: TimeInterval
    /// Work that cannot be pushed to Jira yet because it has no issue.
    public let unloggableSeconds: TimeInterval
    public let firstActivity: Date?
    public let lastActivity: Date?
    public let segmentCount: Int
    /// Number of distinct targets touched — a decent proxy for how fragmented the day was.
    public let contextSwitches: Int

    public var totalSeconds: TimeInterval { workSeconds + breakSeconds }

    public func progress(towardHours target: Double) -> Double {
        guard target > 0 else { return 0 }
        return min(1, workSeconds / (target * 3600))
    }

    /// The elapsed wall-clock span from first to last activity, which is usually much larger
    /// than the tracked total — the gap between them is the day's untracked time.
    public var spanSeconds: TimeInterval {
        guard let first = firstActivity, let last = lastActivity else { return 0 }
        return max(0, last.timeIntervalSince(first))
    }

    public var untrackedWithinSpanSeconds: TimeInterval {
        max(0, spanSeconds - totalSeconds)
    }

    public static func build(
        segments: [WorkSegment],
        day: Date,
        calendar: Calendar = .current,
        asOf now: Date
    ) -> DayRollup {
        let dayStart = calendar.startOfDay(for: day)
        // Split across midnight first, so a session that ran from 23:40 to 00:20 contributes
        // to both days correctly rather than landing entirely in one.
        let pieces = segments
            .flatMap { $0.splitAcrossDays(calendar: calendar, asOf: now) }
            .filter { calendar.isDate($0.start, inSameDayAs: dayStart) }

        var byTarget: [String: TargetTotal] = [:]
        var work: TimeInterval = 0
        var breaks: TimeInterval = 0
        var unloggable: TimeInterval = 0
        var first: Date?
        var last: Date?

        for piece in pieces {
            let duration = piece.duration(asOf: now)
            guard duration > 0 else { continue }
            let end = piece.end ?? now

            first = first.map { min($0, piece.start) } ?? piece.start
            last = last.map { max($0, end) } ?? end

            let isBreak = piece.target.adhoc?.category.countsAsWork == false
            if isBreak { breaks += duration } else { work += duration }
            if !isBreak && !piece.target.isLoggable { unloggable += duration }

            let key = piece.target.id
            if var existing = byTarget[key] {
                existing.seconds += duration
                existing.segmentCount += 1
                existing.firstStart = min(existing.firstStart, piece.start)
                existing.lastEnd = max(existing.lastEnd, end)
                existing.isRunning = existing.isRunning || piece.isOpen
                byTarget[key] = existing
            } else {
                byTarget[key] = TargetTotal(
                    target: piece.target,
                    seconds: duration,
                    segmentCount: 1,
                    firstStart: piece.start,
                    lastEnd: end,
                    isRunning: piece.isOpen
                )
            }
        }

        let sorted = byTarget.values.sorted { lhs, rhs in
            // Running first, then by time spent — the ordering the user wants to see.
            if lhs.isRunning != rhs.isRunning { return lhs.isRunning }
            if lhs.seconds != rhs.seconds { return lhs.seconds > rhs.seconds }
            return lhs.target.displayLabel < rhs.target.displayLabel
        }

        return DayRollup(
            day: dayStart,
            totals: sorted,
            workSeconds: work,
            breakSeconds: breaks,
            unloggableSeconds: unloggable,
            firstActivity: first,
            lastActivity: last,
            segmentCount: pieces.count,
            contextSwitches: max(0, countSwitches(in: pieces))
        )
    }

    /// Counts how many times the target actually changed, in chronological order. Repeated
    /// segments on the same target (pause/resume) are not a context switch.
    private static func countSwitches(in pieces: [WorkSegment]) -> Int {
        var switches = 0
        var previous: String?
        for piece in pieces.sorted(by: { $0.start < $1.start }) {
            if let previous, previous != piece.target.id { switches += 1 }
            previous = piece.target.id
        }
        return switches
    }

    public static func empty(day: Date, calendar: Calendar = .current) -> DayRollup {
        DayRollup(
            day: calendar.startOfDay(for: day),
            totals: [],
            workSeconds: 0,
            breakSeconds: 0,
            unloggableSeconds: 0,
            firstActivity: nil,
            lastActivity: nil,
            segmentCount: 0,
            contextSwitches: 0
        )
    }
}

public struct TargetTotal: Sendable, Equatable, Identifiable {
    public var target: TrackingTarget
    public var seconds: TimeInterval
    public var segmentCount: Int
    public var firstStart: Date
    public var lastEnd: Date
    public var isRunning: Bool

    public var id: String { target.id }
}

/// A week's worth of daily rollups, for the timesheet's week view.
public struct WeekRollup: Sendable, Equatable {
    public let days: [DayRollup]
    public let weekStart: Date

    public var workSeconds: TimeInterval { days.reduce(0) { $0 + $1.workSeconds } }
    public var loggableSeconds: TimeInterval {
        days.reduce(0) { $0 + ($1.workSeconds - $1.unloggableSeconds) }
    }
    public var unloggableSeconds: TimeInterval { days.reduce(0) { $0 + $1.unloggableSeconds } }

    public static func build(
        segments: [WorkSegment],
        weekContaining date: Date,
        calendar: Calendar = .current,
        asOf now: Date
    ) -> WeekRollup {
        let start = calendar.dateInterval(of: .weekOfYear, for: date)?.start
            ?? calendar.startOfDay(for: date)
        let days = (0..<7).compactMap { offset -> DayRollup? in
            guard let day = calendar.date(byAdding: .day, value: offset, to: start) else { return nil }
            return DayRollup.build(segments: segments, day: day, calendar: calendar, asOf: now)
        }
        return WeekRollup(days: days, weekStart: start)
    }
}
