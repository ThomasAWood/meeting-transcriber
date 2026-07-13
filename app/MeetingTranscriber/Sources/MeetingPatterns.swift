import Foundation

/// Identity record for a known meeting app. Carries only the fields the
/// power-assertion / calendar detectors use: `appName` (for assertion-pattern
/// matching + the detected meeting's app label) and `ownerNames` (the on-screen
/// process names an app is known under, kept as documentation / for future use).
///
/// Window-title detection (regexes, idle patterns, minimum window size) lived
/// here too but was removed along with the Screen Recording permission: it was
/// the only code path that needed `CGWindowListCopyWindowInfo`. Detection is now
/// calendar-driven + power-assertion based, neither of which needs SR.
struct AppMeetingPattern: Equatable {
    let appName: String
    let ownerNames: [String]

    init(
        appName: String,
        ownerNames: [String],
    ) {
        self.appName = appName
        self.ownerNames = ownerNames
    }
}

extension AppMeetingPattern {
    static let teams = AppMeetingPattern(
        appName: "Microsoft Teams",
        ownerNames: ["Microsoft Teams", "Microsoft Teams (work or school)"],
    )

    static let zoom = AppMeetingPattern(
        appName: "Zoom",
        ownerNames: ["zoom.us"],
    )

    static let webex = AppMeetingPattern(
        appName: "Webex",
        ownerNames: ["Webex", "Cisco Webex Meetings"],
    )

    /// Debug simulator for testing the full pipeline without a real meeting app.
    /// Run: cd tools/meeting-simulator && swift run
    static let simulator = AppMeetingPattern(
        appName: "MeetingSimulator",
        ownerNames: ["meeting-simulator"],
    )

    static let all: [AppMeetingPattern] = [teams, zoom, webex, simulator]

    static let byName: [String: AppMeetingPattern] = {
        var dict: [String: AppMeetingPattern] = [:]
        for p in all {
            dict[p.appName.lowercased()] = p
        }
        return dict
    }()

    /// Lookup pattern by app name (case-insensitive).
    static func forAppName(_ name: String) -> AppMeetingPattern? {
        byName[name.lowercased()]
    }
}
