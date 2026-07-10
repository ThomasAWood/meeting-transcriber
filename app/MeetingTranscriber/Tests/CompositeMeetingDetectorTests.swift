@testable import MeetingTranscriber
import XCTest

// MARK: - Test doubles

/// Controllable `MeetingDetecting` double. `checkOnce` returns `stubbedMeeting`
/// (toggled off after the first return when `returnOnce` is true); it records
/// `isMeetingActive` / `reset` invocations so routing can be asserted.
private final class StubDetector: MeetingDetecting {
    let label: String
    var stubbedMeeting: DetectedMeeting?
    var active = true
    var returnOnce = false
    private(set) var isActiveCallCount = 0
    private(set) var resetCallCount = 0

    init(label: String) {
        self.label = label
    }

    func checkOnce() -> DetectedMeeting? {
        let result = stubbedMeeting
        if returnOnce { stubbedMeeting = nil }
        return result
    }

    func isMeetingActive(_: DetectedMeeting) -> Bool {
        isActiveCallCount += 1
        return active
    }

    func reset(appName _: String?) {
        resetCallCount += 1
    }
}

// MARK: - Tests

private func makeMeeting(appName: String, pid: pid_t = 1) -> DetectedMeeting {
    DetectedMeeting(
        pattern: AppMeetingPattern(appName: appName, ownerNames: [], meetingPatterns: []),
        windowTitle: appName,
        ownerName: "",
        windowPID: pid,
    )
}

// MARK: - Tests

final class CompositeMeetingDetectorTests: XCTestCase {
    func testReturnsNilWhenNoSubdetectorMatches() {
        let composite = CompositeMeetingDetector(detectors: [
            StubDetector(label: "a"),
            StubDetector(label: "b"),
        ])
        XCTAssertNil(composite.checkOnce())
    }

    func testReturnsFirstSubdetectorHitInOrder() {
        let first = StubDetector(label: "first")
        let second = StubDetector(label: "second")
        first.stubbedMeeting = makeMeeting(appName: "First")
        second.stubbedMeeting = makeMeeting(appName: "Second")

        let composite = CompositeMeetingDetector(detectors: [first, second])
        let result = composite.checkOnce()

        XCTAssertEqual(result?.pattern.appName, "First")
    }

    func testFallsThroughToLaterSubdetectorWhenEarlierMisses() {
        let first = StubDetector(label: "first")
        let second = StubDetector(label: "second")
        // Only the second detector has a meeting.
        second.stubbedMeeting = makeMeeting(appName: "Second")

        let composite = CompositeMeetingDetector(detectors: [first, second])
        let result = composite.checkOnce()

        XCTAssertEqual(result?.pattern.appName, "Second")
    }

    func testIsMeetingActiveRoutesToProducingDetector() {
        let calendar = StubDetector(label: "calendar")
        let power = StubDetector(label: "power")
        calendar.stubbedMeeting = makeMeeting(appName: "Calendar")
        let composite = CompositeMeetingDetector(detectors: [calendar, power])

        let meeting = composite.checkOnce()
        XCTAssertEqual(meeting?.pattern.appName, "Calendar")

        _ = composite.isMeetingActive(meeting!)

        // Routed to the detector that produced the meeting (calendar), not power.
        XCTAssertEqual(calendar.isActiveCallCount, 1)
        XCTAssertEqual(power.isActiveCallCount, 0)
    }

    func testIsMeetingActiveReturnsFalseBeforeAnyDetection() {
        let composite = CompositeMeetingDetector(detectors: [StubDetector(label: "a")])
        XCTAssertFalse(composite.isMeetingActive(makeMeeting(appName: "x")))
    }

    func testIsMeetingActiveRoutesToSecondDetectorWhenItProducedTheMeeting() {
        let first = StubDetector(label: "first")
        let second = StubDetector(label: "second")
        second.stubbedMeeting = makeMeeting(appName: "Power")
        let composite = CompositeMeetingDetector(detectors: [first, second])

        let meeting = composite.checkOnce()
        _ = composite.isMeetingActive(meeting!)

        XCTAssertEqual(first.isActiveCallCount, 0)
        XCTAssertEqual(second.isActiveCallCount, 1)
    }

    func testResetDelegatesToAllSubdetectorsAndClearsRouting() {
        let first = StubDetector(label: "first")
        let second = StubDetector(label: "second")
        first.stubbedMeeting = makeMeeting(appName: "First")
        let composite = CompositeMeetingDetector(detectors: [first, second])

        _ = composite.checkOnce()
        composite.reset()

        XCTAssertEqual(first.resetCallCount, 1)
        XCTAssertEqual(second.resetCallCount, 1)

        // After reset, isMeetingActive no longer routes anywhere (no active detector).
        let callsBefore = first.isActiveCallCount
        XCTAssertFalse(composite.isMeetingActive(makeMeeting(appName: "First")))
        XCTAssertEqual(first.isActiveCallCount, callsBefore)
    }
}
