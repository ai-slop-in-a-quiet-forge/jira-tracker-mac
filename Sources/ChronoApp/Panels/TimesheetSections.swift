import SwiftUI
import AppKit
import ChronoCore

// MARK: - Unfiled time

/// Time that was tracked but has no Jira issue behind it yet.
///
/// Deliberately the first thing on the page, because it is the only part of the day that needs a
/// decision. Everything else is just a record.
struct UnfiledTimeSection: View {
    let day: Date
    @Environment(AppEnvironment.self) private var environment

    /// Ad-hoc totals for the day, grouped by bucket.
    private var buckets: [TargetTotal] {
        DayRollup.build(segments: environment.engine.state.allSegments(), day: day, asOf: Date())
            .totals
            .filter { !$0.target.isLoggable && $0.target.adhoc?.category.countsAsWork == true }
    }

    var body: some View {
        if !buckets.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                HStack {
                    SectionHeader(title: "Needs a ticket")
                    Spacer()
                    Text(DurationFormat.humane(buckets.reduce(0) { $0 + $1.seconds }))
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.orange)
                }

                ForEach(buckets) { bucket in
                    UnfiledRow(total: bucket, day: day)
                }
            }
        }
    }
}

struct UnfiledRow: View {
    let total: TargetTotal
    let day: Date
    @Environment(AppEnvironment.self) private var environment
    @State private var showingPicker = false

    var body: some View {
        HStack(spacing: Theme.Spacing.medium) {
            TargetIcon(target: total.target)

            VStack(alignment: .leading, spacing: 1) {
                Text(total.target.displayLabel)
                    .font(.system(size: 12, weight: .medium))
                Text("\(total.segmentCount == 1 ? "1 entry" : "\(total.segmentCount) entries") · \(total.firstStart.formatted(date: .omitted, time: .shortened))–\(total.lastEnd.formatted(date: .omitted, time: .shortened))")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text(DurationFormat.humane(total.seconds))
                .font(.system(size: 12, weight: .semibold))
                .monospacedDigit()

            Button("Assign to issue…") { showingPicker = true }
                .buttonStyle(FilledButtonStyle(compact: true))
                .popover(isPresented: $showingPicker, arrowEdge: .bottom) {
                    IssuePickerPopover { issue in
                        showingPicker = false
                        guard let adhocID = total.target.adhoc?.id else { return }
                        environment.engine.assign(adhocID: adhocID, to: issue)
                        environment.sync.syncIfNeeded()
                    }
                    .environment(environment)
                }
        }
        .padding(Theme.Spacing.medium)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: Theme.cardRadius))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cardRadius)
                .strokeBorder(Color.orange.opacity(0.3), lineWidth: 0.5)
        )
    }
}

// MARK: - Entries

/// Everything tracked on the day, grouped by task and expandable to individual stretches.
struct DayEntriesSection: View {
    let day: Date
    @Environment(AppEnvironment.self) private var environment
    @State private var expanded: Set<String> = []

    private var rollup: DayRollup {
        DayRollup.build(segments: environment.engine.state.allSegments(), day: day, asOf: Date())
    }

    private func segments(for target: TrackingTarget) -> [WorkSegment] {
        environment.engine.state.allSegments()
            .filter { $0.target.id == target.id && Calendar.current.isDate($0.start, inSameDayAs: day) }
            .sorted { $0.start < $1.start }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            SectionHeader(title: "Entries", trailing: "\(rollup.segmentCount)")

            if rollup.totals.isEmpty {
                EmptyStateView(
                    systemImage: "calendar.badge.clock",
                    title: "Nothing tracked on this day",
                    message: "Use \"Add entry\" above to fill in time after the fact."
                )
            } else {
                ForEach(rollup.totals) { total in
                    VStack(spacing: 0) {
                        EntryRow(
                            total: total,
                            isExpanded: expanded.contains(total.id)
                        ) {
                            if expanded.contains(total.id) {
                                expanded.remove(total.id)
                            } else {
                                expanded.insert(total.id)
                            }
                        }

                        if expanded.contains(total.id) {
                            VStack(spacing: 2) {
                                ForEach(segments(for: total.target)) { segment in
                                    SegmentRow(segment: segment)
                                }
                            }
                            .padding(.leading, Theme.Spacing.section)
                            .padding(.top, 4)
                        }
                    }
                }
            }
        }
    }
}

struct EntryRow: View {
    let total: TargetTotal
    let isExpanded: Bool
    let onToggle: () -> Void

    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        HStack(spacing: Theme.Spacing.small) {
            Button(action: onToggle) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 12)
            }
            .buttonStyle(.plain)

            TargetIcon(target: total.target)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(total.target.shortLabel)
                        .font(.system(size: 12, weight: .semibold))
                    if total.isRunning {
                        Chip(text: "Running", systemImage: "record.circle", tint: .accentColor)
                    }
                }
                if case .issue(let ref) = total.target, !ref.summary.isEmpty {
                    Text(ref.summary)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            Text("\(total.firstStart.formatted(date: .omitted, time: .shortened))–\(total.lastEnd.formatted(date: .omitted, time: .shortened))")
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)

            Text(DurationFormat.humane(total.seconds))
                .font(.system(size: 12, weight: .semibold))
                .monospacedDigit()
                .frame(width: 62, alignment: .trailing)

            if let key = total.target.issueKey {
                Button {
                    if let url = environment.connection.issueURL(key: key) {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    Image(systemName: "arrow.up.right.square").font(.system(size: 10))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, Theme.Spacing.medium)
        .padding(.vertical, 8)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// One stretch of time, editable.
struct SegmentRow: View {
    let segment: WorkSegment
    @Environment(AppEnvironment.self) private var environment
    @State private var hovering = false
    @State private var showingPicker = false
    @State private var showingTimeEditor = false

    var body: some View {
        HStack(spacing: Theme.Spacing.small) {
            let times = "\(segment.start.formatted(date: .omitted, time: .shortened)) – \(segment.end?.formatted(date: .omitted, time: .shortened) ?? "now")"
            if segment.isOpen {
                // A running entry's times belong to the clock, not to an edit form.
                Text(times)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.secondary)
            } else {
                Button(times) { showingTimeEditor = true }
                    .buttonStyle(.plain)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .help("Correct the start or end time")
                    .popover(isPresented: $showingTimeEditor, arrowEdge: .bottom) {
                        SegmentTimeEditor(segment: segment) { showingTimeEditor = false }
                            .environment(environment)
                    }
            }

            if segment.trimmedIdle > 0 {
                Chip(
                    text: "-\(DurationFormat.humane(segment.trimmedIdle))",
                    systemImage: "moon.zzz.fill",
                    tint: .secondary
                )
                .help("Idle time removed from this stretch")
            }
            if segment.source != .manual {
                Chip(text: segment.source.rawValue, tint: .secondary)
                    .help("How this entry was created")
            }
            if let note = segment.note, !note.isEmpty {
                Text(note)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            Spacer()

            Text(DurationFormat.humane(segment.duration(asOf: Date())))
                .font(.system(size: 10.5, weight: .medium))
                .monospacedDigit()

            if hovering && !segment.isOpen {
                Button("Edit…") { showingTimeEditor = true }
                    .buttonStyle(QuietButtonStyle(compact: true))
                    .help("Correct the start or end time")

                Button("Move…") { showingPicker = true }
                    .buttonStyle(QuietButtonStyle(compact: true))
                    .popover(isPresented: $showingPicker, arrowEdge: .bottom) {
                        IssuePickerPopover { issue in
                            showingPicker = false
                            environment.engine.retarget(segmentID: segment.id, to: .issue(issue))
                        }
                        .environment(environment)
                    }

                Button {
                    environment.engine.deleteSegment(id: segment.id)
                } label: {
                    Image(systemName: "trash").font(.system(size: 9.5))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.red.opacity(0.8))
                .help("Delete this entry")
            }
        }
        .padding(.horizontal, Theme.Spacing.small)
        .padding(.vertical, 4)
        .background(hovering ? Color.primary.opacity(0.05) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
        .onHover { hovering = $0 }
    }
}

/// Corrects an entry's start and end.
///
/// Mirrors `BackfillButton`'s form, with one difference that matters: the pickers are *bounded*
/// by the neighbouring entries. Offering a time that will then be refused is a worse experience
/// than not offering it, so the window comes from `TrackingEngine.bounds(forSegment:)` and the
/// engine's rejection is a backstop rather than the primary guard.
struct SegmentTimeEditor: View {
    let segment: WorkSegment
    let onClose: () -> Void

    @Environment(AppEnvironment.self) private var environment
    @State private var start: Date
    @State private var end: Date
    @State private var rejection: String?

    init(segment: WorkSegment, onClose: @escaping () -> Void) {
        self.segment = segment
        self.onClose = onClose
        _start = State(initialValue: segment.start)
        _end = State(initialValue: segment.end ?? segment.start)
    }

    private var bounds: SegmentBounds? {
        environment.engine.bounds(forSegment: segment.id)
    }

    private var isValid: Bool {
        bounds?.allows(start: start, end: end) ?? (end > start)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            Text("Correct this entry\u{2019}s times")
                .font(.system(size: 12.5, weight: .semibold))

            DatePicker("From", selection: $start, in: startRange, displayedComponents: [.hourAndMinute])
                .font(.system(size: 11.5))
            DatePicker("To", selection: $end, in: endRange, displayedComponents: [.hourAndMinute])
                .font(.system(size: 11.5))

            if let rejection {
                Text(rejection)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else if end <= start {
                Text("The end time needs to be after the start.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.orange)
            } else {
                HStack(spacing: 6) {
                    Text(DurationFormat.humane(end.timeIntervalSince(start)))
                        .font(.system(size: 11, weight: .medium))
                    let delta = end.timeIntervalSince(start) - segment.closedDuration
                    if abs(delta) >= 1 {
                        Text(delta > 0
                            ? "+\(DurationFormat.humane(delta))"
                            : "-\(DurationFormat.humane(-delta))")
                            .font(.system(size: 10.5))
                            .foregroundStyle(delta > 0 ? .green : .orange)
                    }
                }
                .foregroundStyle(.secondary)
            }

            if let limits = boundsDescription {
                Text(limits)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }

            HStack {
                Spacer()
                Button("Cancel") { onClose() }
                    .buttonStyle(QuietButtonStyle(compact: true))
                Button("Save") { save() }
                    .buttonStyle(FilledButtonStyle(compact: true))
                    .disabled(!isValid)
            }
        }
        .padding(Theme.Spacing.large)
        .frame(width: 300)
    }

    /// Clamped so the picker cannot even offer an overlapping time. The upper bound for the
    /// start is the current end (and vice versa), which keeps the entry from inverting.
    private var startRange: ClosedRange<Date> {
        let lower = bounds?.earliestStart ?? segment.start.addingTimeInterval(-86_400)
        let upper = max(lower, end)
        return lower...upper
    }

    private var endRange: ClosedRange<Date> {
        let upper = bounds?.latestEnd ?? (segment.end ?? segment.start).addingTimeInterval(86_400)
        let lower = min(start, upper)
        return lower...upper
    }

    private var boundsDescription: String? {
        guard let bounds else { return nil }
        let formatter: (Date) -> String = { $0.formatted(date: .omitted, time: .shortened) }
        switch (bounds.earliestStart, bounds.latestEnd) {
        case (let earliest?, let latest?):
            return "Must stay between \(formatter(earliest)) and \(formatter(latest))."
        case (let earliest?, nil):
            return "Cannot start before \(formatter(earliest))."
        case (nil, let latest?):
            return "Cannot end after \(formatter(latest))."
        case (nil, nil):
            return nil
        }
    }

    private func save() {
        switch environment.engine.editSegmentTimes(id: segment.id, start: start, end: end) {
        case .applied:
            rejection = nil
            onClose()
        case .rejected(let reason):
            // The bounded pickers should make these unreachable; showing the reason rather than
            // failing silently is what makes that assumption safe to hold.
            rejection = Self.describe(reason)
        }
    }

    private static func describe(_ reason: SegmentEditRejection) -> String {
        let time: (Date) -> String = { $0.formatted(date: .omitted, time: .shortened) }
        switch reason {
        case .notFound:
            return "That entry no longer exists."
        case .endNotAfterStart:
            return "The end time needs to be after the start."
        case .overlapsPrevious(let earliest):
            return "Cannot start before \(time(earliest)) — the previous entry ends there."
        case .overlapsNext(let latest):
            return "Cannot end after \(time(latest)) — the next entry starts there."
        case .segmentIsOpen:
            return "This entry is still running. Stop the timer first."
        }
    }
}

// MARK: - Worklog queue

/// What has been sent to Jira, what is waiting, and what went wrong.
struct WorklogQueueSection: View {
    let day: Date
    @Environment(AppEnvironment.self) private var environment

    private var drafts: [WorklogDraft] {
        environment.engine.state.drafts
            .filter { Calendar.current.isDate($0.started, inSameDayAs: day) }
            .sorted { $0.started < $1.started }
    }

    var body: some View {
        if !drafts.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                HStack {
                    SectionHeader(title: "Worklogs")
                    Spacer()
                    if environment.sync.pendingCount > 0 {
                        Button(environment.sync.isSyncing ? "Sending…" : "Send now") {
                            Task { await environment.sync.sync(force: true) }
                        }
                        .buttonStyle(QuietButtonStyle(compact: true))
                        .disabled(environment.sync.isSyncing)
                    }
                }

                ForEach(drafts) { draft in
                    DraftRow(draft: draft)
                }
            }
        }
    }
}

struct DraftRow: View {
    let draft: WorklogDraft
    @Environment(AppEnvironment.self) private var environment

    private var tint: Color {
        switch draft.state {
        case .submitted: return .green
        case .failed(let kind): return kind.isRetryable ? .orange : .red
        case .submitting: return .accentColor
        case .pending: return .secondary
        case .discarded: return .secondary
        }
    }

    private var symbol: String {
        switch draft.state {
        case .submitted: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        case .submitting: return "arrow.up.circle"
        case .pending: return "clock"
        case .discarded: return "xmark.circle"
        }
    }

    var body: some View {
        HStack(spacing: Theme.Spacing.small) {
            Image(systemName: symbol)
                .font(.system(size: 11))
                .foregroundStyle(tint)
                .frame(width: 16)

            Text(draft.issueKey)
                .font(.system(size: 11.5, weight: .semibold))

            Text(DurationFormat.jira(Double(draft.seconds)))
                .font(.system(size: 11, weight: .medium))
                .monospacedDigit()

            Text(draft.state.label)
                .font(.system(size: 10.5))
                .foregroundStyle(tint)

            if let comment = draft.comment, !comment.isEmpty {
                Text("· \(comment)")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            Spacer()

            if let error = draft.lastError, case .failed = draft.state {
                Text(error)
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 180, alignment: .trailing)
                    .help(error)
            }

            actions
        }
        .padding(.horizontal, Theme.Spacing.medium)
        .padding(.vertical, 7)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private var actions: some View {
        switch draft.state {
        case .submitted:
            Button("Undo") {
                Task { _ = await environment.sync.undo(draft: draft) }
            }
            .buttonStyle(QuietButtonStyle(compact: true))
            .help("Deletes the worklog from Jira again")

        case .failed(let kind):
            HStack(spacing: 4) {
                if kind.isRetryable {
                    Button("Retry") {
                        Task { await environment.sync.sync(force: true) }
                    }
                    .buttonStyle(QuietButtonStyle(compact: true))
                }
                if let remedy = kind.remedy {
                    Image(systemName: "info.circle")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .help(remedy)
                }
                Button("Discard") { environment.engine.discardDraft(id: draft.id) }
                    .buttonStyle(QuietButtonStyle(tint: .red, compact: true))
            }

        case .pending:
            Button("Discard") { environment.engine.discardDraft(id: draft.id) }
                .buttonStyle(QuietButtonStyle(tint: .red, compact: true))

        default:
            EmptyView()
        }
    }
}

// MARK: - Shared pickers

/// Compact issue search, used wherever time needs attaching to a ticket.
struct IssuePickerPopover: View {
    let onPick: (IssueRef) -> Void
    @Environment(AppEnvironment.self) private var environment
    @State private var query = ""
    @FocusState private var focused: Bool

    private var options: [IssueRef] {
        query.isEmpty
            ? Array((environment.engine.state.pinnedIssues + environment.engine.state.recentIssues).prefix(8))
            : environment.issues.results
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                TextField("Search issues, or paste a key", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .focused($focused)
                    .onChange(of: query) { _, value in environment.issues.search(value) }
                    .onSubmit {
                        if let first = options.first { onPick(first) }
                        else if IssueService.looksLikeIssueKey(query) {
                            onPick(IssueRef(key: query.uppercased().trimmingCharacters(in: .whitespaces)))
                        }
                    }
                if environment.issues.isSearching {
                    ProgressView().controlSize(.small).scaleEffect(0.6)
                }
            }
            .padding(.horizontal, Theme.Spacing.small)
            .padding(.vertical, 6)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 7))

            if options.isEmpty {
                Text(IssueService.looksLikeIssueKey(query)
                     ? "Press Return to use \(query.uppercased())."
                     : "No matches.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, Theme.Spacing.small)
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(options) { issue in
                            Button {
                                onPick(issue)
                            } label: {
                                HStack(spacing: 6) {
                                    TargetIcon(target: .issue(issue), size: 10)
                                    Text(issue.key).font(.system(size: 11, weight: .semibold))
                                    Text(issue.summary)
                                        .font(.system(size: 10.5))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                    Spacer(minLength: 0)
                                }
                                .padding(.horizontal, 6)
                                .padding(.vertical, 5)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(maxHeight: 220)
            }
        }
        .padding(Theme.Spacing.medium)
        .frame(width: 340)
        .onAppear { focused = true }
    }
}

/// Adds time you forgot to track at all.
struct BackfillButton: View {
    let day: Date
    @Environment(AppEnvironment.self) private var environment
    @State private var showing = false
    @State private var start = Date()
    @State private var end = Date()
    @State private var note = ""
    @State private var target: IssueRef?

    var body: some View {
        Button("Add entry") { prepare(); showing = true }
            .buttonStyle(QuietButtonStyle(compact: true))
            .popover(isPresented: $showing, arrowEdge: .bottom) { form }
    }

    private func prepare() {
        let calendar = Calendar.current
        // Default to a plausible slot: the hour before now, on the selected day.
        let hour = calendar.component(.hour, from: Date())
        start = calendar.date(bySettingHour: max(0, hour - 1), minute: 0, second: 0, of: day) ?? day
        end = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: day) ?? day
        note = ""
        target = nil
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            Text("Add time you didn't track")
                .font(.system(size: 12.5, weight: .semibold))

            DatePicker("From", selection: $start, displayedComponents: [.hourAndMinute])
                .font(.system(size: 11.5))
            DatePicker("To", selection: $end, displayedComponents: [.hourAndMinute])
                .font(.system(size: 11.5))

            if end <= start {
                Text("The end time needs to be after the start.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.orange)
            } else {
                Text(DurationFormat.humane(end.timeIntervalSince(start)))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            Divider()

            if let target {
                HStack(spacing: 6) {
                    TargetIcon(target: .issue(target), size: 10)
                    Text(target.key).font(.system(size: 11.5, weight: .semibold))
                    Spacer()
                    Button("Change") { self.target = nil }
                        .buttonStyle(QuietButtonStyle(compact: true))
                }
            } else {
                IssuePickerPopover { issue in target = issue }
                    .environment(environment)
                    .frame(width: 320)
            }

            TextField("Note (optional)", text: $note)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11.5))

            HStack {
                Spacer()
                Button("Cancel") { showing = false }
                    .buttonStyle(QuietButtonStyle(compact: true))
                Button("Add") { add() }
                    .buttonStyle(FilledButtonStyle(compact: true))
                    .disabled(target == nil || end <= start)
            }
        }
        .padding(Theme.Spacing.medium)
        .frame(width: 360)
    }

    private func add() {
        guard let target, end > start else { return }
        environment.engine.backfill(
            target: .issue(target),
            start: start,
            end: end,
            note: note.isEmpty ? nil : note
        )
        showing = false
        environment.sync.syncIfNeeded()
    }
}
