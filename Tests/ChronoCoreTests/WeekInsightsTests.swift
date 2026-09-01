import Foundation
import Testing
@testable import ChronoCore

@Suite("Week insights")
struct WeekInsightsTests {

    /// Monday 2026-03-09 09:00, so a week runs Sun 8th – Sat 14th under a US calendar.
    private var monday: Date {
        var components = DateComponents()
        components.year = 2026
        components.month = 3
        components.day = 9
        components.hour = 9
        return Calendar.current.date(from: components)!
    }

    private let allWeekdays: Set<Int> = [1, 2, 3, 4, 5, 6, 7]

    private func week(_ segments: [WorkSegment], asOf: Date? = nil) -> WeekRollup {
        WeekRollup.build(
            segments: segments,
            weekContaining: monday,
            asOf: asOf ?? monday.addingTimeInterval(6 * 86_400)
        )
    }

    private func build(_ segments: [WorkSegment], targetHours: Double = 0) -> [WeekInsight] {
        WeekInsights.build(
            for: week(segments),
            targetHours: targetHours,
            workdays: allWeekdays,
            asOf: monday.addingTimeInterval(6 * 86_400)
        )
    }

    private func kinds(_ insights: [WeekInsight]) -> [WeekInsight.Kind] { insights.map(\.kind) }

    // MARK: - The empty case, which is the point of the design

    @Test("A week with nothing tracked says nothing at all")
    func emptyWeek() {
        #expect(build([]).isEmpty)
    }

    @Test("An unremarkable week produces no findings rather than empty tiles")
    func quietWeek() {
        // One issue, one day, no switching, nothing unticketed, no target set. A dashboard would
        // render five zeroes here; this should stay silent.
        let segments = [Fixture.segment(Fixture.issue("CYM-1"), from: monday, minutes: 60)]
        let insights = build(segments)
        #expect(kinds(insights).contains(.fragmentation) == false)
        #expect(kinds(insights).contains(.unticketed) == false)
        #expect(kinds(insights).contains(.unaccounted) == false)
        #expect(kinds(insights).contains(.target) == false)
    }

    // MARK: - Concentration

    @Test("A dominant issue is reported with its share")
    func concentration() {
        let segments = [
            Fixture.segment(Fixture.issue("CYM-1"), from: monday, minutes: 300),
            Fixture.segment(Fixture.issue("CYM-2"), from: monday.addingTimeInterval(21_600), minutes: 60),
        ]
        let insight = build(segments).first { $0.kind == .concentration }
        #expect(insight != nil)
        #expect(insight?.detail.contains("83%") == true)
    }

    @Test("Time on one issue is summed across days before being compared")
    func concentrationAcrossDays() {
        // Per-day totals would each be a fifth of the week and never clear the threshold.
        let segments = (0..<5).map { day in
            Fixture.segment(
                Fixture.issue("CYM-1"),
                from: monday.addingTimeInterval(Double(day) * 86_400),
                minutes: 120
            )
        }
        let insight = build(segments).first { $0.kind == .concentration }
        #expect(insight?.detail.contains("100%") == true)
        #expect(insight?.headline.contains("10h") == true)
    }

    @Test("An evenly spread week reports no concentration")
    func noConcentration() {
        let segments = (0..<5).map { index in
            Fixture.segment(
                Fixture.issue("CYM-\(index)"),
                from: monday.addingTimeInterval(Double(index) * 7_200),
                minutes: 60
            )
        }
        #expect(kinds(build(segments)).contains(.concentration) == false)
    }

    // MARK: - Unticketed

    @Test("Ad-hoc time with no issue is flagged")
    func unticketed() {
        let segments = [
            Fixture.segment(Fixture.issue("CYM-1"), from: monday, minutes: 240),
            Fixture.segment(Fixture.adhoc(.meeting), from: monday.addingTimeInterval(18_000), minutes: 120),
        ]
        let insight = build(segments).first { $0.kind == .unticketed }
        #expect(insight?.tone == .attention)
        #expect(insight?.headline.contains("2h") == true)
    }

    @Test("A trivial amount of unticketed time is not worth a line")
    func smallUnticketedIgnored() {
        let segments = [
            Fixture.segment(Fixture.issue("CYM-1"), from: monday, minutes: 480),
            Fixture.segment(Fixture.adhoc(.interruption), from: monday.addingTimeInterval(30_000), minutes: 5),
        ]
        #expect(kinds(build(segments)).contains(.unticketed) == false)
    }

    // MARK: - Fragmentation

    @Test("The most fragmented day is named, not an average")
    func fragmentation() {
        // An average would spread one chaotic day across five until it looked like nothing.
        var segments: [WorkSegment] = []
        for index in 0..<10 {
            segments.append(
                Fixture.segment(
                    Fixture.issue("CYM-\(index)"),
                    from: monday.addingTimeInterval(Double(index) * 1_800),
                    minutes: 25
                )
            )
        }
        let insight = build(segments).first { $0.kind == .fragmentation }
        #expect(insight != nil)
        // Nine, not ten: `contextSwitches` counts transitions between targets.
        #expect(insight?.detail.contains("9 changes of task") == true)
        #expect(insight?.tone == .attention)
    }

    @Test("Ordinary switching is not reported")
    func lowFragmentationIgnored() {
        let segments = (0..<3).map { index in
            Fixture.segment(
                Fixture.issue("CYM-\(index)"),
                from: monday.addingTimeInterval(Double(index) * 3_600),
                minutes: 50
            )
        }
        #expect(kinds(build(segments)).contains(.fragmentation) == false)
    }

    // MARK: - Unaccounted

    @Test("A long gap inside the working day is reported")
    func unaccounted() {
        // First activity 09:00, last ends 18:00, but only two hours tracked.
        let segments = [
            Fixture.segment(Fixture.issue("CYM-1"), from: monday, minutes: 60),
            Fixture.segment(Fixture.issue("CYM-1"), from: monday.addingTimeInterval(28_800), minutes: 60),
        ]
        let insight = build(segments).first { $0.kind == .unaccounted }
        #expect(insight != nil)
        #expect(insight?.headline.contains("unaccounted for") == true)
    }

    @Test("A tightly tracked day reports no gap")
    func noGap() {
        let segments = [Fixture.segment(Fixture.issue("CYM-1"), from: monday, minutes: 120)]
        #expect(kinds(build(segments)).contains(.unaccounted) == false)
    }

    // MARK: - Target

    @Test("A shortfall against the target is flagged with attention")
    func underTarget() {
        let segments = [Fixture.segment(Fixture.issue("CYM-1"), from: monday, minutes: 120)]
        let insight = WeekInsights.build(
            for: week(segments),
            targetHours: 8,
            workdays: [2],          // Monday only, so one working day of 8h expected
            asOf: monday.addingTimeInterval(6 * 86_400)
        ).first { $0.kind == .target }
        #expect(insight?.tone == .attention)
        #expect(insight?.headline.contains("under target") == true)
        #expect(insight?.detail.contains("1 working day") == true)
    }

    @Test("Working over the target is reported neutrally, not as a problem")
    func overTarget() {
        let segments = [Fixture.segment(Fixture.issue("CYM-1"), from: monday, minutes: 600)]
        let insight = WeekInsights.build(
            for: week(segments),
            targetHours: 8,
            workdays: [2],
            asOf: monday.addingTimeInterval(6 * 86_400)
        ).first { $0.kind == .target }
        #expect(insight?.tone == .neutral)
        #expect(insight?.headline.contains("over target") == true)
    }

    @Test("Days that have not happened yet do not count as a shortfall")
    func futureDaysExcluded() {
        // Otherwise every Monday morning reports being 32 hours behind. Uses the app's default
        // Mon–Fri, so the weekend is out of scope regardless.
        let monToFri: Set<Int> = [2, 3, 4, 5, 6]
        let segments = [Fixture.segment(Fixture.issue("CYM-1"), from: monday, minutes: 480)]
        let insight = WeekInsights.build(
            for: week(segments, asOf: monday.addingTimeInterval(3_600)),
            targetHours: 8,
            workdays: monToFri,
            asOf: monday.addingTimeInterval(3_600)
        ).first { $0.kind == .target }
        // Only Monday counts, and it hit its 8 hours, so there is nothing to say.
        #expect(insight == nil)
    }

    @Test("A past working day with nothing tracked does count against the target")
    func pastEmptyDayCounts() {
        // The other side of the same rule: Monday is over and empty, so Tuesday should say so.
        let monToFri: Set<Int> = [2, 3, 4, 5, 6]
        let tuesday = monday.addingTimeInterval(86_400)
        let segments = [Fixture.segment(Fixture.issue("CYM-1"), from: tuesday, minutes: 480)]
        let insight = WeekInsights.build(
            for: week(segments, asOf: tuesday.addingTimeInterval(3_600)),
            targetHours: 8,
            workdays: monToFri,
            asOf: tuesday.addingTimeInterval(3_600)
        ).first { $0.kind == .target }
        #expect(insight?.headline.contains("under target") == true)
        #expect(insight?.detail.contains("2 working days") == true)
    }

    @Test("No target configured means no target line")
    func noTarget() {
        let segments = [Fixture.segment(Fixture.issue("CYM-1"), from: monday, minutes: 120)]
        #expect(kinds(build(segments, targetHours: 0)).contains(.target) == false)
    }

    // MARK: - Shape

    @Test("Findings are stable and identifiable")
    func identifiable() {
        let segments = [
            Fixture.segment(Fixture.issue("CYM-1"), from: monday, minutes: 300),
            Fixture.segment(Fixture.adhoc(.meeting), from: monday.addingTimeInterval(21_600), minutes: 120),
        ]
        let first = build(segments)
        let second = build(segments)
        #expect(first == second)
        #expect(Set(first.map(\.id)).count == first.count, "ids must be unique")
    }
}
