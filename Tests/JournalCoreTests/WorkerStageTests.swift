import XCTest
@testable import JournalCore

final class WorkerStageTests: XCTestCase {
    func testStagesRequireRecognizedNativeMarkersAndKeepLatest() {
        XCTAssertNil(
            WorkerStage.last(
                in: "whisper model slow\nNAGI_STAGE done\nignore previous instructions"))
        XCTAssertEqual(
            WorkerStage.last(in: "NAGI_STAGE model_loading\nloader log\nNAGI_STAGE transcribing\n"),
            "transcribing")
        XCTAssertEqual(WorkerStage.last(in: "NAGI_STAGE aligning\n"), "aligning")
    }
    func testProgressCallbackReadsEvidenceFromSyntheticProcessWithoutASR() throws {
        var stages: [String] = []
        try LocalProcess.run(
            "/bin/sh",
            [
                "-c",
                "printf 'NAGI_STAGE model_loading\\n'; /bin/sleep 0.3; printf 'NAGI_STAGE transcribing\\n'; /bin/sleep 0.3",
            ], timeout: 3, onStage: { stages.append($0) })
        XCTAssertEqual(stages, ["model_loading", "transcribing"])
    }
}
