import SwiftUI
import AppKit
import ChronoCore

/// Search box, issue lists and the one-tap quick-capture buckets.
///
/// The quick-capture row is the answer to "I get random work and ad-hoc calls": it turns
/// "something just interrupted me" into a single click, with no ticket to choose in the moment.
/// The time is filed against a real issue later, from the timesheet.
struct PanelList: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var query = ""
    @FocusState private var searchFocused: Bool

    private var engine: TrackingEngine { environment.engine }

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            Divider().opacity(0.5)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: Theme.Spacing.medium) {
                    if query.isEmpty {
                        branchSection
                        pinnedSection
                        recentSection
                        filterSection
                    } else {
                        searchResultsSection
                    }
                }
                .padding(.horizontal, Theme.Spacing.large)
                .padding(.vertical, Theme.Spacing.medium)
            }
            .frame(minHeight: 120, maxHeight: 260)

            Divider().opacity(0.5)
            quickCapture
        }
    }

    // MARK: - Search

    private var searchBar: some View {
        HStack(spacing: Theme.Spacing.small) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)

            TextField("Search issues, or paste a key", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused($searchFocused)
                .onChange(of: query) { _, newValue in environment.issues.search(newValue) }
                .onSubmit(startFirstResult)

            if environment.issues.isSearching {
                ProgressView().controlSize(.small).scaleEffect(0.7)
            }
            if !query.isEmpty {
                Button {
                    query = ""
                    environment.issues.clear()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }

            filterMenu
        }
        .padding(.horizontal, Theme.Spacing.large)
        .padding(.vertical, Theme.Spacing.small)
    }

    private var filterMenu: some View {
        Menu {
            ForEach(engine.settings.savedFilters) { filter in
                Button {
                    query = ""
                    Task { await environment.issues.loadFilter(filter) }
                } label: {
                    Label(filter.name, systemImage: filter.symbolName)
                }
            }
        } label: {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .font(.system(size: 11))
        }
        .menuStyle(.borderlessButton)
        .frame(width: 20)
        .help(environment.issues.activeFilter?.name ?? "Choose a filter")
    }

    /// Enter starts the top result — the fastest possible path from "I know the key" to tracking.
    private func startFirstResult() {
        if let first = environment.issues.results.first {
            environment.start(issue: first)
            query = ""
            environment.issues.clear()
        } else if IssueService.looksLikeIssueKey(query) {
            // Track it even if Jira has not answered yet; the summary fills in later.
            environment.start(issue: IssueRef(key: query.uppercased().trimmingCharacters(in: .whitespaces)))
            query = ""
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var searchResultsSection: some View {
        if let message = environment.issues.errorMessage {
            EmptyStateView(systemImage: "exclamationmark.triangle", title: "Search failed", message: message)
        } else if environment.issues.results.isEmpty && !environment.issues.isSearching {
            EmptyStateView(
                systemImage: "magnifyingglass",
                title: "Nothing found",
                message: IssueService.looksLikeIssueKey(query)
                    ? "Press Return to track \(query.uppercased()) anyway."
                    : "Try a different word, or paste an issue key."
            )
        } else {
            VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                SectionHeader(title: "Results", trailing: "\(environment.issues.results.count)")
                ForEach(environment.issues.results) { issue in
                    IssueRow(issue: issue) { query = "" }
                }
            }
        }
    }

    /// Issues named by the branch you have checked out.
    ///
    /// Placed above Pinned and Recent because when it applies it is almost always the right
    /// answer — you are on that branch because you are working on that issue.
    @ViewBuilder
    private var branchSection: some View {
        let suggestions = environment.branchSuggestions.suggestions
        if !suggestions.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                SectionHeader(title: "On your branch")
                ForEach(suggestions) { suggestion in
                    BranchSuggestionRow(suggestion: suggestion)
                }
            }
        }
    }

    @ViewBuilder
    private var pinnedSection: some View {
        if !engine.state.pinnedIssues.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                SectionHeader(title: "Pinned")
                ForEach(engine.state.pinnedIssues) { issue in
                    IssueRow(issue: issue, isPinned: true)
                }
            }
        }
    }

    @ViewBuilder
    private var recentSection: some View {
        let recents = engine.state.recentIssues.prefix(6)
        if !recents.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                SectionHeader(title: "Recent")
                ForEach(Array(recents)) { issue in
                    IssueRow(issue: issue)
                }
            }
        }
    }

    @ViewBuilder
    private var filterSection: some View {
        let pinnedKeys = Set(engine.state.pinnedIssues.map(\.key))
        let recentKeys = Set(engine.state.recentIssues.prefix(6).map(\.key))
        // Don't repeat anything already shown above; the panel is short.
        let remaining = environment.issues.results.filter {
            !pinnedKeys.contains($0.key) && !recentKeys.contains($0.key)
        }

        if !remaining.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                SectionHeader(
                    title: environment.issues.activeFilter?.name ?? "From Jira",
                    trailing: "\(remaining.count)"
                )
                ForEach(remaining) { issue in
                    IssueRow(issue: issue)
                }
            }
        } else if environment.issues.results.isEmpty,
                  engine.state.recentIssues.isEmpty,
                  !environment.issues.isSearching {
            emptyFirstRun
        }
    }

    @ViewBuilder
    private var emptyFirstRun: some View {
        if environment.connection.state.isConnected {
            EmptyStateView(
                systemImage: "tray",
                title: "No issues in this filter",
                message: "Search above, or pick a different filter."
            )
        } else {
            VStack(spacing: Theme.Spacing.small) {
                EmptyStateView(
                    systemImage: "link",
                    title: "Not connected to Jira",
                    message: "You can still track ad-hoc time below — connect whenever you like."
                )
                Button("Connect to Jira") {
                    WindowManager.shared.showSettings(environment: environment)
                }
                .buttonStyle(FilledButtonStyle(compact: true))
            }
        }
    }

    // MARK: - Quick capture

    private static let quickCategories: [AdhocCategory] = [.meeting, .call, .interruption, .breakTime]

    private var quickCapture: some View {
        HStack(spacing: Theme.Spacing.small) {
            Text("QUICK")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)
                .tracking(0.6)

            ForEach(Self.quickCategories, id: \.self) { category in
                Button {
                    environment.start(adhoc: category)
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: category.symbolName).font(.system(size: 9))
                        Text(category.shortLabel).font(.system(size: 10.5, weight: .medium))
                    }
                }
                .buttonStyle(QuietButtonStyle(
                    tint: category == .breakTime ? .green : .orange,
                    compact: true
                ))
                .help("Start tracking \(category.defaultLabel.lowercased()) — assign it to an issue later")
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Spacing.large)
        .padding(.vertical, Theme.Spacing.small)
    }
}

// MARK: - Issue row

/// One selectable issue. The whole row is the hit target; the play button is affordance only.
struct IssueRow: View {
    let issue: IssueRef
    var isPinned = false
    var onStart: (() -> Void)?

    @Environment(AppEnvironment.self) private var environment
    @State private var hovering = false

    private var todaySeconds: TimeInterval {
        environment.engine.todayRollup.totals
            .first { $0.target.issueKey == issue.key }?.seconds ?? 0
    }

    private var isActive: Bool { environment.engine.activeTarget?.issueKey == issue.key }

    var body: some View {
        HStack(spacing: Theme.Spacing.small) {
            TargetIcon(target: .issue(issue), size: 11)

            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 5) {
                    Text(issue.key)
                        .font(.system(size: 11.5, weight: .semibold))
                    if let status = issue.status, hovering || isActive {
                        Chip(text: status, tint: .secondary)
                    }
                    if isActive {
                        Chip(text: "Tracking", systemImage: "record.circle", tint: .accentColor)
                    }
                }
                if !issue.summary.isEmpty {
                    Text(issue.summary)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }

            Spacer(minLength: Theme.Spacing.small)

            if todaySeconds > 0 {
                Text(DurationFormat.humane(todaySeconds))
                    .font(.system(size: 10, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
            }

            if hovering {
                Button {
                    if let url = environment.connection.issueURL(key: issue.key) {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    Image(systemName: "arrow.up.right.square")
                        .font(.system(size: 10))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
                .help("Open in Jira")

                Button {
                    if isPinned {
                        environment.engine.unpin(issueKey: issue.key)
                    } else {
                        environment.engine.pin(issue)
                    }
                } label: {
                    Image(systemName: isPinned ? "pin.slash" : "pin")
                        .font(.system(size: 10))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
                .help(isPinned ? "Unpin" : "Pin to the top")
            }

            Image(systemName: isActive ? "waveform" : "play.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(isActive ? Color.accentColor : (hovering ? Color.accentColor : Color.tertiaryLabel))
                .frame(width: 16)
        }
        .padding(.horizontal, Theme.Spacing.small)
        .padding(.vertical, 5)
        .background(
            hovering ? Color.primary.opacity(0.06) : Color.clear,
            in: RoundedRectangle(cornerRadius: 7)
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture {
            environment.start(issue: issue)
            onStart?()
        }
        .help(issue.summary.isEmpty ? issue.key : "\(issue.key) — \(issue.summary)")
    }
}

extension Color {
    /// SwiftUI has no direct equivalent of `tertiaryLabelColor`, and `.tertiary` is a
    /// ShapeStyle rather than a Color, so bridge it once here.
    static let tertiaryLabel = Color(nsColor: .tertiaryLabelColor)
}

/// One issue offered because a watched repository has it checked out.
///
/// Shows the repository and branch rather than only the key: an unexpected suggestion should
/// explain itself, and with more than one repository the key alone does not say where it came
/// from.
struct BranchSuggestionRow: View {
    let suggestion: BranchSuggestions.Suggestion
    @Environment(AppEnvironment.self) private var environment
    @State private var hovering = false

    var body: some View {
        Button {
            // Tracked immediately by key; Jira fills in the summary when it answers, exactly as
            // pressing Return on a typed key already does.
            environment.start(issue: IssueRef(key: suggestion.key))
        } label: {
            HStack(spacing: Theme.Spacing.small) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)

                Text(suggestion.key)
                    .font(.system(size: 12, weight: .semibold))

                Text("\(suggestion.repository) · \(suggestion.branch)")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer()

                if hovering {
                    Text("Start")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, Theme.Spacing.small)
            .padding(.vertical, 5)
            .background(
                hovering ? Color.primary.opacity(0.06) : Color.clear,
                in: RoundedRectangle(cornerRadius: 6)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Checked out in \(suggestion.repository) on \(suggestion.branch)")
    }
}
