import SwiftUI
import ChronoCore

/// The week in review: a short list of things that were not already obvious.
///
/// Deliberately **not** a dashboard, which is the risk #12 named. There are no tiles, no
/// sparklines and no metrics that read zero. Each finding decides for itself whether it has
/// anything to say, so an unremarkable week collapses to a single line and takes no space —
/// and the section a person sees in a busy week is short enough to actually read.
///
/// Everything shown here comes from `WeekInsights` in ChronoCore, so the thresholds and the
/// wording are covered by tests rather than living in a view.
struct WeekReviewSection: View {
    let day: Date
    @Environment(AppEnvironment.self) private var environment

    private var insights: [WeekInsight] {
        let engine = environment.engine
        let week = WeekRollup.build(
            segments: engine.state.allSegments(),
            weekContaining: day,
            asOf: Date()
        )
        return WeekInsights.build(
            for: week,
            targetHours: engine.settings.dailyTargetHours,
            workdays: engine.settings.workdays,
            asOf: Date()
        )
    }

    var body: some View {
        let findings = insights
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            SectionHeader(title: "This week")

            if findings.isEmpty {
                // Said once, plainly, rather than five boxes containing zero.
                Text("Nothing stands out this week.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(findings) { insight in
                    InsightRow(insight: insight)
                }
            }
        }
    }
}

private struct InsightRow: View {
    let insight: WeekInsight

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.small) {
            Image(systemName: symbol)
                .font(.system(size: 11))
                .foregroundStyle(insight.tone == .attention ? Color.orange : Color.secondary)
                .frame(width: 14)

            VStack(alignment: .leading, spacing: 1) {
                Text(insight.headline)
                    .font(.system(size: 11.5, weight: .medium))
                    .fixedSize(horizontal: false, vertical: true)
                Text(insight.detail)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Spacing.small)
        .padding(.vertical, 5)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 6))
    }

    private var symbol: String {
        switch insight.kind {
        case .concentration: return "chart.pie"
        case .unticketed: return "tag.slash"
        case .fragmentation: return "arrow.triangle.branch"
        case .unaccounted: return "questionmark.circle"
        case .target: return "target"
        }
    }
}
