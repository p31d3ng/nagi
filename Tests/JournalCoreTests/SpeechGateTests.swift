import AVFoundation
import XCTest
@testable import JournalCore

final class SpeechGateTests: XCTestCase {
    func buffer(
        _ frames: Int, rate: Double = 16000, channels: AVAudioChannelCount = 1,
        rightOnly: Bool = false
    ) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: channels)!
        let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!;
        b.frameLength = b.frameCapacity
        for c in 0..<Int(channels) {
            for i in 0..<frames {
                b.floatChannelData![c][i] = rightOnly && c == 0 ? 0 : Float(i % 31) / 3100
            }
        }
        return b
    }
    func testSilenceCreatesNoFilesAndDurableElapsedGap() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try Store(root: root);
        let id = try store.createSession(title: "silence", device: "synthetic", model: "unified")
        let writer = ChunkWriter(store: store, session: id, model: "unified")
        let gate = SpeechGate(score: { _ in 0 }); try writer.enableSpeechOnly(gate: gate)
        for _ in 0..<100 { try writer.write(buffer(4096)) }; try writer.finish();
        try writer.finish()
        XCTAssertEqual(writer.writtenDuration, 25.6, accuracy: 0.0001)
        XCTAssertTrue(try store.chunks(session: id).isEmpty)
        XCTAssertTrue(
            try FileManager.default
                .contentsOfDirectory(atPath: root.appendingPathComponent("audio").path).isEmpty)
        XCTAssertTrue(store.isOmittedSilence(session: id, start: 0, end: 25.6))
        XCTAssertLessThanOrEqual(gate.peakBufferedFrames, 16512)
        try Archive.recover(store)
        XCTAssertEqual(
            try store.exec("SELECT status FROM sessions WHERE id=?", [id]).first?["status"],
            "interrupted")
    }
    func testShortSpeechPrePostRollExactOriginalSamplesAndOffsets() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try Store(root: root);
        let id = try store.createSession(title: "short", device: "synthetic", model: "unified")
        var index = 0;
        let gate = SpeechGate(score: { _ in
            defer { index += 1 }; return (100...102).contains(index) ? 0.9 : 0
        })
        let writer = ChunkWriter(store: store, session: id, model: "unified");
        try writer.enableSpeechOnly(gate: gate)
        let source = buffer(160000); try writer.write(source); try writer.finish()
        let chunks = try store.chunks(session: id); XCTAssertEqual(chunks.count, 1)
        let chunk = try XCTUnwrap(chunks.first)
        XCTAssertLessThan(chunk.offset, 3.2);
        XCTAssertGreaterThanOrEqual(chunk.offset + chunk.duration, 4.296)
        XCTAssertEqual(
            chunk.captured - chunk.offset, try XCTUnwrap(try store.sessions().first).started,
            accuracy: 0.05)
        let file = try AVAudioFile(forReading: store.root.appendingPathComponent(chunk.path));
        let saved = buffer(Int(file.length)); try file.read(into: saved)
        let start = Int((chunk.offset * 16000).rounded())
        for i in 0..<Int(saved.frameLength) {
            XCTAssertEqual(saved.floatChannelData![0][i], source.floatChannelData![0][start + i])
        }
        XCTAssertTrue(store.isOmittedSilence(session: id, start: 0, end: chunk.offset))
    }
    func testStereoSelectsStrongChannelAndPreservesBothAtNonIntegerBlockRate() throws {
        let gate = SpeechGate(score: { samples in
            XCTAssertGreaterThan(samples.max() ?? 0, 0.005); return 0.9
        })
        var count = 0;
        gate.onKeep = { b, offset in
            XCTAssertEqual(b.format.sampleRate, 44100); XCTAssertEqual(b.format.channelCount, 2)
            XCTAssertEqual(offset, Double(count) / 44100, accuracy: 1e-8)
            for i in 0..<Int(b.frameLength) { XCTAssertEqual(b.floatChannelData![0][i], 0) }
            count += Int(b.frameLength)
        }
        try gate.feed(buffer(88217, rate: 44100, channels: 2, rightOnly: true)); try gate.finish();
        try gate.finish()
        XCTAssertEqual(count, 88217)
    }
    func testTrailingShortPartialSpeechIsNotDiscarded() throws {
        let gate = SpeechGate(score: { _ in 0.9 }); var frames = 0
        gate.onKeep = { b, _ in frames += Int(b.frameLength) }
        try gate.feed(buffer(100)); try gate.finish(); XCTAssertEqual(frames, 100)
    }
    func testDetectorFailureStillSealsAlreadySavedSpeech() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try Store(root: root);
        let id = try store.createSession(title: "failure", device: "synthetic", model: "unified")
        var count = 0
        let gate = SpeechGate(score: { _ in
            count += 1; if count > 3 { throw JournalError("Injected VAD failure") }; return 0.9
        })
        let writer = ChunkWriter(store: store, session: id, model: "unified");
        try writer.enableSpeechOnly(gate: gate)
        XCTAssertThrowsError(try writer.write(buffer(4096)))
        try writer.finish()
        let chunks = try store.chunks(session: id); XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunks[0].duration, 0.096, accuracy: 0.0001)
        XCTAssertEqual(chunks[0].status, "queued")
        try Archive.recover(store);
        XCTAssertEqual(try store.chunks(session: id)[0].duration, 0.096, accuracy: 0.0001)
    }
}
