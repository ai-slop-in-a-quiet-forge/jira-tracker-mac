import SwiftUI
import AppKit
import ChronoCore

/// Data, export, and the escape hatches.
///
/// Every time tracker should be able to hand your data back and show you where it lives. This
/// tab exists so nobody has to take Chrono's word for anything.
struct AdvancedSettingsTab: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var exportMessage: String?

    private var engine: TrackingEngine { environment.engine }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.section) {
            SettingsGroup(
                "Where your data lives",
                footnote: "Plain JSON, on this Mac only. Nothing is uploaded anywhere except the worklogs you send to Jira."
            ) {
                HStack {
                    Text(engine.storageDirectory?.path ?? "Unavailable")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                    Spacer()
                    Button("Reveal") {
                        guard let url = engine.storageDirectory else { return }
                        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: url.path)
                    }
                    .buttonStyle(QuietButtonStyle(compact: true))
                }

                Divider()
                summaryRow("Stored entries", "\(engine.state.segments.count)")
                summaryRow("Queued worklogs", "\(engine.state.pendingDrafts.count)")
                summaryRow(
                    "Tracked this week",
                    DurationFormat.humane(
                        WeekRollup.build(
                            segments: engine.state.allSegments(),
                            weekContaining: Date(),
                            asOf: Date()
                        ).workSeconds
                    )
                )
            }

            SettingsGroup(
                "Export",
                footnote: "CSV with ISO 8601 timestamps and RFC 4180 quoting, so a summary containing a comma cannot corrupt the file."
            ) {
                HStack(spacing: Theme.Spacing.small) {
                    Button("Export every entry…") { export(.segments) }
                        .buttonStyle(FilledButtonStyle(compact: true))
                    Button("Export daily totals…") { export(.dailyTotals) }
                        .buttonStyle(QuietButtonStyle(compact: true))
                    Button("Export for Tempo…") { export(.tempo) }
                        .buttonStyle(QuietButtonStyle(compact: true))
                        .help("One row per issue per day, in the columns Tempo's worklog importer reads")
                }
                if let exportMessage {
                    Text(exportMessage)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
            }

            SettingsGroup(
                "Housekeeping",
                footnote: "Entries older than 45 days move into monthly archive files automatically, so the file Chrono writes every few seconds stays small."
            ) {
                Button("Forget submitted worklogs older than 30 days") {
                    engine.pruneDrafts(olderThan: 30)
                    environment.show(.init(kind: .info, message: "Old worklog records cleared."))
                }
                .buttonStyle(QuietButtonStyle(compact: true))
            }

            SettingsGroup("About") {
                summaryRow("Version", Bundle.main.shortVersion)
                summaryRow("Jira API", "Cloud REST v3")
                summaryRow("Remote protocol", "v\(ChronoRemote.protocolVersion)")
                Divider()
                Text("Chrono runs entirely on this Mac. There is no Chrono account, no telemetry and no server — the only network calls it makes are to your own Jira site.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func summaryRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.system(size: 11, weight: .medium)).monospacedDigit()
        }
    }

    private enum ExportKind {
        case segments, dailyTotals, tempo

        var filenameStem: String {
            switch self {
            case .segments: return "chrono-entries"
            case .dailyTotals: return "chrono-daily"
            case .tempo: return "chrono-tempo"
            }
        }
    }

    private func export(_ kind: ExportKind) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        let stamp = Export.filenameDateFormatter.string(from: Date())
        panel.nameFieldStringValue = "\(kind.filenameStem)-\(stamp).csv"
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let url = panel.url else { return }

        let segments = engine.state.allSegments()
        let csv: String
        // Anything the export could not represent, said plainly rather than left to be noticed
        // in the imported timesheet.
        var caveat: String?

        switch kind {
        case .segments:
            csv = Export.segmentsCSV(segments, drafts: engine.state.drafts)
        case .dailyTotals:
            csv = Export.dailyTotalsCSV(segments, asOf: Date())
        case .tempo:
            let result = TempoExport.csv(
                segments,
                workerAccountID: engine.state.jiraAccountID,
                asOf: Date()
            )
            csv = result.csv
            if result.hasSkipped {
                let what = result.skippedLabels.joined(separator: ", ")
                caveat = " \(DurationFormat.humane(result.skippedSeconds)) of time without an issue "
                    + "(\(what)) was left out — Tempo logs against a Jira issue."
            } else if engine.state.jiraAccountID == nil {
                caveat = " The Worker column is empty because Chrono has not connected to Jira yet;"
                    + " Tempo will reject the file until it is filled in."
            }
        }

        do {
            try Data(csv.utf8).write(to: url, options: .atomic)
            exportMessage = "Saved to \(url.lastPathComponent)." + (caveat ?? "")
        } catch {
            exportMessage = "Could not save: \(error.localizedDescription)"
        }
    }
}

extension Bundle {
    var shortVersion: String {
        let version = infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        let build = infoDictionary?["CFBundleVersion"] as? String
        return build.map { "\(version) (\($0))" } ?? version
    }
}
