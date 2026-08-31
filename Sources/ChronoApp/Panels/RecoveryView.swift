import SwiftUI
import ChronoCore

/// Shown at launch when the previous run ended with a timer still going.
///
/// The important design choice is that Chrono refuses to guess. It knows exactly how long the
/// timer was *demonstrably* running — up to the last heartbeat — and presents the gap between
/// that and now as unknown rather than quietly billing it.
struct RecoveryView: View {
    @Environment(AppEnvironment.self) private var environment

    private var proposal: RecoveryProposal? { environment.engine.pendingRecovery }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.large) {
            if let proposal {
                header(proposal)
                breakdown(proposal)
                actions(proposal)
            } else {
                EmptyStateView(
                    systemImage: "checkmark.circle",
                    title: "Nothing to recover",
                    message: "This session was already resolved."
                )
                Button("Close") { WindowManager.shared.close(.recovery) }
                    .buttonStyle(FilledButtonStyle())
            }
        }
        .padding(Theme.Spacing.section)
        .frame(width: 480, alignment: .leading)
    }

    private func header(_ proposal: RecoveryProposal) -> some View {
        HStack(alignment: .top, spacing: Theme.Spacing.medium) {
            Image(systemName: "clock.badge.exclamationmark.fill")
                .font(.system(size: 26))
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text("Chrono was tracking when it last closed")
                    .font(.system(size: 14, weight: .semibold))
                Text("It looks like the app quit or the Mac restarted without the timer being stopped.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func breakdown(_ proposal: RecoveryProposal) -> some View {
        Card {
            VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                HStack(spacing: Theme.Spacing.small) {
                    TargetIcon(target: proposal.target)
                    Text(proposal.target.displayLabel)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(2)
                }
                Divider()
                row(
                    "Started",
                    proposal.start.formatted(date: .abbreviated, time: .shortened)
                )
                row(
                    "Last confirmed active",
                    proposal.lastKnownActive.formatted(date: .abbreviated, time: .shortened)
                )
                row(
                    "Time we can vouch for",
                    DurationFormat.humane(proposal.confidentSeconds),
                    tint: .primary,
                    bold: true
                )
                row(
                    "Unknown since then",
                    DurationFormat.humane(proposal.unknownSeconds),
                    tint: .orange
                )
            }
        }
    }

    private func row(_ label: String, _ value: String, tint: Color = .secondary, bold: Bool = false) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.system(size: 11, weight: bold ? .semibold : .regular))
                .monospacedDigit()
                .foregroundStyle(tint)
        }
    }

    private func actions(_ proposal: RecoveryProposal) -> some View {
        VStack(spacing: Theme.Spacing.small) {
            Button {
                environment.engine.resolveRecovery(.keepUntilLastActivity)
                finish()
            } label: {
                Text("Log \(DurationFormat.humane(proposal.confidentSeconds)) and stop")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(FilledButtonStyle())

            HStack(spacing: Theme.Spacing.small) {
                Button {
                    environment.engine.resolveRecovery(.keepAndContinue)
                    finish()
                } label: {
                    Text("Log it and carry on").frame(maxWidth: .infinity)
                }
                .buttonStyle(QuietButtonStyle())

                Button {
                    environment.engine.resolveRecovery(.discard)
                    finish()
                } label: {
                    Text("Discard it").frame(maxWidth: .infinity)
                }
                .buttonStyle(QuietButtonStyle(tint: .red))
            }
        }
    }

    private func finish() {
        environment.sync.syncIfNeeded()
        WindowManager.shared.close(.recovery)
    }
}
