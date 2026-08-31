import SwiftUI
import ChronoCore

/// SwiftUI exports its own `Settings` (the scene type), which makes a bare `Settings` ambiguous
/// anywhere both modules are imported. App code uses this name instead.
typealias TrackerSettings = ChronoCore.Settings

/// Shared visual language.
///
/// The goal is for Chrono to look like it came with the OS: system materials, SF Symbols,
/// system accent colour, and dynamic type that respects the user's settings. The only place it
/// deliberately departs from stock SwiftUI is timer text, which uses monospaced digits so
/// numbers do not jitter as they count.
enum Theme {
    static let cornerRadius: CGFloat = 10
    static let cardRadius: CGFloat = 12
    static let panelWidth: CGFloat = 400
    static let rowHeight: CGFloat = 38

    enum Spacing {
        static let tight: CGFloat = 4
        static let small: CGFloat = 8
        static let medium: CGFloat = 12
        static let large: CGFloat = 16
        static let section: CGFloat = 20
    }

    /// Colour for a tracking state, used consistently across the menu bar, panel and phone.
    static func statusColor(for status: TrackingStatus) -> Color {
        switch status {
        case .running: return .accentColor
        case .paused: return .orange
        case .idle: return .secondary
        }
    }
}

// MARK: - Timer text

/// Large, non-jittering elapsed-time display.
struct TimerText: View {
    let seconds: TimeInterval
    var size: CGFloat = 34
    var showSeconds: Bool = true

    var body: some View {
        Text(showSeconds ? DurationFormat.clock(seconds) : DurationFormat.compact(seconds))
            .font(.system(size: size, weight: .medium, design: .rounded))
            // Without this the width changes as digits change, and the whole row shuffles.
            .monospacedDigit()
            .contentTransition(.numericText())
    }
}

// MARK: - Chips

/// Small labelled pill, used for counts, warnings and metadata.
struct Chip: View {
    let text: String
    var systemImage: String?
    var tint: Color = .secondary

    var body: some View {
        HStack(spacing: 3) {
            if let systemImage {
                Image(systemName: systemImage).font(.system(size: 9, weight: .semibold))
            }
            Text(text).font(.system(size: 10, weight: .medium))
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .foregroundStyle(tint)
        .background(tint.opacity(0.12), in: Capsule())
    }
}

// MARK: - Progress

/// Day-progress ring, shown next to the daily total.
struct ProgressRing: View {
    let progress: Double
    var lineWidth: CGFloat = 4
    var tint: Color = .accentColor

    var body: some View {
        ZStack {
            Circle()
                .stroke(tint.opacity(0.15), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.001, min(1, progress)))
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.4), value: progress)
        }
    }
}

/// Horizontal day bar: work, then a hatched remainder up to the target.
struct DayProgressBar: View {
    let workSeconds: TimeInterval
    let targetSeconds: TimeInterval
    var unfiledSeconds: TimeInterval = 0

    private var workFraction: Double {
        guard targetSeconds > 0 else { return 0 }
        return min(1, workSeconds / targetSeconds)
    }

    /// Portion of the bar that is tracked but has no Jira issue behind it, drawn in a warning
    /// tint so it reads as "needs attention" rather than "done".
    private var unfiledFraction: Double {
        guard targetSeconds > 0, workSeconds > 0 else { return 0 }
        return min(workFraction, unfiledSeconds / targetSeconds)
    }

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.15))
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: width * workFraction)
                if unfiledFraction > 0 {
                    Capsule()
                        .fill(Color.orange)
                        .frame(width: width * unfiledFraction)
                }
            }
        }
        .frame(height: 6)
        .animation(.easeOut(duration: 0.4), value: workFraction)
    }
}

// MARK: - Cards

struct Card<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(Theme.Spacing.medium)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: Theme.cardRadius))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cardRadius)
                    .strokeBorder(.separator.opacity(0.6), lineWidth: 0.5)
            )
    }
}

// MARK: - Buttons

/// Filled action button, for the one primary verb in a view.
struct FilledButtonStyle: ButtonStyle {
    var tint: Color = .accentColor
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: compact ? 11 : 12, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, compact ? 10 : 14)
            .padding(.vertical, compact ? 5 : 7)
            .background(
                tint.opacity(configuration.isPressed ? 0.75 : 1),
                in: RoundedRectangle(cornerRadius: Theme.cornerRadius - 2)
            )
            .contentShape(Rectangle())
    }
}

/// Quiet button for secondary verbs; fills in on hover so it still feels clickable.
struct QuietButtonStyle: ButtonStyle {
    var tint: Color = .primary
    var compact = false
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: compact ? 11 : 12, weight: .medium))
            .foregroundStyle(tint)
            .padding(.horizontal, compact ? 8 : 12)
            .padding(.vertical, compact ? 4 : 6)
            .background(
                tint.opacity(configuration.isPressed ? 0.18 : (hovering ? 0.10 : 0.06)),
                in: RoundedRectangle(cornerRadius: Theme.cornerRadius - 2)
            )
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
    }
}

/// Icon-only button used in dense rows.
struct IconButtonStyle: ButtonStyle {
    var tint: Color = .accentColor
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: 26, height: 26)
            .background(
                tint.opacity(configuration.isPressed ? 0.24 : (hovering ? 0.14 : 0)),
                in: Circle()
            )
            .contentShape(Circle())
            .onHover { hovering = $0 }
    }
}

// MARK: - Target presentation

/// Icon for a tracking target: issue type glyph for issues, category glyph for ad-hoc time.
struct TargetIcon: View {
    let target: TrackingTarget
    var size: CGFloat = 13

    private var symbol: String {
        switch target {
        case .adhoc(let ref): return ref.category.symbolName
        case .issue(let ref):
            switch ref.issueType?.lowercased() {
            case "bug": return "ant.fill"
            case "story": return "bookmark.fill"
            case "epic": return "bolt.horizontal.fill"
            case "sub-task", "subtask": return "arrow.turn.down.right"
            case "task": return "checkmark.square.fill"
            default: return "square.stack.3d.up.fill"
            }
        }
    }

    private var tint: Color {
        switch target {
        case .adhoc(let ref): return ref.category == .breakTime ? .green : .orange
        case .issue(let ref):
            switch ref.issueType?.lowercased() {
            case "bug": return .red
            case "story": return .green
            case "epic": return .purple
            default: return .blue
            }
        }
    }

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size))
            .foregroundStyle(tint)
            .frame(width: size + 4)
    }
}

// MARK: - Empty states

struct EmptyStateView: View {
    let systemImage: String
    let title: String
    var message: String?

    var body: some View {
        VStack(spacing: Theme.Spacing.small) {
            Image(systemName: systemImage)
                .font(.system(size: 22))
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            if let message {
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Theme.Spacing.section)
    }
}

// MARK: - Section header

struct SectionHeader: View {
    let title: String
    var trailing: String?

    var body: some View {
        HStack {
            Text(title.uppercased())
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(.tertiary)
                .tracking(0.6)
            Spacer()
            if let trailing {
                Text(trailing)
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(.tertiary)
            }
        }
    }
}
