import Foundation

/// Turns tracked segments into Jira worklog drafts.
///
/// Entirely pure, and the trickiest logic in the app, so worth stating the rules explicitly:
///
/// * One draft per **issue per calendar day**. Jira worklogs carry a single `started`
///   timestamp, and a timesheet reviewer expects "3h 20m on Tuesday", not eleven fragments
///   reflecting every time you tabbed away.
/// * Segments already covered by a draft are never drafted again, which is what makes
///   stopping a timer twice, or re-running a build after a crash, harmless.
/// * Rounding is applied to the **daily total**, not to each segment, so twelve 90-second
///   fragments do not round up into twelve separate minutes of invented time.
/// * A total below the minimum is not logged *and not consumed* — the segments stay
///   un-drafted and roll into the next draft for that issue and day.
public enum WorklogBuilder {

    /// Rounds a duration to a multiple of `minutes`.
    /// `minutes <= 0` means "don't round" and the exact seconds are kept.
    public static func round(seconds: TimeInterval, minutes: Int, mode: RoundingMode) -> Int {
        let exact = max(0, seconds)
        guard minutes > 0 else { return Int(exact.rounded()) }
        let step = Double(minutes * 60)
        let quotient = exact / step
        let steps: Double
        switch mode {
        case .nearest: steps = quotient.rounded()
        case .up: steps = quotient.rounded(.up)
        case .down: steps = quotient.rounded(.down)
        }
        return Int(steps * step)
    }

    /// Builds drafts for every issue/day pairing present in `segments` that is not already
    /// covered.
    ///
    /// - Parameters:
    ///   - segments: closed segments to consider. Open segments are ignored — a running timer
    ///     has not finished producing time yet.
    ///   - coveredSegmentIDs: ids already claimed by an existing draft.
    ///   - restrictedTo: when non-nil, only this target is drafted (used when stopping a
    ///     single timer rather than settling the whole day).
    public static func buildDrafts(
        from segments: [WorkSegment],
        settings: Settings,
        coveredSegmentIDs: Set<UUID>,
        restrictedTo target: TrackingTarget? = nil,
        calendar: Calendar = .current,
        now: Date
    ) -> [WorklogDraft] {
        // Only closed, loggable, uncovered segments are candidates. Ad-hoc time has no issue
        // to log against, so it is left for the user to reconcile later.
        let candidates = segments
            .filter { $0.end != nil }
            .filter { !coveredSegmentIDs.contains($0.id) }
            .filter { $0.target.isLoggable }
            .filter { target == nil || $0.target.id == target?.id }
            // Keep worklogs inside the day they happened, even for a session over midnight.
            .flatMap { $0.splitAcrossDays(calendar: calendar, asOf: now) }

        guard !candidates.isEmpty else { return [] }

        // Group by (issue key, day).
        struct GroupKey: Hashable {
            let issueKey: String
            let day: Date
        }
        let grouped = Dictionary(grouping: candidates) { segment in
            GroupKey(
                issueKey: segment.target.issueKey ?? "",
                day: calendar.startOfDay(for: segment.start)
            )
        }

        var drafts: [WorklogDraft] = []
        for (key, group) in grouped {
            let exactSeconds = group.reduce(0) { $0 + $1.closedDuration }
            let rounded = round(
                seconds: exactSeconds,
                minutes: settings.roundingMinutes,
                mode: settings.roundingMode
            )

            // Too small to be worth logging: leave the segments uncovered so they merge into
            // the next draft for this issue and day.
            guard rounded >= max(60, settings.minimumLoggableSeconds) else { continue }

            let earliestStart = group.map(\.start).min() ?? now

            drafts.append(
                WorklogDraft(
                    issueKey: key.issueKey,
                    issueID: resolveIssueID(in: group),
                    started: earliestStart,
                    seconds: rounded,
                    comment: comment(for: group, settings: settings),
                    // Note: the *split* pieces carry their parent's id, so covering the parent
                    // id correctly marks the whole original segment as claimed.
                    segmentIDs: Array(Set(group.map(\.id))),
                    createdAt: now
                )
            )
        }

        // Stable ordering so the review list does not shuffle between launches.
        return drafts.sorted {
            ($0.started, $0.issueKey) < ($1.started, $1.issueKey)
        }
    }

    private static func resolveIssueID(in group: [WorkSegment]) -> String? {
        for segment in group {
            if case .issue(let ref) = segment.target, let id = ref.id { return id }
        }
        return nil
    }

    /// Assembles the Jira worklog comment from the notes the user attached to the segments.
    ///
    /// Notes are de-duplicated in first-seen order: pausing and resuming the same task all
    /// afternoon should not produce "Fixing the parser" nine times.
    static func comment(for group: [WorkSegment], settings: Settings) -> String? {
        var lines: [String] = []
        if settings.includeNoteAsComment {
            var seen = Set<String>()
            for segment in group.sorted(by: { $0.start < $1.start }) {
                guard let note = segment.note?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !note.isEmpty,
                      seen.insert(note.lowercased()).inserted
                else { continue }
                lines.append(note)
            }
        }
        let signature = settings.commentSignature.trimmingCharacters(in: .whitespacesAndNewlines)
        if !signature.isEmpty { lines.append(signature) }

        let joined = lines.joined(separator: "\n")
        return joined.isEmpty ? nil : joined
    }
}
