import SwiftUI

/// Calendar-driven recording section embedded in the General settings tab.
///
/// Lets the user opt into calendar-driven detection (system-wide capture that
/// starts/stops on event boundaries) and pick which local calendars may
/// trigger a recording. The allowlist is stored in `AppSettings.enabledCalendarIDs`
/// where an **empty set means all calendars enabled** (least-surprising first
/// run); toggling a calendar off materializes the full id list minus that one
/// so the math stays consistent in both directions.
struct CalendarDetectionSection: View {
    @Bindable var settings: AppSettings

    // `@State` (not a plain `let`) so a single `EKEventStore` is created and
    // reused across the view's re-initializations instead of one per body eval.
    @State private var eventSource = CalendarEventSource()
    @State private var calendars: [CalendarListEntry] = []

    var body: some View {
        Section("Calendar") {
            Toggle("Start from calendar events", isOn: $settings.calendarDetectionEnabled)
                .accessibilityIdentifier("calendarDetectionToggle")
                .onChange(of: settings.calendarDetectionEnabled) { _, newValue in
                    guard newValue else { return }
                    Task { await ensureAccessThenReload() }
                }

            if settings.calendarDetectionEnabled {
                if !eventSource.isAuthorized {
                    Label(
                        "Calendar access not granted. Grant access in System Settings → Privacy & Security → Calendars.",
                        systemImage: "exclamationmark.triangle.fill",
                    )
                    .foregroundStyle(.orange)
                    .font(.caption)

                    Button("Grant Access…") {
                        Task { await ensureAccessThenReload() }
                    }
                } else if calendars.isEmpty {
                    Text("No calendars available. Add one in the Calendar app or System Settings → Internet Accounts.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    allowlistHint
                    ForEach(calendars) { entry in
                        calendarRow(entry)
                    }
                }
            }
        }
        .onAppear { reloadCalendars() }
    }

    private var allowlistHint: some View {
        Text(settings.enabledCalendarIDs.isEmpty
            ? "All calendars enabled. Turn one off to restrict recording to specific calendars."
            : "Only the selected calendars trigger recordings.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private func calendarRow(_ entry: CalendarListEntry) -> some View {
        HStack {
            VStack(alignment: .leading) {
                Text(entry.title)
                if !entry.sourceTitle.isEmpty {
                    Text(entry.sourceTitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            // Empty allowlist = all on; otherwise explicit membership. A
            // `Binding(get:set:)` (not a constant) so the toggle both reflects
            // and drives the set-backed allowlist.
            Toggle(
                "",
                isOn: Binding(
                    get: { settings.enabledCalendarIDs.isEmpty || settings.enabledCalendarIDs.contains(entry.id) },
                    set: { enabled in setCalendar(entry.id, enabled: enabled) }
                )
            )
            .labelsHidden()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(entry.title) — \(entry.sourceTitle)")
    }

    /// Request calendar access if not yet granted, then (always) refresh the
    /// list. Refreshing unconditionally mutates `calendars` so the view
    /// re-renders and re-reads `eventSource.isAuthorized` after the async grant
    /// attempt — including the denied case.
    @MainActor
    private func ensureAccessThenReload() async {
        if !eventSource.isAuthorized {
            _ = await eventSource.requestAccess()
            // Small delay to let the permission dialog be dismissed and EventKit update its state
            try? await Task.sleep(for: .milliseconds(500))
        }
        reloadCalendars()
    }

    /// Load the calendar list from EventKit (empty when not authorized).
    @MainActor
    private func reloadCalendars() {
        calendars = eventSource.availableCalendars()
    }

    /// Update the allowlist for one calendar, preserving the "empty = all on"
    /// invariant. Turning a calendar OFF from the all-on (empty) state
    /// materializes the full id set minus that calendar; turning one ON simply
    /// adds it (which may re-collapse back to "all on" if the user re-enables
    /// everything, but that's benign and self-correcting).
    private func setCalendar(_ id: String, enabled: Bool) {
        var ids = settings.enabledCalendarIDs
        if enabled {
            ids.insert(id)
        } else if ids.isEmpty {
            // Materialize "all on" → all ids except this one.
            ids = Set(eventSource.availableCalendars().map(\.id))
            ids.remove(id)
        } else {
            ids.remove(id)
        }
        settings.enabledCalendarIDs = ids
    }
}
