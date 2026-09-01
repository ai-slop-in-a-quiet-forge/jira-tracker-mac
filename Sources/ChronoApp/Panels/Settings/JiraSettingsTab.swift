import SwiftUI
import ChronoCore

/// Connection plus everything about how time reaches Jira.
struct JiraSettingsTab: View {
    @Environment(AppEnvironment.self) private var environment

    private var bind: SettingsBinding { SettingsBinding(environment: environment) }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.section) {
            JiraConnectionForm()

            SettingsGroup(
                "When to send worklogs",
                footnote: "Nothing is ever lost by choosing a later option — time is stored locally and queued until you submit it."
            ) {
                Picker("", selection: bind.bind(\.submitStrategy)) {
                    ForEach(SubmitStrategy.allCases, id: \.self) { strategy in
                        Text(strategy.title).tag(strategy)
                    }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
            }

            SettingsGroup(
                "Rounding",
                footnote: "Rounding applies to each issue's daily total, not to individual stretches — so a dozen short interruptions cannot inflate into a dozen rounded-up minutes."
            ) {
                Picker("Round to", selection: bind.bind(\.roundingMinutes)) {
                    Text("Exact seconds").tag(0)
                    Text("Nearest minute").tag(1)
                    Text("5 minutes").tag(5)
                    Text("10 minutes").tag(10)
                    Text("15 minutes").tag(15)
                    Text("30 minutes").tag(30)
                }
                .font(.system(size: 11.5))

                if environment.engine.settings.roundingMinutes > 1 {
                    Picker("Direction", selection: bind.bind(\.roundingMode)) {
                        ForEach(RoundingMode.allCases, id: \.self) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .font(.system(size: 11.5))
                }

                Divider()

                Picker("Minimum worklog", selection: bind.bind(\.minimumLoggableSeconds)) {
                    Text("1 minute").tag(60)
                    Text("2 minutes").tag(120)
                    Text("5 minutes").tag(300)
                    Text("15 minutes").tag(900)
                }
                .font(.system(size: 11.5))
                .help("Shorter stretches stay queued and merge into the next worklog for that issue")
            }

            SettingsGroup("Estimates and comments") {
                Picker("Remaining estimate", selection: bind.bind(\.adjustEstimate)) {
                    ForEach(EstimateAdjustment.allCases, id: \.self) { option in
                        Text(option.title).tag(option)
                    }
                }
                .font(.system(size: 11.5))

                Toggle("Use my notes as the worklog comment", isOn: bind.bind(\.includeNoteAsComment))
                    .font(.system(size: 11.5))

                LabeledField(
                    label: "Append to every comment (optional)",
                    placeholder: "e.g. logged via Chrono",
                    text: bind.bind(\.commentSignature)
                )
            }

            SettingsGroup(
                "Meeting time",
                footnote: "If your team has a standing ticket for ceremonies and calls, name it here and Chrono will log meeting time against it instead of leaving it unfiled."
            ) {
                LabeledField(
                    label: "Log meetings against this issue (optional)",
                    placeholder: "e.g. CYM-100",
                    text: bind.bind(\.meetingIssueKey)
                )
            }

            WatchedRepositoryEditor()

            SavedFilterEditor()
        }
    }
}

/// Manages the repositories whose branch names Chrono reads.
struct WatchedRepositoryEditor: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var message: String?

    private var paths: [String] { environment.engine.settings.watchedRepositoryPaths }

    var body: some View {
        SettingsGroup(
            "Suggest from your git branch",
            footnote: "A branch called CYM-1234-fix-parser offers CYM-1234 at the top of the panel. Chrono reads the checked-out branch of these folders when the panel opens, and nothing else — no file watching, and it never writes to your repositories."
        ) {
            if paths.isEmpty {
                Text("No folders added. Nothing is read until you add one.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(paths, id: \.self) { path in
                    HStack(spacing: Theme.Spacing.small) {
                        Image(systemName: "folder")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(URL(fileURLWithPath: path).lastPathComponent)
                                .font(.system(size: 11.5, weight: .medium))
                            Text(abbreviated(path))
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer()
                        if environment.branchSuggestions.unreadablePaths.contains(path) {
                            Text("Not readable")
                                .font(.system(size: 10))
                                .foregroundStyle(.orange)
                                .help("Chrono could not run git here. The folder may have been moved, renamed, or be on a volume that is not mounted.")
                        }
                        Button {
                            remove(path)
                        } label: {
                            Image(systemName: "minus.circle").font(.system(size: 10.5))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.red.opacity(0.8))
                        .help("Stop reading this folder")
                    }
                }
            }

            Divider()
            HStack {
                Button("Add a folder…") { add() }
                    .buttonStyle(FilledButtonStyle(compact: true))
                if let message {
                    Text(message)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    /// `~/code/thing` reads better than the full path and fits the row.
    private func abbreviated(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    private func add() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Watch"
        panel.message = "Choose a git repository"

        guard panel.runModal() == .OK, let url = panel.url else { return }
        let path = url.path

        guard !paths.contains(path) else {
            message = "That folder is already in the list."
            return
        }

        // Validated on the way in, so a mistake is caught while the folder chooser is still fresh
        // in mind rather than showing up later as a suggestion that never appears.
        Task {
            guard await BranchSuggestions.isRepository(path) else {
                message = "That folder is not a git repository."
                return
            }
            message = nil
            environment.mutateSettings { $0.watchedRepositoryPaths.append(path) }
            environment.refreshBranchSuggestions()
        }
    }

    private func remove(_ path: String) {
        message = nil
        environment.mutateSettings { settings in
            settings.watchedRepositoryPaths.removeAll { $0 == path }
        }
        environment.refreshBranchSuggestions()
    }
}

/// Lets the user curate the filter list offered in the panel.
struct SavedFilterEditor: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var newName = ""
    @State private var newJQL = ""

    var body: some View {
        SettingsGroup(
            "Issue lists",
            footnote: "These appear in the filter menu next to the panel's search box."
        ) {
            ForEach(environment.engine.settings.savedFilters) { filter in
                HStack(spacing: Theme.Spacing.small) {
                    Image(systemName: filter.symbolName)
                        .font(.system(size: 10))
                        .foregroundStyle(.tint)
                        .frame(width: 16)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(filter.name).font(.system(size: 11.5, weight: .medium))
                        Text(filter.jql)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    Spacer()
                    Button {
                        environment.mutateSettings { settings in
                            settings.savedFilters.removeAll { $0.id == filter.id }
                        }
                    } label: {
                        Image(systemName: "minus.circle")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            }

            Divider()

            HStack(spacing: Theme.Spacing.small) {
                TextField("Name", text: $newName)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11))
                    .frame(width: 120)
                TextField("JQL", text: $newJQL)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11, design: .monospaced))
                Button("Add") {
                    let name = newName.trimmingCharacters(in: .whitespaces)
                    let jql = newJQL.trimmingCharacters(in: .whitespaces)
                    guard !name.isEmpty, !jql.isEmpty else { return }
                    environment.mutateSettings { settings in
                        settings.savedFilters.append(SavedFilter(name: name, jql: jql))
                    }
                    newName = ""
                    newJQL = ""
                }
                .buttonStyle(QuietButtonStyle(compact: true))
                .disabled(newName.isEmpty || newJQL.isEmpty)
            }
        }
    }
}
