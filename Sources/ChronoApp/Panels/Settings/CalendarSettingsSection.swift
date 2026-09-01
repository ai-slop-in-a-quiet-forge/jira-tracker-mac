import SwiftUI
import ChronoCore

/// The calendar sensor's settings: the one permission Chrono ever asks for.
///
/// The copy works hard here on purpose. This is the first prompt the app shows for a sensor, and
/// the difference between someone granting it and declining it is whether they can tell what is
/// being read. So the panel states the limits, and once access is granted it lists the actual
/// accounts and calendars — visible proof rather than a promise, and the place a Google account
/// shows up as being included.
struct CalendarSettingsSection: View {
    @Environment(AppEnvironment.self) private var environment

    private var bind: SettingsBinding { SettingsBinding(environment: environment) }
    private var settings: TrackerSettings { environment.engine.settings }
    private var sensor: CalendarSensor { environment.calendar }

    var body: some View {
        SettingsGroup(
            "Calendar",
            footnote: "Chrono reads only the title and times of events, never writes to your calendar, and sends nothing anywhere. macOS only offers full calendar access, not read-only, so that is what the prompt asks for — the restriction to reading is Chrono's own. Any calendar macOS already syncs works, including Google, because Chrono reads them through macOS rather than talking to those services itself."
        ) {
            Toggle("Use my calendar to name meeting time", isOn: Binding(
                get: { settings.calendarIntegrationEnabled },
                set: { enabled in
                    environment.mutateSettings { $0.calendarIntegrationEnabled = enabled }
                    if enabled {
                        Task {
                            // The prompt appears here and nowhere else — enabling it is the
                            // only thing that ever triggers it.
                            await sensor.requestAccess()
                            sensor.refreshCalendars()
                            environment.refreshCalendar()
                        }
                    }
                }
            ))
            .font(.system(size: 12, weight: .medium))

            if settings.calendarIntegrationEnabled {
                Divider()
                accessRow

                if sensor.access.isUsable {
                    Toggle("Name meeting time after the event", isOn: bind.bind(\.labelMeetingsFromCalendar))
                        .font(.system(size: 11.5))
                        .help("Tracks \"Sprint review\" instead of a generic \"Meeting\"")
                    Toggle("Offer to add meetings I forgot to track", isOn: bind.bind(\.offerCalendarBackfill))
                        .font(.system(size: 11.5))

                    Divider()
                    calendarPicker
                }
            }
        }
    }

    @ViewBuilder
    private var accessRow: some View {
        switch sensor.access {
        case .granted:
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.green)
                Text("\(sensor.availableCalendars.count) calendars readable")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Refresh") {
                    sensor.refreshCalendars()
                    environment.refreshCalendar()
                }
                .buttonStyle(QuietButtonStyle(compact: true))
            }
        case .notDetermined:
            HStack {
                Text("Waiting for permission.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Ask again") {
                    Task {
                        await sensor.requestAccess()
                        sensor.refreshCalendars()
                        environment.refreshCalendar()
                    }
                }
                .buttonStyle(FilledButtonStyle(compact: true))
            }
        case .denied, .writeOnly, .restricted:
            VStack(alignment: .leading, spacing: 4) {
                Text(sensor.access == .writeOnly
                    ? "macOS granted write-only access, which Chrono cannot use — it only ever reads."
                    : "Calendar access was declined. Everything else in Chrono works without it.")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Open Privacy Settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(QuietButtonStyle(compact: true))
            }
        }
    }

    /// Grouped by account, because that is the question people actually have — "is it reading my
    /// work Google calendar or my personal one?"
    @ViewBuilder
    private var calendarPicker: some View {
        let grouped = Dictionary(grouping: sensor.availableCalendars, by: \.accountName)
            .sorted { $0.key < $1.key }

        if grouped.isEmpty {
            Text("No calendars found. Add an account in System Settings ▸ Internet Accounts.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Calendars to read")
                        .font(.system(size: 11.5, weight: .medium))
                    Spacer()
                    if !settings.calendarIdentifiers.isEmpty {
                        Button("Use all") {
                            environment.mutateSettings { $0.calendarIdentifiers = [] }
                            environment.refreshCalendar()
                        }
                        .buttonStyle(QuietButtonStyle(compact: true))
                    }
                }

                if settings.calendarIdentifiers.isEmpty {
                    Text("All of them. Tick individual calendars to narrow it down.")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                }

                ForEach(grouped, id: \.key) { account, calendars in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(account)
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(.secondary)
                        ForEach(calendars) { info in
                            Toggle(isOn: binding(for: info)) {
                                Text(info.title).font(.system(size: 11))
                            }
                            .padding(.leading, Theme.Spacing.small)
                        }
                    }
                }
            }
        }
    }

    /// An empty selection means "all", so the toggles read as on until one is ticked — and the
    /// first tick has to seed the list with just that calendar rather than removing one from
    /// nothing.
    private func binding(for info: CalendarSensor.CalendarInfo) -> Binding<Bool> {
        Binding(
            get: {
                settings.calendarIdentifiers.isEmpty
                    || settings.calendarIdentifiers.contains(info.id)
            },
            set: { isOn in
                environment.mutateSettings { settings in
                    var selection = settings.calendarIdentifiers
                    if selection.isEmpty {
                        // Was "all": ticking off one means "all except this".
                        selection = sensor.availableCalendars.map(\.id)
                    }
                    if isOn {
                        if !selection.contains(info.id) { selection.append(info.id) }
                    } else {
                        selection.removeAll { $0 == info.id }
                    }
                    // Back to every calendar selected is the same as "all", and storing it that
                    // way means a newly added calendar is picked up rather than silently missing.
                    settings.calendarIdentifiers =
                        Set(selection) == Set(sensor.availableCalendars.map(\.id)) ? [] : selection
                }
                environment.refreshCalendar()
            }
        )
    }
}
