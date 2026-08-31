import SwiftUI
import AppKit
import ChronoCore

/// Settings window, split into tabs so nothing is more than one scroll from the top.
struct SettingsView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var tab: Tab = .jira

    enum Tab: String, CaseIterable, Identifiable {
        case jira, tracking, interruptions, phone, advanced
        var id: String { rawValue }

        var title: String {
            switch self {
            case .jira: return "Jira"
            case .tracking: return "Tracking"
            case .interruptions: return "Interruptions"
            case .phone: return "Phone"
            case .advanced: return "Advanced"
            }
        }

        var symbol: String {
            switch self {
            case .jira: return "link"
            case .tracking: return "clock"
            case .interruptions: return "bell.badge"
            case .phone: return "iphone"
            case .advanced: return "slider.horizontal.3"
            }
        }
    }

    var body: some View {
        TabView(selection: $tab) {
            ForEach(Tab.allCases) { item in
                ScrollView {
                    content(for: item)
                        .padding(Theme.Spacing.section)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .tabItem { Label(item.title, systemImage: item.symbol) }
                .tag(item)
            }
        }
        .frame(width: 620, height: 620)
    }

    @ViewBuilder
    private func content(for tab: Tab) -> some View {
        switch tab {
        case .jira: JiraSettingsTab()
        case .tracking: TrackingSettingsTab()
        case .interruptions: InterruptionSettingsTab()
        case .phone: PhoneSettingsTab()
        case .advanced: AdvancedSettingsTab()
        }
    }
}

// MARK: - Building blocks

/// A titled group of controls, with consistent spacing.
struct SettingsGroup<Content: View>: View {
    let title: String
    var footnote: String?
    @ViewBuilder var content: Content

    init(_ title: String, footnote: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.footnote = footnote
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
            VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                content
            }
            .padding(Theme.Spacing.medium)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: Theme.cardRadius))
            if let footnote {
                Text(footnote)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Reads and writes a single settings field, persisting on every change.
///
/// `Binding`'s accessors are `@Sendable`, while the settings live on the main actor. SwiftUI only
/// ever invokes them on the main thread, so `assumeIsolated` states that fact rather than
/// papering over the warning — and keeps every settings control a one-liner.
@MainActor
struct SettingsBinding {
    let environment: AppEnvironment

    func bind<Value: Sendable>(_ keyPath: WritableKeyPath<TrackerSettings, Value>) -> Binding<Value> {
        let environment = self.environment
        return Binding(
            get: { MainActor.assumeIsolated { environment.engine.settings[keyPath: keyPath] } },
            set: { newValue in
                MainActor.assumeIsolated {
                    environment.mutateSettings { $0[keyPath: keyPath] = newValue }
                }
            }
        )
    }
}

extension View {
    /// Convenience for the very common "label on the left, control on the right" row.
    func settingsRow(_ label: String, help: String? = nil) -> some View {
        HStack {
            Text(label).font(.system(size: 11.5))
            Spacer()
            self
        }
        .help(help ?? "")
    }
}

struct DailyTargetField: View {
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        let binding = SettingsBinding(environment: environment).bind(\.dailyTargetHours)
        HStack {
            Text("Hours per day").font(.system(size: 11.5))
            Spacer()
            Stepper(
                value: binding,
                in: 1...16,
                step: 0.5
            ) {
                Text(String(format: "%.1f h", binding.wrappedValue))
                    .font(.system(size: 11.5))
                    .monospacedDigit()
                    .frame(width: 50, alignment: .trailing)
            }
            .labelsHidden()
        }
    }
}

// MARK: - Jira connection form

/// Shared by onboarding and the Jira settings tab.
struct JiraConnectionForm: View {
    var showsSkip = false
    var onDone: (() -> Void)?

    @Environment(AppEnvironment.self) private var environment
    @State private var site = ""
    @State private var email = ""
    @State private var token = ""
    @State private var onePasswordRef = ""
    @State private var useOnePassword = false
    @State private var isWorking = false
    @State private var revealToken = false
    @State private var message: String?
    @State private var messageIsError = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.large) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Connect to Jira Cloud")
                    .font(.system(size: 18, weight: .semibold))
                Text("Chrono talks to Jira directly from this Mac using a personal API token. There is no Chrono server and no account to create.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if case .connected(let user) = environment.connection.state, !isWorking {
                connectedCard(user)
            } else {
                form
            }

            if let message {
                Label(message, systemImage: messageIsError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(messageIsError ? .red : .green)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(showsSkip ? Theme.Spacing.section : 0)
        .onAppear {
            site = environment.engine.settings.siteURL
            email = environment.engine.settings.accountEmail
            onePasswordRef = environment.engine.settings.onePasswordTokenRef ?? ""
            useOnePassword = !onePasswordRef.isEmpty
        }
    }

    private func connectedCard(_ user: JiraUser) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            Card {
                HStack(spacing: Theme.Spacing.medium) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(.green)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(user.displayName).font(.system(size: 12.5, weight: .semibold))
                        Text(environment.engine.settings.siteURL)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Text(environment.connection.tokenSource.description)
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                }
            }
            HStack {
                Button("Re-check") {
                    Task { await environment.connection.verify() }
                }
                .buttonStyle(QuietButtonStyle())

                Button("Disconnect") {
                    environment.mutateSettings { settings in
                        environment.connection.disconnect(settings: &settings)
                    }
                    message = "Disconnected. Local history is untouched."
                    messageIsError = false
                }
                .buttonStyle(QuietButtonStyle(tint: .red))

                Spacer()
                if let onDone {
                    Button("Continue") { onDone() }
                        .buttonStyle(FilledButtonStyle())
                }
            }
        }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            LabeledField(
                label: "Jira site",
                placeholder: "your-company.atlassian.net",
                text: $site
            )
            .onChange(of: site) { _, value in
                environment.mutateSettings { $0.siteURL = value }
            }

            LabeledField(
                label: "Your Jira email",
                placeholder: "you@company.com",
                text: $email
            )
            .onChange(of: email) { _, value in
                environment.mutateSettings { $0.accountEmail = value }
            }

            Picker("", selection: $useOnePassword) {
                Text("Paste an API token").tag(false)
                Text("Read it from 1Password").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(!OnePassword.isAvailable && !useOnePassword)

            if useOnePassword {
                LabeledField(
                    label: "1Password reference",
                    placeholder: "op://Private/Jira API Token/credential",
                    text: $onePasswordRef
                )
                Text(OnePassword.isAvailable
                     ? "Chrono runs `op read` at launch, so the token is never copied into a file on disk."
                     : "The 1Password CLI (op) was not found. Install it, or paste a token instead.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(OnePassword.isAvailable ? Color.secondary : Color.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("API token").font(.system(size: 11, weight: .medium))
                        Spacer()
                        Button("Paste") {
                            if let clipboard = NSPasteboard.general.string(forType: .string) {
                                token = clipboard.trimmingCharacters(in: .whitespacesAndNewlines)
                            }
                        }
                        .buttonStyle(QuietButtonStyle(compact: true))
                        .help("Paste the token from the clipboard")
                    }
                    if revealToken {
                        TextField("Paste the token from id.atlassian.com", text: $token)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 11.5, design: .monospaced))
                    } else {
                        SecureField("Paste the token from id.atlassian.com", text: $token)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 11.5))
                    }
                    HStack {
                        Toggle("Show token", isOn: $revealToken)
                            .font(.system(size: 10.5))
                            .toggleStyle(.checkbox)
                        Spacer()
                    }
                    Button("Create an API token in your browser…") {
                        if let url = URL(string: "https://id.atlassian.com/manage-profile/security/api-tokens") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .buttonStyle(.link)
                    .font(.system(size: 10.5))
                }
            }

            HStack {
                Button(isWorking ? "Checking…" : "Connect") { connect() }
                    .buttonStyle(FilledButtonStyle())
                    .disabled(isWorking || site.isEmpty || email.isEmpty)

                if showsSkip {
                    Button("Skip for now") { onDone?() }
                        .buttonStyle(QuietButtonStyle())
                        .help("You can still track ad-hoc time and connect Jira later")
                }
                Spacer()
                if isWorking { ProgressView().controlSize(.small) }
            }
        }
    }

    private func connect() {
        isWorking = true
        message = nil
        Task {
            var settings = environment.engine.settings
            let result: Result<JiraUser, JiraError>
            if useOnePassword {
                result = await environment.connection.useOnePassword(
                    reference: onePasswordRef, site: site, email: email, settings: &settings
                )
            } else {
                result = await environment.connection.connect(
                    site: site, email: email, token: token, settings: &settings
                )
            }
            environment.engine.update(settings: settings)

            switch result {
            case .success(let user):
                messageIsError = false
                message = "Connected as \(user.displayName)."
                token = ""
                await environment.connectToJira()
                onDone?()
            case .failure(let error):
                messageIsError = true
                message = error.errorDescription
            }
            isWorking = false
        }
    }
}

struct LabeledField: View {
    let label: String
    let placeholder: String
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 11, weight: .medium))
            TextField(placeholder, text: $text)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11.5))
                .autocorrectionDisabled()
        }
    }
}
