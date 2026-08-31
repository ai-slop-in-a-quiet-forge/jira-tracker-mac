import Foundation

/// Decides when to interrupt the user, and about what.
///
/// This is the piece that makes the app either genuinely useful or immediately muted, so the
/// rules are all in one pure function with explicit cooldowns rather than scattered across
/// timers in the UI layer. Exactly one intervention is returned per evaluation, in strict
/// priority order — the app never stacks three notifications on top of each other.
public enum InterventionPolicy {

    /// Evaluated every few seconds by the app.
    ///
    /// `memory` carries the debounce bookkeeping and is updated in place, which keeps the
    /// decision itself a pure function of (snapshot, context, settings, memory).
    public static func evaluate(
        snapshot: ActivitySnapshot,
        context: InterventionContext,
        settings: Settings,
        memory: inout InterventionMemory,
        calendar: Calendar = .current
    ) -> Intervention {
        let now = snapshot.timestamp

        // Keep the running signal timers up to date regardless of whether we act on them.
        updateSignalTimers(snapshot: snapshot, context: context, settings: settings, memory: &memory)

        // A snooze suppresses everything. So does a system Focus mode, on the principle that
        // an app which nags through Do Not Disturb deserves to be deleted.
        if let until = memory.suppressedUntil, now < until { return .none }
        if snapshot.focusModeActive && settings.meetingDetectionEnabled == false { return .none }

        // While the machine is locked or asleep the app auto-pauses directly; prompting into
        // a locked screen just produces a pile of stale notifications.
        if snapshot.screenLocked || snapshot.systemAsleep { return .none }

        // 1. A runaway timer is the most expensive mistake, so it outranks everything.
        if case .running(let target, let since) = context.status {
            let elapsed = now.timeIntervalSince(since)
            let limit = max(1, settings.runawaySessionHours) * 3600
            if elapsed >= limit, allow(memory.lastRunawayPromptAt, now, cooldown: 3600) {
                memory.lastRunawayPromptAt = now
                return .runawaySession(target: target, elapsed: elapsed)
            }
        }

        // 2. Idle: you walked away while the clock ran.
        if case .running(let target, _) = context.status,
           settings.autoPauseOnIdle || settings.idleDefaultAction != .keep {
            let threshold = TimeInterval(max(60, settings.idleThresholdSeconds))
            if snapshot.idleSeconds >= threshold, allow(memory.lastIdlePromptAt, now, cooldown: 120) {
                memory.lastIdlePromptAt = now
                return .idleDetected(target: target, seconds: snapshot.idleSeconds)
            }
        }

        // 3. Meeting: the timer is running but you are clearly on a call.
        if case .running(let target, _) = context.status,
           let signal = snapshot.meetingSignal(settings: settings),
           let since = memory.meetingSignalSince {
            let duration = now.timeIntervalSince(since)
            let grace = TimeInterval(max(5, settings.meetingGraceSeconds))
            // A weak signal has to persist much longer before it earns an interruption.
            let required = signal.confidence == .weak ? grace * 3 : grace
            let alreadyOnMeetingBucket = target.adhoc?.category == .meeting
                || target.adhoc?.category == .call
                || (!settings.meetingIssueKey.isEmpty && target.issueKey == settings.meetingIssueKey)

            if duration >= required,
               !alreadyOnMeetingBucket,
               allow(memory.lastMeetingPromptAt, now, cooldown: 15 * 60) {
                memory.lastMeetingPromptAt = now
                return .meetingDetected(target: target, signal: signal, seconds: duration)
            }
        }

        // 4. Working, but tracking nothing.
        if context.status.isIdle,
           settings.forgotToStartNudgeEnabled,
           let activeSince = memory.untrackedActiveSince {
            let activeFor = now.timeIntervalSince(activeSince)
            let threshold = TimeInterval(max(1, settings.forgotToStartAfterMinutes)) * 60
            if activeFor >= threshold,
               isWithinWorkingHours(now, settings: settings, calendar: calendar),
               allow(memory.lastForgotPromptAt, now, cooldown: threshold) {
                memory.lastForgotPromptAt = now
                return .forgotToStart(activeSeconds: activeFor)
            }
        }

        // 5. Paused and forgotten.
        if case .paused(let target, let pausedAt) = context.status, let pausedAt {
            let pausedFor = now.timeIntervalSince(pausedAt)
            let threshold = TimeInterval(max(5, settings.abandonPausedAfterMinutes)) * 60
            if pausedFor >= threshold,
               snapshot.isUserActive,
               allow(memory.lastPausedReminderAt, now, cooldown: threshold) {
                memory.lastPausedReminderAt = now
                return .pausedTooLong(target: target, seconds: pausedFor)
            }
        }

        // 6. Periodic "still on this?" check-in.
        if case .running(let target, let since) = context.status, settings.nudgeEnabled {
            let interval = TimeInterval(max(5, settings.nudgeIntervalMinutes)) * 60
            let reference = memory.lastNudgeAt ?? since
            if now.timeIntervalSince(reference) >= interval, snapshot.isUserActive {
                memory.lastNudgeAt = now
                return .stillTracking(target: target, elapsed: now.timeIntervalSince(since))
            }
        }

        // 7. Health nag, off by default.
        if settings.breakReminderEnabled, context.status.isRunning {
            let interval = TimeInterval(max(15, settings.breakReminderAfterMinutes)) * 60
            if context.continuousWorkSeconds >= interval,
               allow(memory.lastBreakPromptAt, now, cooldown: interval) {
                memory.lastBreakPromptAt = now
                return .takeABreak(continuousSeconds: context.continuousWorkSeconds)
            }
        }

        // 8. End-of-day settle-up: only once per day, and only if there is something to do.
        if settings.endOfDayReviewEnabled,
           calendar.component(.hour, from: now) >= settings.endOfDayReviewHour,
           isWorkday(now, settings: settings, calendar: calendar),
           !calendar.isDate(memory.lastEndOfDayReviewOn ?? .distantPast, inSameDayAs: now),
           context.unfiledSeconds > 0 || context.unsettledSeconds > 0 || context.pendingDraftCount > 0 {
            memory.lastEndOfDayReviewOn = now
            return .endOfDayReview(
                unfiledSeconds: context.unfiledSeconds,
                unsettledSeconds: context.unsettledSeconds,
                pendingDrafts: context.pendingDraftCount
            )
        }

        return .none
    }

    // MARK: - Signal timers

    /// Maintains "how long has this been true for" clocks in `memory`.
    private static func updateSignalTimers(
        snapshot: ActivitySnapshot,
        context: InterventionContext,
        settings: Settings,
        memory: inout InterventionMemory
    ) {
        let now = snapshot.timestamp

        // Meeting signal continuity: reset the moment the signal drops, so a 20-second gap
        // between two calls is not treated as one long meeting.
        if snapshot.meetingSignal(settings: settings) != nil {
            if memory.meetingSignalSince == nil { memory.meetingSignalSince = now }
        } else {
            memory.meetingSignalSince = nil
            // Let the next genuine meeting prompt immediately rather than waiting out the
            // cooldown from the previous one.
            memory.lastMeetingPromptAt = nil
        }

        // "Active but not tracking" continuity.
        if context.status.isIdle && snapshot.isUserActive {
            if memory.untrackedActiveSince == nil { memory.untrackedActiveSince = now }
        } else if !context.status.isIdle || !snapshot.isUserActive {
            // Only reset on a real absence, not on a momentary pause in typing.
            if !context.status.isIdle || snapshot.idleSeconds > 300 {
                memory.untrackedActiveSince = nil
            }
        }

        if snapshot.idleSeconds < 30 { memory.lastKnownActiveAt = now }
    }

    private static func allow(_ last: Date?, _ now: Date, cooldown: TimeInterval) -> Bool {
        guard let last else { return true }
        return now.timeIntervalSince(last) >= cooldown
    }

    static func isWorkday(_ date: Date, settings: Settings, calendar: Calendar) -> Bool {
        settings.workdays.isEmpty || settings.workdays.contains(calendar.component(.weekday, from: date))
    }

    /// Rough working-hours guard so the "you forgot to start a timer" nudge does not fire at
    /// 11pm on a Sunday.
    static func isWithinWorkingHours(_ date: Date, settings: Settings, calendar: Calendar) -> Bool {
        guard isWorkday(date, settings: settings, calendar: calendar) else { return false }
        let hour = calendar.component(.hour, from: date)
        return hour >= 6 && hour < 23
    }
}

/// The parts of engine state the policy needs, passed explicitly so the policy has no
/// reference to the engine.
public struct InterventionContext: Sendable, Equatable {
    public var status: TrackingStatus
    /// Uninterrupted running time, for the break reminder.
    public var continuousWorkSeconds: TimeInterval
    public var unfiledSeconds: TimeInterval
    public var unsettledSeconds: TimeInterval
    public var pendingDraftCount: Int

    public init(
        status: TrackingStatus,
        continuousWorkSeconds: TimeInterval = 0,
        unfiledSeconds: TimeInterval = 0,
        unsettledSeconds: TimeInterval = 0,
        pendingDraftCount: Int = 0
    ) {
        self.status = status
        self.continuousWorkSeconds = continuousWorkSeconds
        self.unfiledSeconds = unfiledSeconds
        self.unsettledSeconds = unsettledSeconds
        self.pendingDraftCount = pendingDraftCount
    }
}

/// Debounce and continuity bookkeeping. Persisted so cooldowns survive a relaunch.
public struct InterventionMemory: Codable, Sendable, Equatable {
    public var lastIdlePromptAt: Date?
    public var lastMeetingPromptAt: Date?
    public var lastNudgeAt: Date?
    public var lastForgotPromptAt: Date?
    public var lastBreakPromptAt: Date?
    public var lastPausedReminderAt: Date?
    public var lastRunawayPromptAt: Date?
    public var lastEndOfDayReviewOn: Date?
    /// Set by "snooze reminders" — nothing fires before this instant.
    public var suppressedUntil: Date?

    // Continuity clocks, maintained by the policy.
    public var meetingSignalSince: Date?
    public var untrackedActiveSince: Date?
    public var lastKnownActiveAt: Date?

    public init() {}

    /// Silences all interventions for a while.
    public mutating func snooze(until date: Date) {
        suppressedUntil = date
    }
}

/// The one thing the app should do about the user's situation right now.
public enum Intervention: Sendable, Equatable {
    case none
    /// The clock is running but nobody is home.
    case idleDetected(target: TrackingTarget, seconds: TimeInterval)
    /// The clock is running on real work while you are on a call.
    case meetingDetected(target: TrackingTarget, signal: MeetingSignal, seconds: TimeInterval)
    /// You are clearly working and nothing is being tracked.
    case forgotToStart(activeSeconds: TimeInterval)
    /// Periodic confirmation.
    case stillTracking(target: TrackingTarget, elapsed: TimeInterval)
    /// A single session has run implausibly long.
    case runawaySession(target: TrackingTarget, elapsed: TimeInterval)
    case pausedTooLong(target: TrackingTarget, seconds: TimeInterval)
    case takeABreak(continuousSeconds: TimeInterval)
    case endOfDayReview(unfiledSeconds: TimeInterval, unsettledSeconds: TimeInterval, pendingDrafts: Int)

    public var isNone: Bool { self == .none }

    /// Interventions that demand a decision, as opposed to ones that are just information.
    public var requiresResponse: Bool {
        switch self {
        case .idleDetected, .meetingDetected, .runawaySession, .endOfDayReview: return true
        case .none, .forgotToStart, .stillTracking, .pausedTooLong, .takeABreak: return false
        }
    }
}
