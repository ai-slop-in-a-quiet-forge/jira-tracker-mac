import EventKit
import Foundation
import Observation
import ChronoCore

/// Reads the local calendar so meeting time can be labelled with the meeting.
///
/// ## Google, Exchange and iCloud are all the same thing here
///
/// There is no Google Calendar integration in Chrono and there does not need to be. A Google
/// account added in System Settings ▸ Internet Accounts with Calendars enabled is synced by
/// macOS, and EventKit then serves those events exactly like an iCloud or local one. Talking to
/// Google directly would mean an OAuth client secret shipped inside the app, a consent screen,
/// and Chrono making network calls to a third party — which contradicts the promise in Settings
/// ▸ About that the only network calls it makes are to your own Jira site.
///
/// So this reads whatever macOS already has. The Settings panel lists the account each calendar
/// belongs to, so it is visible rather than merely true that Google calendars are included.
///
/// ## The first permission Chrono has ever asked for
///
/// Every other sensor is permission-free, deliberately. This one cannot be: there is no way to
/// read a calendar without being allowed to. So it is off until switched on, the prompt appears
/// only at that moment, and the app is fully functional without it.
///
/// EventKit offers exactly two requests, and neither is read-only:
/// `requestWriteOnlyAccessToEvents` (the opposite of what is needed) and
/// `requestFullAccessToEvents`. **Reading requires full access**, so that is what is asked for.
/// The restriction to reading is therefore Chrono's own, enforced by this file being the only
/// place that touches `EKEventStore` and never calling a mutating method on it — not something
/// macOS is enforcing on Chrono's behalf. Worth being precise about rather than claiming a
/// guarantee the system is not making.
@MainActor
@Observable
final class CalendarSensor {

    enum Access: Equatable {
        case notDetermined
        case denied
        case restricted
        case granted
        /// Granted, but only for writing — useless here, and worth saying so rather than looking
        /// broken.
        case writeOnly

        var isUsable: Bool { self == .granted }
    }

    struct CalendarInfo: Identifiable, Equatable, Hashable {
        let id: String
        let title: String
        /// iCloud, a Google address, an Exchange server — whatever macOS calls the source.
        let accountName: String
    }

    private(set) var access: Access = .notDetermined
    /// Events overlapping the window last refreshed, reduced to title and time.
    private(set) var events: [CalendarEvent] = []
    private(set) var availableCalendars: [CalendarInfo] = []
    private(set) var lastError: String?

    /// Created lazily: constructing an `EKEventStore` is what makes the app show up in the
    /// Calendars privacy list, so an install that never enables this never appears there.
    private var store: EKEventStore?

    // MARK: - Access

    func refreshAccessStatus() {
        access = Self.map(EKEventStore.authorizationStatus(for: .event))
    }

    /// Asks for read access, showing the system prompt the first time.
    @discardableResult
    func requestAccess() async -> Bool {
        let store = ensureStore()
        do {
            // Full access is the only request that permits reading; see the type's note. Chrono
            // never calls a mutating EventKit method, but the grant itself does allow writing.
            let granted = try await store.requestFullAccessToEvents()
            refreshAccessStatus()
            lastError = granted ? nil : "Chrono was not given access to your calendars."
            return granted
        } catch {
            refreshAccessStatus()
            lastError = error.localizedDescription
            return false
        }
    }

    // MARK: - Reading

    /// Reloads the calendar list. Cheap, and the set changes when an account is added.
    func refreshCalendars() {
        guard access.isUsable else {
            availableCalendars = []
            return
        }
        let store = ensureStore()
        availableCalendars = store.calendars(for: .event)
            .map {
                CalendarInfo(
                    id: $0.calendarIdentifier,
                    title: $0.title,
                    accountName: $0.source?.title ?? "Unknown account"
                )
            }
            .sorted { ($0.accountName, $0.title) < ($1.accountName, $1.title) }
    }

    /// Loads events between `start` and `end`, restricted to `identifiers` when non-empty.
    ///
    /// The EventKit objects never leave this method: each is reduced to a `CalendarEvent`
    /// carrying only title, times and which calendar it came from. Attendees, notes, location
    /// and organiser are dropped here, so nothing downstream can accidentally use them.
    func refreshEvents(from start: Date, to end: Date, identifiers: [String]) {
        guard access.isUsable else {
            events = []
            return
        }
        let store = ensureStore()

        let wanted: [EKCalendar]?
        if identifiers.isEmpty {
            wanted = nil   // nil means every calendar, which is EventKit's own default
        } else {
            let selected = store.calendars(for: .event)
                .filter { identifiers.contains($0.calendarIdentifier) }
            // An empty selection would otherwise be read as "all calendars", which is the
            // opposite of what an empty selection means to the person who made it.
            guard !selected.isEmpty else {
                events = []
                return
            }
            wanted = selected
        }

        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: wanted)
        events = store.events(matching: predicate).map { event in
            CalendarEvent(
                id: event.eventIdentifier ?? UUID().uuidString,
                title: event.title ?? "Untitled event",
                start: event.startDate,
                end: event.endDate,
                calendarTitle: event.calendar?.title ?? "Calendar",
                accountName: event.calendar?.source?.title ?? "Unknown account",
                isAllDay: event.isAllDay
            )
        }
    }

    // MARK: - Internals

    private func ensureStore() -> EKEventStore {
        if let store { return store }
        let created = EKEventStore()
        store = created
        return created
    }

    private static func map(_ status: EKAuthorizationStatus) -> Access {
        switch status {
        case .notDetermined: return .notDetermined
        case .restricted: return .restricted
        case .denied: return .denied
        case .fullAccess: return .granted
        case .writeOnly: return .writeOnly
        // `.authorized` is the pre-macOS 14 spelling of full access.
        case .authorized: return .granted
        @unknown default: return .notDetermined
        }
    }
}
