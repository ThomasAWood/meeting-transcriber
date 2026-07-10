import Foundation

/// A `MeetingDetecting` that delegates to an ordered list of sub-detectors,
/// returning the first hit and routing `isMeetingActive` to whichever
/// sub-detector produced the current meeting.
///
/// Used to layer the calendar-driven detector (primary trigger) over the
/// power-assertion detector (fallback for unscheduled calls). Order matters:
/// an earlier detector wins when more than one has a hit on the same poll.
final class CompositeMeetingDetector: MeetingDetecting {
    let detectors: [any MeetingDetecting]

    /// The sub-detector whose `checkOnce` most recently returned a meeting.
    /// `isMeetingActive` is routed here so each meeting is checked against the
    /// strategy that detected it (the watch loop only ever has one active
    /// meeting, polled repeatedly until it ends).
    private var activeDetector: (any MeetingDetecting)?

    init(detectors: [any MeetingDetecting]) {
        self.detectors = detectors
    }

    func checkOnce() -> DetectedMeeting? {
        for detector in detectors {
            if let meeting = detector.checkOnce() {
                activeDetector = detector
                return meeting
            }
        }
        return nil
    }

    func isMeetingActive(_ meeting: DetectedMeeting) -> Bool {
        activeDetector?.isMeetingActive(meeting) ?? false
    }

    func reset(appName: String?) {
        for detector in detectors { detector.reset(appName: appName) }
        activeDetector = nil
    }
}
