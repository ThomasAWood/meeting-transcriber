import EventKit
import Foundation
import os.log

/// Information about a calendar event used for meeting detection.
struct CalendarEventInfo: Equatable, Sendable {
    let id: String
    let title: String
    let calendarID: String
    let start: Date
    let end: Date
    let isAllDay: Bool
    let isCancelled: Bool

    init(
        id: String,
        title: String,
        calendarID: String,
        start: Date,
        end: Date,
        isAllDay: Bool = false,
        isCancelled: Bool = false
    ) {
        self.id = id
        self.title = title
        self.calendarID = calendarID
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
        self.isCancelled = isCancelled
    }
}

/// Information about a calendar list entry.
struct CalendarListEntry: Equatable, Identifiable, Sendable {
    let id: String // The calendar identifier
    let title: String // The calendar title
    let sourceTitle: String // The calendar source/account title

    init(id: String, title: String, sourceTitle: String) {
        self.id = id
        self.title = title
        self.sourceTitle = sourceTitle
    }
}

/// Pure decision logic for identifying active events from a list of event info.
enum CalendarDetectorLogic {
    /// Returns the active event at the given time, following specific priority rules.
    static func activeEvent(at now: Date, events: [CalendarEventInfo], enabledCalendarIDs: Set<String>) -> CalendarEventInfo? {
        let filtered = events.filter { event in
            // Skip all-day or cancelled events
            guard !event.isAllDay, !event.isCancelled else { return false }

            // Check if event is within the time window (start <= now < end)
            guard event.start <= now, now < event.end else { return false }

            // If an allowlist is provided, only include events from those calendars
            if !enabledCalendarIDs.isEmpty {
                return enabledCalendarIDs.contains(event.calendarID)
            }

            return true
        }

        // Sort by: 1. Earliest end, 2. Earliest start, 3. ID (for determinism)
        return filtered.sorted {
            if $0.end != $1.end {
                return $0.end < $1.end
            }
            if $0.start != $1.start {
                return $0.start < $1.start
            }
            return $0.id < $1.id
        }.first
    }
}

/// Production EventKit wrapper for accessing calendar data.
///
/// Not `@MainActor`-isolated so it can be called synchronously from the
/// nonisolated `CalendarDetector` (which conforms to the nonisolated
/// `MeetingDetecting` protocol like the other detectors). All actual access is
/// main-thread in practice — the detector is driven by the `@MainActor`
/// `WatchLoop`, and the settings UI calls `requestAccess()`/`availableCalendars()`
/// on main — so the class is `@unchecked Sendable` to satisfy Swift 6 without
/// forcing main-actor isolation (which would break the detector conformance).
/// EventKit calls are Objective-C APIs that compile from a nonisolated context.
final class CalendarEventSource: @unchecked Sendable {
    private let store = EKEventStore()

    init() {}

    /// Returns true if the app has full access to calendar events.
    var isAuthorized: Bool {
        EKEventStore.authorizationStatus(for: .event) == .fullAccess
    }

    /// Requests full access to calendar events.
    func requestAccess() async -> Bool {
        guard !isAuthorized else { return true }

        do {
            let granted = try await store.requestFullAccessToEvents()
            if !granted {
                Logger(subsystem: AppPaths.logSubsystem, category: "CalendarDetector")
                    .info("User denied calendar access.")
            }
            return granted
        } catch {
            Logger(subsystem: AppPaths.logSubsystem, category: "CalendarDetector")
                .error("Failed to request calendar access: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// Fetches event information within the specified date range.
    func fetchEvents(from start: Date, to end: Date) -> [CalendarEventInfo] {
        guard isAuthorized else { return [] }

        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        let ekEvents = store.events(matching: predicate)

        return ekEvents.map { event in
            CalendarEventInfo(
                id: event.eventIdentifier,
                title: event.title ?? "",
                calendarID: event.calendar.calendarIdentifier,
                start: event.startDate,
                end: event.endDate,
                isAllDay: event.isAllDay,
                isCancelled: event.status == .canceled
            )
        }
    }

    /// Returns a list of available calendars.
    func availableCalendars() -> [CalendarListEntry] {
        guard isAuthorized else { return [] }

        return store.calendars(for: .event).map { calendar in
            CalendarListEntry(
                id: calendar.calendarIdentifier,
                title: calendar.title,
                sourceTitle: calendar.source?.title ?? ""
            )
        }
    }
}

/// Detects active meetings via calendar events.
///
/// Nonisolated to match the other `MeetingDetecting` conformers
/// (`PowerAssertionDetector`); the watch loop drives it on the main thread.
@Observable
final class CalendarDetector: MeetingDetecting {
    private let eventsProvider: (Date, Date) -> [CalendarEventInfo]
    private let enabledCalendarIDs: () -> Set<String>
    private let nowProvider: () -> Date
    private let cacheRefreshInterval: TimeInterval

    private var cachedEvents: [CalendarEventInfo] = []
    private var lastFetchDate: Date?
    private var currentEvent: CalendarEventInfo?

    /// Initializes the detector.
    init(
        eventsProvider: @escaping (Date, Date) -> [CalendarEventInfo],
        enabledCalendarIDs: @escaping () -> Set<String>,
        nowProvider: @escaping () -> Date = { Date() },
        cacheRefreshInterval: TimeInterval = 60
    ) {
        self.eventsProvider = eventsProvider
        self.enabledCalendarIDs = enabledCalendarIDs
        self.nowProvider = nowProvider
        self.cacheRefreshInterval = cacheRefreshInterval
    }

    /// Polls for a new meeting based on calendar events.
    func checkOnce() -> DetectedMeeting? {
        let now = nowProvider()

        // Refresh cache if stale or outside window
        if lastFetchDate == nil || now.timeIntervalSince(lastFetchDate!) > cacheRefreshInterval {
            // Fetch a window around 'now' to ensure we capture the current event and upcoming ones.
            let start = now.addingTimeInterval(-300) // 5 mins before
            let end = now.addingTimeInterval(86400)  // 24 hours after
            cachedEvents = eventsProvider(start, end)
            lastFetchDate = now
        }

        guard let activeEvent = CalendarDetectorLogic.activeEvent(at: now, events: cachedEvents, enabledCalendarIDs: enabledCalendarIDs()) else {
            if currentEvent != nil {
                Logger(subsystem: AppPaths.logSubsystem, category: "CalendarDetector")
                    .info("Meeting ended (no active calendar event found).")
                currentEvent = nil
            }
            return nil
        }

        if currentEvent == nil {
            Logger(subsystem: AppPaths.logSubsystem, category: "CalendarDetector")
                .info("Meeting detected via calendar: \(activeEvent.title, privacy: .private)")
        }

        currentEvent = activeEvent

        return DetectedMeeting(
            pattern: AppMeetingPattern(
                appName: "Calendar",
                ownerNames: [],
                meetingPatterns: []
            ),
            windowTitle: activeEvent.title.isEmpty ? "Calendar Event" : activeEvent.title,
            ownerName: "",
            windowPID: 0, // Sentinel for system-wide capture; watch loop translates this to a global recording.
            detectedAt: now
        )
    }

    /// Checks if the currently detected meeting is still active.
    func isMeetingActive(_ meeting: DetectedMeeting) -> Bool {
        guard let event = currentEvent else { return false }
        return nowProvider() < event.end
    }

    /// Resets the detector state.
    func reset(appName: String? = nil) {
        currentEvent = nil
    }
}

// MARK: - Production Factory Extension
extension CalendarDetector {
    static func production(
        source: CalendarEventSource = CalendarEventSource(),
        enabledCalendarIDs: @escaping () -> Set<String>,
        nowProvider: @escaping () -> Date = { Date() }
    ) -> CalendarDetector {
        CalendarDetector(
            eventsProvider: { start, end in source.fetchEvents(from: start, to: end) },
            enabledCalendarIDs: enabledCalendarIDs,
            nowProvider: nowProvider
        )
    }
}
