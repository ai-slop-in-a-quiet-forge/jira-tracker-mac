import Foundation
import Testing
@testable import ChronoCore

@Suite("Menu bar clock")
struct MenuBarTimeTests {

    private let session: TimeInterval = 4_521      // 1:15:21
    private let day: TimeInterval = 20_400         // 5:40:00

    @Test("Each mode shows the clock it promises")
    func modes() {
        #expect(MenuBarTime.title(for: .session, session: session, dayTotal: day, showSeconds: false) == "1:15")
        #expect(MenuBarTime.title(for: .dayTotal, session: session, dayTotal: day, showSeconds: false) == "5:40")
        #expect(MenuBarTime.title(for: .both, session: session, dayTotal: day, showSeconds: false) == "1:15 · 5:40")
    }

    @Test("Seconds apply to the session clock only")
    func secondsAreSessionOnly() {
        // A day total ticking its seconds column is noise, and it would double how often the
        // menu bar reflows.
        #expect(MenuBarTime.title(for: .session, session: session, dayTotal: day, showSeconds: true) == "1:15:21")
        #expect(MenuBarTime.title(for: .dayTotal, session: session, dayTotal: day, showSeconds: true) == "5:40")
        #expect(MenuBarTime.title(for: .both, session: session, dayTotal: day, showSeconds: true) == "1:15:21 · 5:40")
    }

    @Test("Width is stable as seconds tick, in every mode")
    func widthIsStableWithinAnHour() {
        // The guarantee `compactFormatIsStable` makes for the old format has to hold for the
        // new ones too, or the menu bar shuffles sideways once a second.
        for mode in MenuBarTime.allCases {
            let widths = Set((0..<60).map { offset in
                MenuBarTime.title(
                    for: mode,
                    session: 3_600 + Double(offset),
                    dayTotal: 20_400 + Double(offset),
                    showSeconds: false
                ).count
            })
            #expect(widths.count == 1, "\(mode) changes width as seconds pass")
        }
    }

    @Test("Showing seconds still keeps a fixed width within a minute")
    func secondsWidthIsStable() {
        let widths = Set((0..<60).map { offset in
            MenuBarTime.title(
                for: .both,
                session: 3_600 + Double(offset),
                dayTotal: 20_400,
                showSeconds: true
            ).count
        })
        #expect(widths.count == 1)
    }

    @Test("Zero is rendered, not blanked")
    func zero() {
        // The caller decides whether to show anything at all; idle is handled before this point.
        #expect(MenuBarTime.title(for: .dayTotal, session: 0, dayTotal: 0, showSeconds: false) == "0:00")
    }

    @Test("Round trips through Codable so the setting survives a relaunch")
    func codable() throws {
        for mode in MenuBarTime.allCases {
            let data = try JSONEncoder().encode(mode)
            #expect(try JSONDecoder().decode(MenuBarTime.self, from: data) == mode)
        }
    }

    @Test("Defaults to the long-standing behaviour")
    func defaultIsSession() {
        #expect(Settings().menuBarTime == .session)
    }
}
