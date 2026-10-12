import Foundation
import XCTest
@testable import Nagi

@MainActor final class CaptureRunStateTests: XCTestCase {
    func testQueuedOldFailureCannotStopNewRecording() {
        let state = CaptureRunState()
        let oldSource = NSObject(), newSource = NSObject()
        let old = state.begin()
        state.bind(old, session: "old", source: oldSource)
        var stops = 0
        let queuedError = {
            if state.fail(old, session: "old", source: oldSource, message: "Old stream stopped") {
                stops += 1
            }
        }
        state.end(old)
        let new = state.begin()
        state.bind(new, session: "new", source: newSource)
        queuedError()
        XCTAssertEqual(stops, 0)
        XCTAssertEqual(state.outcome(new, error: CancellationError()), .cancelled)
        XCTAssertTrue(
            state.fail(new, session: "new", source: newSource, message: "Current receiver lost"))
        XCTAssertEqual(
            state.outcome(new, error: CancellationError()), .failed("Current receiver lost"))
    }
    func testDifferentStreamInSameSessionCannotReportFailure() {
        let state = CaptureRunState(), oldSource = NSObject(), currentSource = NSObject()
        let run = state.begin()
        state.bind(run, session: "same", source: currentSource)
        XCTAssertFalse(
            state.fail(run, session: "same", source: oldSource, message: "Stale callback"))
        XCTAssertEqual(state.outcome(run, error: CancellationError()), .cancelled)
    }
    func testSourceFailureSurvivesCancellationCleanupAndKeepsFirstCause() {
        let state = CaptureRunState(), source = NSObject()
        let run = state.begin()
        state.bind(run, session: "startup", source: source)
        XCTAssertTrue(
            state.fail(
                run, session: "startup", source: source,
                message: "System audio permission was revoked. Grant access and retry."))
        XCTAssertTrue(
            state.fail(run, session: "startup", source: source, message: "Secondary cleanup error"))
        XCTAssertEqual(
            state.outcome(run, error: CancellationError()),
            .failed("System audio permission was revoked. Grant access and retry."))
        let cleanupError = NSError(
            domain: "Synthetic", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Could not flush audio"])
        XCTAssertEqual(
            state.outcome(run, error: CancellationError()).preservingFailure(cleanupError),
            .failed("System audio permission was revoked. Grant access and retry."))
        XCTAssertEqual(
            CaptureRunState.Outcome.cancelled.preservingFailure(cleanupError),
            .failed("Could not flush audio"))
        state.end(run)
        XCTAssertFalse(state.fail(run, session: "startup", source: source, message: "Late failure"))
    }
    func testUserCancelAndDirectStartupFailureStayDistinct() {
        let state = CaptureRunState()
        let run = state.begin()
        XCTAssertEqual(state.outcome(run, error: CancellationError()), .cancelled)
        let failure = NSError(
            domain: "SyntheticCapture", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Receiver unavailable"])
        XCTAssertEqual(state.outcome(run, error: failure), .failed("Receiver unavailable"))
    }
}
