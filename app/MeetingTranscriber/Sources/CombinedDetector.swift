import Foundation
import os.log

private let logger = Logger(subsystem: AppPaths.logSubsystem, category: "CombinedDetector")

/// Combined meeting detector that uses calendar events as the primary trigger
/// and power assertions (meeting app power claims) as a fallback.
///
/// When calendar detection is enabled, it checks for active calendar events first.
/// If no calendar event is found, it falls back to power assertion detection.
/// This hybrid approach gives calendar events priority while still capturing
/// ad-hoc meetings started without calendar entries.
@Observable
final class CombinedDetector: MeetingDetecting {
    private let calendarDetector: CalendarDetector?
    private let powerAssertionDetector: PowerAssertionDetector
    private let calendarEnabled: () -> Bool

    private var lastActiveSource: ActiveSource = .none

    enum ActiveSource {
        case none
        case calendar
        case powerAssertion
    }

    init(
        calendarDetector: CalendarDetector?,
        powerAssertionDetector: PowerAssertionDetector,
        calendarEnabled: @escaping () -> Bool
    ) {
        self.calendarDetector = calendarDetector
        self.powerAssertionDetector = powerAssertionDetector
        self.calendarEnabled = calendarEnabled
    }

    /// Polls for meetings, checking calendar first (if enabled), then power assertions.
    func checkOnce() -> DetectedMeeting? {
        // Check calendar first if enabled
        if calendarEnabled(), let calendar = calendarDetector {
            if let meeting = calendar.checkOnce() {
                if lastActiveSource != .calendar {
                    logger.info("Meeting detected via calendar detector")
                    lastActiveSource = .calendar
                }
                return meeting
            }
        }

        // Fallback to power assertion detection
        if let meeting = powerAssertionDetector.checkOnce() {
            if lastActiveSource != .powerAssertion {
                logger.info("Meeting detected via power assertion detector")
                lastActiveSource = .powerAssertion
            }
            return meeting
        }

        lastActiveSource = .none
        return nil
    }

    /// Checks if a meeting is still active by delegating to the appropriate detector.
    func isMeetingActive(_ meeting: DetectedMeeting) -> Bool {
        // If the meeting came from calendar and calendar is still enabled, check that
        if meeting.pattern.appName == "Calendar", calendarEnabled(), let calendar = calendarDetector {
            return calendar.isMeetingActive(meeting)
        }

        // Otherwise check power assertion detector
        return powerAssertionDetector.isMeetingActive(meeting)
    }

    /// Resets both detectors.
    func reset(appName: String? = nil) {
        calendarDetector?.reset(appName: appName)
        powerAssertionDetector.reset(appName: appName)
        lastActiveSource = .none
    }

    // MARK: - Production Factory

    static func production(
        settings: AppSettings,
        eventSource: CalendarEventSource = CalendarEventSource()
    ) -> CombinedDetector {
        let calendarDetector: CalendarDetector?
        if settings.calendarDetectionEnabled {
            calendarDetector = CalendarDetector.production(
                source: eventSource,
                enabledCalendarIDs: { settings.enabledCalendarIDs }
            )
        } else {
            calendarDetector = nil
        }

        let powerAssertionDetector = PowerAssertionDetector()

        return CombinedDetector(
            calendarDetector: calendarDetector,
            powerAssertionDetector: powerAssertionDetector,
            calendarEnabled: { settings.calendarDetectionEnabled }
        )
    }
}