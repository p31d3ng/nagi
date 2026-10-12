import Combine
import XCTest
@testable import Nagi

@MainActor final class InputLevelsTests: XCTestCase {
    func testLevelUpdatesDoNotInvalidateCaptureClockOrRecordingHeader() {
        let meter = CaptureMeter()
        meter.begin(session: "clock", systemEnabled: true, now: 0, automatic: false)
        var changes = 0
        let subscription = meter.clock.objectWillChange.sink { changes += 1 }
        for index in 0..<100 {
            meter.mailbox.offer(Double(index) / 100, system: false, session: "clock", at: 0.1)
            meter.poll(now: 0.2)
        }
        XCTAssertEqual(changes, 0)
        meter.elapsed = 10; meter.elapsed = 10
        XCTAssertEqual(changes, 1)
        subscription.cancel()
    }
    func testOpeningMeterIsStoppedWithoutCaptureTimerOrPermissionAction() {
        let meter = CaptureMeter()
        meter.poll(now: 20)
        XCTAssertEqual(meter.microphone.state, .stopped);
        XCTAssertEqual(meter.system.state, .stopped)
    }
    func testFramesSilentNoFramesAndStopAreDistinct() {
        let meter = CaptureMeter()
        meter.begin(session: "a", systemEnabled: true, now: 0, automatic: false)
        meter.poll(now: 0.2); XCTAssertEqual(meter.microphone.state, .waiting)
        meter.mailbox.offer(0, system: false, session: "a", at: 0.3)
        meter.poll(now: 0.4); XCTAssertEqual(meter.microphone.state, .quiet)
        meter.poll(now: 0.6); XCTAssertEqual(meter.microphone.state, .quiet)
        meter.mailbox.offer(0.1, system: false, session: "a", at: 0.8)
        meter.poll(now: 0.9); XCTAssertEqual(meter.microphone.state, .receiving)
        meter.poll(now: 1.4); XCTAssertEqual(meter.microphone.state, .receiving)
        meter.poll(now: 2.4); XCTAssertEqual(meter.microphone.state, .noFrames)
        meter.stop(); XCTAssertEqual(meter.microphone.state, .stopped)
    }
    func testSourcesAreIndependentAndLateOldSessionCannotChangeNewMeter() {
        let meter = CaptureMeter()
        meter.begin(session: "old", systemEnabled: true, now: 0, automatic: false)
        meter.mailbox.offer(0.1, system: true, session: "old", at: 0.1)
        meter.poll(now: 0.2)
        XCTAssertEqual(meter.system.state, .receiving);
        XCTAssertEqual(meter.microphone.state, .waiting)
        meter.begin(session: "new", systemEnabled: false, now: 1, automatic: false)
        meter.mailbox.offer(1, system: false, session: "old", at: 1.1)
        meter.mailbox.offer(1, system: true, session: "new", at: 1.1)
        meter.poll(now: 1.2)
        XCTAssertEqual(meter.microphone.state, .waiting);
        XCTAssertEqual(meter.system.state, .stopped)
    }
    func testMailboxCoalescesManyCallbacksIntoOnePublicationAndFiniteLevels() {
        let meter = CaptureMeter();
        meter.begin(session: "s", systemEnabled: false, now: 0, automatic: false)
        var publications = 0
        let sink = meter.$microphone.dropFirst().sink { _ in publications += 1 }
        let begin = Date()
        for i in 0..<100000 {
            meter.mailbox.offer(i == 9 ? 0.5 : 0.01, system: false, session: "s", at: 0.1)
        }
        XCTAssertEqual(publications, 0)
        meter.poll(now: 0.2)
        XCTAssertEqual(publications, 1)
        XCTAssertEqual(meter.microphone.db, 20 * log10(0.5), accuracy: 0.01)
        meter.mailbox.offer(.nan, system: false, session: "s", at: 0.3)
        meter.mailbox.offer(-1, system: false, session: "s", at: 0.3)
        meter.stop(); sink.cancel()
        print(
            "INPUT_LEVEL_PROFILE callbacks=100000 wall_s=\(Date().timeIntervalSince(begin)) publications=1 bounded_slots=2"
        )
    }
    func testProgressDoesNotLabelSlowOrSilentWorkFailed() {
        XCTAssertTrue(
            TranscriptionProgress.liveHint(model: "whisper", dual: false).contains("no incremental")
        )
        XCTAssertTrue(
            TranscriptionProgress.describe(
                model: "whisper", recording: true, speechOnly: true, statuses: [:], transcripts: 0
            )
            .contains("VAD"))
        XCTAssertTrue(
            TranscriptionProgress.describe(
                model: "whisper", recording: false, speechOnly: false,
                statuses: ["queued": 3, "processing": 1], transcripts: 2
            )
            .contains("3 queued"))
        XCTAssertTrue(
            TranscriptionProgress.describe(
                model: "whisper", recording: false, speechOnly: false, statuses: ["failed": 1],
                transcripts: 0
            )
            .contains("Retry"))
        XCTAssertTrue(
            TranscriptionProgress.describe(
                model: "whisper", recording: false, speechOnly: false, statuses: ["silence": 1],
                transcripts: 0
            )
            .contains("does not prove"))
        XCTAssertFalse(
            TranscriptionProgress.queue([["status": "queued", "n": "3", "seconds": "23.5"]])
                .contains("failed"))
        XCTAssertTrue(
            TranscriptionProgress.queue([["status": "queued", "n": "3", "seconds": "23.5"]])
                .contains("23.5"))
    }
}
