@testable import MeetingTranscriber
import XCTest

final class AppMeetingPatternTests: XCTestCase {
    // MARK: - forAppName Lookup

    func testForAppNameReturnsTeams() {
        let pattern = AppMeetingPattern.forAppName("Microsoft Teams")
        XCTAssertEqual(pattern?.appName, "Microsoft Teams")
    }

    func testForAppNameCaseInsensitive() {
        let pattern = AppMeetingPattern.forAppName("microsoft teams")
        XCTAssertEqual(pattern?.appName, "Microsoft Teams")
    }

    func testForAppNameReturnsNilForUnknown() {
        XCTAssertNil(AppMeetingPattern.forAppName("Unknown App"))
    }

    // MARK: - All Patterns

    func testAllPatternsCount() {
        XCTAssertEqual(AppMeetingPattern.all.count, 4)
    }

    // MARK: - Simulator Pattern

    func testSimulatorPattern() {
        let sim = AppMeetingPattern.simulator
        XCTAssertEqual(sim.appName, "MeetingSimulator")
    }

    // MARK: - Owner Names

    func testTeamsOwnerNames() {
        XCTAssertFalse(AppMeetingPattern.teams.ownerNames.isEmpty)
    }

    func testZoomOwnerNames() {
        XCTAssertTrue(AppMeetingPattern.zoom.ownerNames.contains("zoom.us"))
    }

    func testWebexOwnerNames() {
        XCTAssertTrue(AppMeetingPattern.webex.ownerNames.contains("Webex"))
    }

    // MARK: - byName Lookup

    func testByNameLookup() {
        XCTAssertNotNil(AppMeetingPattern.byName["microsoft teams"])
        XCTAssertNotNil(AppMeetingPattern.byName["zoom"])
        XCTAssertNotNil(AppMeetingPattern.byName["webex"])
        XCTAssertNil(AppMeetingPattern.byName["slack"])
    }
}
