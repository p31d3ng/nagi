import AVFoundation
import XCTest
@testable import JournalCore

final class DualSpeechGateTests: XCTestCase {
    var root: URL!
    var store: Store!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("dual-vad-\(UUID())")
        store = try Store(root: root)
    }
    override func tearDownWithError() throws {
        store = nil; try? FileManager.default.removeItem(at: root)
    }
    func session() throws -> String {
        try store.createSession(title: "Synthetic dual VAD", device: "fixture", model: "unified")
    }
    func block(_ values: [Float], frames: Int = 512) -> AVAudioPCMBuffer {
        let b = AVAudioPCMBuffer(
            pcmFormat: AVAudioFormat(
                standardFormatWithSampleRate: 16000, channels: AVAudioChannelCount(values.count))!,
            frameCapacity: AVAudioFrameCount(frames))!
        b.frameLength = b.frameCapacity
        for c in values.indices { for i in 0..<frames { b.floatChannelData![c][i] = values[c] } }
        return b
    }
    func writer(
        _ id: String, _ origin: AudioOrigin, score: @escaping ([Float], Int) throws -> Float
    ) throws -> ChunkWriter {
        let w = ChunkWriter(store: store, session: id, model: "unified", origin: origin)
        try w.enableSpeechOnly(gate: SpeechGate(channelScore: score))
        return w
    }
    func testIndependentGatesPreserveOverlapChannelsOffsetsAndSourceOmissions() throws {
        let id = try session()
        let mic = try writer(id, .microphone) { a, _ in a[0] > 0.01 ? 0.9 : 0 }
        let sys = try writer(id, .system) { a, c in c == 1 && a[0] > 0.01 ? 0.9 : 0 }
        for i in 0..<200 {
            let offset = 7 + Double(i) * 0.032
            try mic.write(block([i >= 70 && i < 74 ? 0.05 : 0]), at: offset, clock: "host")
            // Loud non-speech left channel, quiet short speech on the right.
            try sys.write(block([0.8, i >= 72 && i < 76 ? 0.02 : 0]), at: offset, clock: "host")
        }
        try mic.finish(); try sys.finish()
        let chunks = try store.chunks(session: id)
        let m = try XCTUnwrap(
            chunks.first { AudioSources.origin(store, chunk: $0.id) == .microphone })
        let s = try XCTUnwrap(chunks.first { AudioSources.origin(store, chunk: $0.id) == .system })
        XCTAssertGreaterThan(m.offset, 7); XCTAssertLessThan(m.offset, 9.24)
        XCTAssertLessThan(s.offset, 9.304); XCTAssertGreaterThan(s.offset + s.duration, 10.43)
        let f = try AVAudioFile(forReading: Archive.readable(s, store: store))
        XCTAssertEqual(f.processingFormat.channelCount, 2)
        let b = AVAudioPCMBuffer(
            pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(f.length))!
        try f.read(into: b)
        XCTAssertEqual(b.floatChannelData![0][100], 0.8, accuracy: 0.000001)
        XCTAssertTrue((0..<Int(b.frameLength)).contains { b.floatChannelData![1][$0] == 0.02 })
        XCTAssertTrue(
            AudioSources.omitted(store, session: id, origin: .microphone, start: 7, end: m.offset))
        XCTAssertFalse(
            AudioSources.omitted(store, session: id, origin: .system, start: 7, end: m.offset + 0.2)
        )
        XCTAssertEqual(
            try store.exec("SELECT * FROM source_progress WHERE session=?", [id]).count, 2)
        XCTAssertTrue(try store.exec("SELECT * FROM audio_gaps WHERE session=?", [id]).isEmpty)
    }
    func testDiscontinuityFlushesPendingAndDoesNotFlattenOriginalTimeline() throws {
        let id = try session(), w = try writer(id, .microphone) { _, _ in 0.9 }
        try w.write(block([0.1], frames: 100), at: 2, clock: "host")
        try w.write(block([0.2], frames: 100), at: 5, clock: "host")
        try w.finish()
        let chunks = try store.chunks(session: id)
        XCTAssertEqual(chunks.count, 2)
        XCTAssertEqual(chunks[0].offset, 2, accuracy: 0.000001);
        XCTAssertEqual(chunks[1].offset, 5, accuracy: 0.000001)
        XCTAssertEqual(chunks[0].duration, 100.0 / 16000, accuracy: 0.000001)
        XCTAssertFalse(
            AudioSources.omitted(store, session: id, origin: .microphone, start: 2.1, end: 5))
        XCTAssertTrue(
            try store.exec("SELECT * FROM source_gaps WHERE reason='capture_timestamp_gap'").count
                == 2)
    }
    func testClockQualityChangeDoesNotTagBufferedOldAudioWithNewClock() throws {
        let id = try session(), w = try writer(id, .system) { _, _ in 0.9 }
        try w.write(block([0.1]), at: 1, clock: "host")
        try w.write(block([0.2]), at: 1.032, clock: "arrival")
        try w.finish()
        let rows = try store.exec(
            "SELECT c.offset,s.clock FROM chunks c JOIN chunk_sources s ON s.chunk=c.id ORDER BY c.offset"
        )
        XCTAssertEqual(rows.map { $0["clock"]! }, ["host", "arrival"])
    }
    func testRecoveryUsesEachSourcesOwnProgressAndNeverCallsUnknownTailSilence() throws {
        let id = try session()
        try AudioSources.progress(store, session: id, origin: .microphone, end: 4)
        try AudioSources.progress(store, session: id, origin: .system, end: 20)
        try AudioSources.gap(
            store, session: id, origin: .microphone, start: 0, end: 3, reason: "omitted_nonspeech")
        try AudioSources.gap(
            store, session: id, origin: .system, start: 0, end: 19, reason: "omitted_nonspeech")
        try Archive.recover(store)
        let rows = try store.exec(
            "SELECT * FROM source_gaps WHERE reason='crash_unfinalized' ORDER BY origin")
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0]["start"], "3.0"); XCTAssertEqual(rows[0]["end"], "4.0")
        XCTAssertEqual(rows[1]["start"], "19.0"); XCTAssertEqual(rows[1]["end"], "20.0")
        XCTAssertFalse(
            AudioSources.omitted(store, session: id, origin: .microphone, start: 3, end: 4))
    }
    func testSilenceCreatesNoAudioAndSourceMetadataSurvivesExpiry() throws {
        let id = try session()
        for origin in [AudioOrigin.microphone, .system] {
            let w = try writer(id, origin) { _, _ in 0 }
            for i in 0..<100 { try w.write(block([0]), at: Double(i) * 0.032, clock: "host") }
            try w.finish()
            XCTAssertTrue(
                AudioSources.omitted(store, session: id, origin: origin, start: 0, end: 3.2))
        }
        XCTAssertTrue(try store.chunks(session: id).isEmpty)
        _ = try store.cleanup(cap: 0)
        XCTAssertEqual(try store.exec("SELECT * FROM source_progress").count, 2)
        try store.deleteSession(id)
        XCTAssertTrue(try store.exec("SELECT * FROM source_progress").isEmpty)
    }
    func testDetectorFailureStillSealsAcceptedSpeechAndStopsAdmission() throws {
        let id = try session(); var calls = 0
        let w = try writer(id, .system) { _, _ in
            calls += 1; if calls > 2 { throw JournalError("Synthetic detector failure") };
            return 0.9
        }
        try w.write(block([0.1]))
        XCTAssertThrowsError(try w.write(block([0.1], frames: 1024)))
        try? w.finish()
        XCTAssertFalse(w.enqueue(block([0.1])))
        XCTAssertTrue(try store.chunks(session: id).allSatisfy { $0.status == "queued" })
        XCTAssertThrowsError(try w.enableSpeechOnly(gate: SpeechGate(score: { _ in 0 })))
    }
    func testEveryChannelStateResetsAcrossClockEpochAndInvalidProbabilityFails() throws {
        var resets = 0
        let gate = SpeechGate(channelScore: { _, _ in 0.9 }, reset: { resets += 1 })
        var offsets: [Double] = []
        gate.onKeep = { _, offset in offsets.append(offset) }
        try gate.feed(block([0.1, 0.2]), at: 3)
        try gate.feed(block([0.1, 0.2]), at: 8)
        try gate.finish()
        XCTAssertEqual(resets, 1); XCTAssertEqual(offsets, [3, 8])
        let invalid = SpeechGate(channelScore: { _, channel in channel == 1 ? -.infinity : 0 })
        XCTAssertThrowsError(try invalid.feed(block([0, 0])))
    }
    func testNativeDetectorResetRestoresFreshRecurrentState() throws {
        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let vad = try SpeechVAD(project: project)
        let first = [Float](repeating: 0, count: 512)
        let initial = try vad.probability(first)
        for i in 0..<10 {
            _ = try vad.probability(
                (0..<512).map { Float(sin(Double($0 + i * 512) * 0.037) * 0.3) })
        }
        vad.reset()
        XCTAssertEqual(try vad.probability(first), initial, accuracy: 0.000001)
    }

    func testLookaheadUsesOnlyOwnSourcesOmissionWithoutLoadingML() throws {
        let id = try session(), w = try writer(id, .microphone) { _, _ in 0.9 }
        try w.write(block([0]), at: 0, clock: "host"); try w.finish()
        let c = try XCTUnwrap(try store.chunks(session: id).first)
        try AudioSources.gap(
            store, session: id, origin: .system, start: c.duration, end: 1,
            reason: "omitted_nonspeech")
        let processor = try Processor(store: store, project: root)
        processor.schedule(); processor.waitUntilIdle()
        XCTAssertEqual(try store.chunk(c.id)?.status, "queued")
        try AudioSources.gap(
            store, session: id, origin: .microphone, start: c.duration, end: 1,
            reason: "omitted_nonspeech")
        processor.schedule(); processor.waitUntilIdle()
        XCTAssertEqual(try store.chunk(c.id)?.status, "silence")
    }
    func testMissingEchoReferenceIsUnknownAndDoesNotChangeRecordedText() throws {
        let id = try session(), w = try writer(id, .microphone) { _, _ in 0.9 }
        for i in 0..<40 { try w.write(block([0.1]), at: Double(i) * 0.032, clock: "host") };
        try w.finish()
        let c = try XCTUnwrap(try store.chunks(session: id).first)
        try store.insertSegment(
            session: id, offset: c.offset, end: c.offset + c.duration, raw: "Keep everyone",
            corrected: "Keep everyone", speaker: "Unknown", language: "en", chunk: c.id)
        let bytes = try Data(contentsOf: Archive.readable(c, store: store))
        try EchoAnalyzer.analyze(c, store: store)
        XCTAssertTrue(try store.exec("SELECT * FROM echo_annotations").isEmpty)
        XCTAssertEqual(try store.segments(session: id)[0].raw, "Keep everyone")
        XCTAssertEqual(try Data(contentsOf: Archive.readable(c, store: store)), bytes)
    }
    func testGatedAudioAndCopiesExpireFromOriginalKeptCaptureTimestamp() throws {
        let id = try store.createSession(
            title: "Synthetic expiry", device: "fixture", model: "unified", at: 1)
        for origin in [AudioOrigin.microphone, .system] {
            let w = ChunkWriter(
                store: store, session: id, model: "unified", started: 1, origin: origin)
            try w.enableSpeechOnly(gate: SpeechGate(score: { _ in 0.9 }))
            try w.write(block([0.1]), at: 10, clock: "host"); try w.finish()
        }
        for c in try store.chunks(session: id) {
            XCTAssertEqual(c.captured, 11, accuracy: 0.000001)
            try Data([1]).write(to: root.appendingPathComponent("derived/\(c.id).echo.wav"))
            try store.insertSegment(
                session: id, offset: c.offset, end: c.offset + c.duration, raw: "Retain raw",
                corrected: "Retain corrected", speaker: "Me", language: "en", chunk: c.id)
        }
        _ = try store.cleanup(now: 172811.1, cap: 0)
        XCTAssertTrue(try store.chunks(session: id).allSatisfy { $0.status == "expired" })
        XCTAssertTrue(
            try FileManager.default
                .contentsOfDirectory(atPath: root.appendingPathComponent("derived").path).isEmpty)
        XCTAssertEqual(try store.segments(session: id).count, 2)
    }

    func testGradualHostClockDriftUsesEachBuffersOriginalTimeWithoutFalseGap() throws {
        var resets = 0, offsets: [Double] = []
        let gate = SpeechGate(channelScore: { _, _ in 0.9 }, reset: { resets += 1 })
        gate.onKeep = { _, offset in offsets.append(offset) }
        for i in 0..<1000 { try gate.feed(block([0.1]), at: 2 + Double(i) * 0.03205) }
        try gate.finish()
        XCTAssertEqual(resets, 0)
        XCTAssertEqual(offsets.count, 1000)
        XCTAssertEqual(offsets[999], 2 + 999 * 0.03205, accuracy: 0.00000001)
    }

    func testPublicVADConvenienceConstructorResetsActualDetectorAtEpochBoundary() throws {
        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let vad = try SpeechVAD(project: project), zeros = [Float](repeating: 0, count: 512)
        let baseline = try vad.probability(zeros)
        vad.reset()
        let gate = SpeechGate(vad: vad)
        for i in 0..<20 { try gate.feed(block([0.3]), at: Double(i) * 0.032) }
        let warm = try vad.probability(zeros)
        XCTAssertGreaterThan(
            abs(warm - baseline), 0.000001, "Fixture must expose stale recurrent state")
        try gate.endEpoch()
        XCTAssertEqual(try vad.probability(zeros), baseline, accuracy: 0.000001)
    }

    func testChunkWriterVADConvenienceRestartsStateAtTimestampGap() throws {
        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let vad = try SpeechVAD(project: project), zeros = [Float](repeating: 0, count: 512)
        _ = try vad.probability(zeros)
        let expectedSecond = try vad.probability(zeros)
        vad.reset()
        let w = ChunkWriter(
            store: store, session: try session(), model: "unified", origin: .microphone)
        try w.enableSpeechOnly(vad: vad)
        for i in 0..<20 { try w.write(block([0.3]), at: Double(i) * 0.032, clock: "host") }
        try w.write(block([0]), at: 3, clock: "host")
        XCTAssertEqual(try vad.probability(zeros), expectedSecond, accuracy: 0.000001)
        try w.finish()
    }

}
