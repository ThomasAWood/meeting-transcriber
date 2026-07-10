import XCTest
@testable import MeetingTranscriber

@MainActor
final class CalendarDetectorTests: XCTestCase {
    // MARK: - Logic Tests

    func testCalendarDetectorLogic_NoEvents() {
        let now = Date(timeIntervalSince1970: 1000)
        let events: [CalendarEventInfo] = []
        let active = CalendarDetectorLogic.activeEvent(at: now, events: events, enabledCalendarIDs: [])
        XCTAssertNil(active)
    }

    func testCalendarDetectorLogic_ActiveEvent() {
        let now = Date(timeIntervalSince1970: 1000)
        let event = CalendarEventInfo(
            id: "1",
            title: "Test Meeting",
            calendarID: "cal_1",
            start: now.addingTimeInterval(-60), // 1 min ago
            end: now.addingTimeInterval(3600),  // 1 hour from now
            isAllDay: false,
            isCancelled: false
        )
        let active = CalendarDetectorLogic.activeEvent(at: now, events: [event], enabledCalendarIDs: [])
        XCTAssertEqual(active?.title, "Test Meeting")
    }

    func testCalendarDetectorLogic_EndBoundary() {
        let now = Date(timeIntervalSince1970: 1000)
        // Event ends exactly at 'now' - should be nil because end is exclusive (start <= now < end)
        let event = CalendarEventInfo(
            id: "1",
            title: "Ends Now",
            calendarID: "cal_1",
            start: now.addingTimeInterval(-60),
            end: now,
            isAllDay: false,
            isCancelled: false
        )
        let active = CalendarDetectorLogic.activeEvent(at: now, events: [event], enabledCalendarIDs: [])
        XCTAssertNil(active)
    }

    func testCalendarDetectorLogic_SkipsAllDay() {
        let now = Date(timeIntervalSince1970: 1000)
        let event = CalendarEventInfo(
            id: "1",
            title: "All Day Event",
            calendarID: "cal_1",
            start: now.addingTimeInterval(-86400),
            end: now.addingTimeInterval(86400),
            isAllDay: true,
            isCancelled: false
        )
        let active = CalendarDetectorLogic.activeEvent(at: now, events: [event], enabledCalendarIDs: [])
        XCTAssertNil(active)
    }

    func testCalendarDetectorLogic_SkipsCancelled() {
        let now = Date(timeIntervalSince1970: 1000)
        let event = CalendarEventInfo(
            id: "1",
            title: "Cancelled Event",
            calendarID: "cal_1",
            start: now.addingTimeInterval(-60),
            end: now.addingTimeInterval(3600),
            isAllDay: false,
            isCancelled: true
        )
        let active = CalendarDetectorLogic.activeEvent(at: now, events: [event], enabledCalendarIDs: [])
        XCTAssertNil(active)
    }

    func testCalendarDetectorLogic_Allowlist() {
        let now = Date(timeIntervalSince1970: 1000)
        let eventIn = CalendarEventInfo(
            id: "in",
            title: "In",
            calendarID: "cal_1",
            start: now.addingTimeInterval(-60),
            end: now.addingTimeInterval(3600),
            isAllDay: false,
            isCancelled: false
        )
        let eventOut = CalendarEventInfo(
            id: "out",
            title: "Out",
            calendarID: "cal_2",
            start: now.addingTimeInterval(-60),
            end: now.addingTimeInterval(3600),
            isAllDay: false,
            isCancelled: false
        )

        // Case 1: Allowlist non-empty
        let activeIn = CalendarDetectorLogic.activeEvent(at: now, events: [eventIn, eventOut], enabledCalendarIDs: ["cal_1"])
        XCTAssertEqual(activeIn?.id, "in")

        // Case 2: Allowlist empty (all allowed)
        let activeAll = CalendarDetectorLogic.activeEvent(at: now, events: [eventIn, eventOut], enabledCalendarIDs: [])
        XCTAssertNotNil(activeAll)
    }

    func testCalendarDetectorLogic_EarliestEndWins() {
        let now = Date(timeIntervalSince1970: 1000)
        let event1 = CalendarEventInfo(id: "1", title: "First to end", calendarID: "c", start: now.addingTimeInterval(-10), end: now.addingTimeInterval(100))
        let event2 = CalendarEventInfo(id: "2", title: "Second to end", calendarID: "c", start: now.addingTimeInterval(-10), end: now.addingTimeInterval(200))
        let event3 = CalendarEventInfo(id: "3", title: "Third to end", calendarID: "c", start: now.addingTimeInterval(-10), end: now.addingTimeInterval(50))

        let active = CalendarDetectorLogic.activeEvent(at: now, events: [event1, event2, event3], enabledCalendarIDs: [])
        XCTAssertEqual(active?.id, "3") // Fixed: earliest end is event 3 (50)
    }

    // MARK: - Detector Tests

    func testCalendarDetector_CheckOnce() {
        let fixedNow = Date(timeIntervalSince1970: 2000)
        let event = CalendarEventInfo(
            id: "evt_1",
            title: "Meeting Title",
            calendarID: "cal_1",
            start: fixedNow.addingTimeInterval(-60),
            end: fixedNow.addingTimeInterval(3600),
            isAllDay: false,
            isCancelled: false
        )

        let detector = CalendarDetector(
            eventsProvider: { _, _ in [event] },
            enabledCalendarIDs: { ["cal_1"] },
            nowProvider: { fixedNow }
        )

        let meeting = detector.checkOnce()
        XCTAssertNotNil(meeting)
        XCTAssertEqual(meeting?.windowTitle, "Meeting Title")
        XCTAssertEqual(meeting?.pattern.appName, "Calendar")
        XCTAssertEqual(meeting?.windowPID, 0)
    }

    func testCalendarDetector_IsMeetingActive() {
        let fixedNow = Date(timeIntervalSince1970: 2000)
        let eventEnd = fixedNow.addingTimeInterval(100)
        let eventStart = fixedNow.addingTimeInterval(-100)

        let event = CalendarEventInfo(
            id: "evt_1",
            title: "Meeting Title",
            calendarID: "cal_1",
            start: eventStart,
            end: eventEnd,
            isAllDay: false,
            isCancelled: false
        )

        let detector = CalendarDetector(
            eventsProvider: { _, _ in [event] },
            enabledCalendarIDs: { [] },
            nowProvider: { fixedNow }
        )

        // First, establish the meeting in detector state
        _ = detector.checkOnce()

        XCTAssertTrue(detector.isMeetingActive(DetectedMeeting(pattern: AppMeetingPattern(appName: "Calendar", ownerNames: [], meetingPatterns: []), windowTitle: "", ownerName: "", windowPID: 0)), "Should be active before end")

        // Move time past end
        let detectorAfterEnd = CalendarDetector(
            eventsProvider: { _, _ in [event] },
            enabledCalendarIDs: { [] },
            nowProvider: { eventEnd.addingTimeInterval(1) }
        )
        _ = detectorAfterEnd.checkOnce() // Must call checkOnce to update the internal currentEvent
        XCTAssertFalse(detectorAfterEnd.isMeetingActive(DetectedMeeting(pattern: AppMeetingPattern(appName: "Calendar", ownerNames: [], meetingPatterns: []), windowTitle: "", ownerName: "", windowPID: 0)), "Should not be active after end")
    }

    func testCalendarDetector_Reset() {
        let fixedNow = Date(timeIntervalSince1970: 2000)
        let event = CalendarEventInfo(id: "1", title: "T", calendarID: "c", start: fixedNow, end: fixedNow.addingTimeInterval(100), isAllDay: false, isCancelled: false)

        let detector = CalendarDetector(
            eventsProvider: { _, _ in [event] },
            enabledCalendarIDs: { [] },
            nowProvider: { fixedNow }
        )

        _ = detector.checkOnce()
        detector.reset()

        // `reset()` clears the in-progress event tracking so `isMeetingActive`
        // no longer reports the prior event as active (it returns false until a
        // fresh `checkOnce`). A still-active event can legitimately be
        // re-detected by a subsequent poll.
        XCTAssertFalse(detector.isMeetingActive(DetectedMeeting.mock(end: fixedNow)))
        XCTAssertNotNil(detector.checkOnce())
    }
}

// MARK: - Helper for isMeetingActive testing
extension DetectedMeeting {
    /// A helper to create a meeting with a specific end date for testing isMeetingActive.
    static func mock(end: Date) -> DetectedMeeting {
        DetectedMeeting(
            pattern: AppMeetingPattern(appName: "Calendar", ownerNames: [], meetingPatterns: []),
            windowTitle: "",
            ownerName: "",
            windowPID: 0,
            detectedAt: Date()
        )
    }
}

// Note: The actual implementation of isMeetingActive in CalendarDetector uses the internal currentEvent.
// To test it properly, we must ensure checkOnce has been called to populate currentEvent.
extension CalendarDetector {
    func testIsMeetingActive_Logic() {
        // This is a bit tricky because currentEvent is private. 
        // We rely on the fact that checkOnce populates it.
    }
}
