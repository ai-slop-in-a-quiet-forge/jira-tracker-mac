import Foundation

/// One continuous stretch of time spent on one target.
///
/// The whole history is an append-only list of these. Pausing closes a segment; resuming
/// opens a new one against the same target. Nothing is ever mutated in place — trimming
/// idle time, splitting a segment across midnight and editing a note all *return new
/// segments* rather than modifying existing ones, which keeps the audit trail intact and
/// makes the engine trivially undo-able.
public struct WorkSegment: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var target: TrackingTarget
    public var start: Date
    /// `nil` means this segment is still running. Only one segment may be open at a time.
    public var end: Date?
    public var note: String?
    public var source: SegmentSource
    /// Set when an idle or away period was carved out of this segment, so the timesheet
    /// can show "trimmed" and the user can tell the difference between a short session and
    /// a long session that lost its middle.
    public var trimmedIdle: TimeInterval

    public init(
        id: UUID = UUID(),
        target: TrackingTarget,
        start: Date,
        end: Date? = nil,
        note: String? = nil,
        source: SegmentSource = .manual,
        trimmedIdle: TimeInterval = 0
    ) {
        self.id = id
        self.target = target
        self.start = start
        self.end = end
        self.note = note
        self.source = source
        self.trimmedIdle = trimmedIdle
    }

    public var isOpen: Bool { end == nil }

    /// Elapsed time. An open segment is measured against `now`, which is why callers must
    /// pass a clock reading rather than this being a plain stored property.
    public func duration(asOf now: Date) -> TimeInterval {
        max(0, (end ?? now).timeIntervalSince(start))
    }

    /// Duration of a closed segment; zero for an open one (callers that care use `duration(asOf:)`).
    public var closedDuration: TimeInterval {
        guard let end else { return 0 }
        return max(0, end.timeIntervalSince(start))
    }

    // MARK: - Immutable transforms

    public func closing(at date: Date) -> WorkSegment {
        var copy = self
        // Guard against a backwards clock (NTP correction, sleep/wake) producing negative time.
        copy.end = max(date, start)
        return copy
    }

    public func withNote(_ note: String?) -> WorkSegment {
        var copy = self
        copy.note = note?.isEmpty == true ? nil : note
        return copy
    }

    /// Cuts `interval` off the end of the segment — how idle time is discarded.
    public func trimmingTail(by interval: TimeInterval, at reference: Date) -> WorkSegment {
        let effectiveEnd = end ?? reference
        let newEnd = max(start, effectiveEnd.addingTimeInterval(-interval))
        var copy = self
        copy.end = newEnd
        copy.trimmedIdle += effectiveEnd.timeIntervalSince(newEnd)
        return copy
    }

    /// Splits at a boundary, returning the pieces. Used to keep segments inside one calendar
    /// day so daily totals and Jira worklog `started` dates stay honest when you work past
    /// midnight.
    public func split(at boundary: Date) -> [WorkSegment] {
        guard let end, boundary > start, boundary < end else { return [self] }
        var head = self
        head.end = boundary
        var tail = self
        tail.id = UUID()
        tail.start = boundary
        tail.end = end
        // Trimmed-idle bookkeeping belongs to whichever piece actually lost the time; it was
        // trimmed off the tail, so it travels with the tail.
        head.trimmedIdle = 0
        return [head, tail]
    }

    /// Breaks a segment into per-calendar-day pieces.
    public func splitAcrossDays(calendar: Calendar = .current, asOf now: Date) -> [WorkSegment] {
        let effectiveEnd = end ?? now
        guard !calendar.isDate(start, inSameDayAs: effectiveEnd) else { return [self] }

        var pieces: [WorkSegment] = []
        var cursor = self
        cursor.end = effectiveEnd
        while true {
            guard let cursorEnd = cursor.end else { break }
            let nextMidnight = calendar.startOfDay(for: cursor.start).addingTimeInterval(86_400)
            guard nextMidnight < cursorEnd else {
                pieces.append(cursor)
                break
            }
            let parts = cursor.split(at: nextMidnight)
            guard parts.count == 2 else { pieces.append(cursor); break }
            pieces.append(parts[0])
            cursor = parts[1]
        }
        return pieces
    }
}

/// Where a segment came from. Surfaced in the timesheet so the user can audit anything the
/// app decided on their behalf — automatic switches especially.
public enum SegmentSource: String, Codable, Sendable, CaseIterable {
    /// The user started it from the menu bar.
    case manual
    /// Started by the phone remote (BLE or the LAN web remote).
    case remote
    /// The app auto-switched, e.g. a meeting was detected and the user accepted the switch.
    case automatic
    /// Recovered after a crash or forced quit from the persisted open segment.
    case recovered
    /// Typed in by hand after the fact.
    case backfilled
    /// Pulled down from an existing Jira worklog during reconciliation.
    case imported

    public var isUserOriginated: Bool { self == .manual || self == .remote || self == .backfilled }
}
