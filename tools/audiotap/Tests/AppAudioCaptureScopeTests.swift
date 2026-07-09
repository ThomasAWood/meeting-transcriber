@testable import AudioTapLib
import XCTest

/// Tests for the `CaptureScope` switch on `AppAudioCapture` /
/// `AudioCaptureSession` (per-process mixdown vs. system-wide global tap).
///
/// The actual `start()` path needs real audio hardware + TCC permission, so
/// these cover the constructible surface — scope storage, the `pids` computed
/// view, and the PID-translation invariant — matching the depth of the sibling
/// `AppAudioCapturePIDTranslationTests`.
@available(macOS 14.2, *)
final class AppAudioCaptureScopeTests: XCTestCase {
    // MARK: - AppAudioCapture scope storage

    func testSystemWideScopeStoresNoPids() {
        let capture = AppAudioCapture(scope: .systemWide, outputFileDescriptor: -1)
        XCTAssertEqual(capture.pids, [])
        if case .systemWide = capture.scope {} else {
            XCTFail("Expected .systemWide scope, got \(capture.scope)")
        }
    }

    func testProcessScopePreservesPids() {
        let capture = AppAudioCapture(scope: .processes([111, 222]), outputFileDescriptor: -1)
        XCTAssertEqual(capture.pids, [111, 222])
        if case let .processes(pids) = capture.scope {
            XCTAssertEqual(pids, [111, 222])
        } else {
            XCTFail("Expected .processes scope, got \(capture.scope)")
        }
    }

    func testPidsConvenienceInitMapsToProcessesScope() {
        // Backward-compat convenience init keeps existing callers/tests working.
        let capture = AppAudioCapture(pids: [1234], outputFileDescriptor: -1)
        XCTAssertEqual(capture.pids, [1234])
        if case .processes = capture.scope {} else {
            XCTFail("Convenience init should map to .processes scope")
        }
    }

    // MARK: - PID-translation invariant

    func testTranslatePIDsThrowsForSystemWideScope() {
        // `translatePIDs()` reads the computed `pids`, which is empty for the
        // system-wide scope. Production never calls it on that scope
        // (`makeTapDescription` branches to the global tap first), but the
        // throw is the defensive invariant — a system-wide capture has nothing
        // to translate, mirroring the empty-pids guard.
        let capture = AppAudioCapture(scope: .systemWide, outputFileDescriptor: -1)
        XCTAssertThrowsError(try capture.translatePIDs())
    }

    // MARK: - AudioCaptureSession accepts system-wide scope

    func testAudioCaptureSessionAcceptsSystemWideScope() {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("audiotap-scope-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: tmp) }

        // Construction must succeed for the system-wide scope. We don't start()
        // (that needs real hardware + TCC); the session simply must accept it
        // so the recorder layer can build a calendar-driven system-wide session.
        let session = AudioCaptureSession(scope: .systemWide, appOutputURL: tmp)
        XCTAssertNotNil(session)
    }
}
