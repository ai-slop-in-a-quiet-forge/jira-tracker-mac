import Foundation

/// An injectable source of "now".
///
/// Every piece of time arithmetic in ChronoCore goes through a `Clock` rather than
/// calling `Date()` directly. That is what makes the tracking engine testable: a test
/// can advance time by four hours instantly and assert on the resulting segments.
public protocol Clock: Sendable {
    var now: Date { get }
}

public struct SystemClock: Clock {
    public init() {}
    public var now: Date { Date() }
}

/// A clock a test drives by hand.
public final class MutableClock: Clock, @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    public init(_ start: Date = Date(timeIntervalSince1970: 1_700_000_000)) {
        current = start
    }

    public var now: Date {
        lock.lock(); defer { lock.unlock() }
        return current
    }

    public func advance(by interval: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        current = current.addingTimeInterval(interval)
    }

    public func set(_ date: Date) {
        lock.lock(); defer { lock.unlock() }
        current = date
    }
}
