import Foundation

/// The window a segment's times may be moved within, set by its neighbours.
///
/// Given to the UI so the pickers can be bounded rather than letting someone choose a time that
/// is then refused — being told "no" after committing to a value is a worse experience than not
/// being offered it.
public struct SegmentBounds: Equatable, Sendable {
    /// The end of the preceding entry. Nil when this is the first of the day.
    public let earliestStart: Date?
    /// The start of the following entry, or of the running timer. Nil when nothing follows.
    public let latestEnd: Date?

    public init(earliestStart: Date?, latestEnd: Date?) {
        self.earliestStart = earliestStart
        self.latestEnd = latestEnd
    }

    public func allows(start: Date, end: Date) -> Bool {
        if end <= start { return false }
        if let earliestStart, start < earliestStart { return false }
        if let latestEnd, end > latestEnd { return false }
        return true
    }
}

/// Why an edit to a segment's times was refused.
///
/// Each case carries the boundary it hit, so the UI can say *what* the limit is rather than only
/// that one was exceeded. "Cannot start before 14:30" is actionable; "invalid time" is not.
public enum SegmentEditRejection: Equatable, Sendable {
    case notFound
    /// A zero-length or backwards entry. `updateSegment` would silently clamp this; an explicit
    /// edit should say so instead.
    case endNotAfterStart
    /// Would reach back into the previous entry.
    case overlapsPrevious(earliestAllowedStart: Date)
    /// Would reach forward into the next entry, or into the running timer.
    case overlapsNext(latestAllowedEnd: Date)
    /// The running segment's times are owned by the clock, not by an edit form. Stopping or
    /// backdating are the operations that apply to it.
    case segmentIsOpen
}

public enum SegmentEditOutcome: Equatable, Sendable {
    case applied
    case rejected(SegmentEditRejection)

    public var didApply: Bool { self == .applied }
}
