import AVFoundation
import XCTest
@testable import JournalCore

final class LiveTests: XCTestCase {
    var root: URL!
    var store: Store!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "nagi-live-test-\(UUID())")
        store = try Store(root: root)
    }
    override func tearDownWithError() throws {
        store = nil; try? FileManager.default.removeItem(at: root)
    }
    func session() throws -> String {
        try store.createSession(title: "Synthetic", device: "fixture", model: "unified")
    }
    func testPreviewWindowAndPagingBound() throws {
        let id = try session()
        for i in 0..<250 {
            try store.exec(
                "INSERT INTO live_previews VALUES(?,?,?,?,0)", [id, i * 30, 30, "word \(i)"])
        }
        let rows = try LiveDocument.page(store, session: id, limit: 10000)
        XCTAssertEqual(rows.count, 200); XCTAssertEqual(rows.first?.text, "word 50")
        let older = try LiveDocument.page(store, session: id, before: rows.first!.offset)
        XCTAssertEqual(older.count, 50); XCTAssertEqual(older.last?.text, "word 49")
    }
    func testPreviewReconciliationPreservesCorrectionAndWaitsForAllChunks() throws {
        let id = try session()
        let a = try store.registerChunk(
            session: id, path: "audio/a.caf", captured: Date().timeIntervalSince1970, offset: 0,
            model: "unified")
        let b = try store.registerChunk(
            session: id, path: "audio/b.caf", captured: Date().timeIntervalSince1970, offset: 10,
            model: "unified")
        try store.seal(a, duration: 10); try store.seal(b, duration: 10)
        try store.exec(
            "INSERT INTO segments(session,offset,end,raw,corrected,speaker,language,chunk) VALUES(?,0,10,'raw','my corrected text','Me','en',?)",
            [id, a])
        try store.exec("INSERT INTO live_previews VALUES(?,0,20,'preview',1)", [id])
        try store.exec("UPDATE chunks SET status='done' WHERE id=?", [a])
        XCTAssertEqual(try LiveDocument.page(store, session: id).map(\.text), ["preview"])
        try store.exec("UPDATE chunks SET status='done' WHERE id=?", [b])
        XCTAssertEqual(try LiveDocument.page(store, session: id).map(\.text), ["my corrected text"])
        XCTAssertEqual(try store.segments(session: id).first?.raw, "raw")
    }
    func testExpiredAudioKeepsPreviewText() throws {
        let id = try session()
        let chunk = try store.registerChunk(
            session: id, path: "audio/expired.caf", captured: 1, offset: 0, model: "unified")
        try store.seal(chunk, duration: 10)
        try store.exec("UPDATE chunks SET status='expired' WHERE id=?", [chunk])
        try store.exec("INSERT INTO live_previews VALUES(?,0,10,'preserved words',1)", [id])
        let row = try XCTUnwrap(LiveDocument.page(store, session: id).first)
        XCTAssertEqual(row.text, "preserved words")
        XCTAssertTrue(row.detail.contains("expired"))
    }
    func testPreviewCountsTowardCapacityAndSessionDeletion() throws {
        let id = try session()
        try store.exec(
            "INSERT INTO live_previews VALUES(?,0,30,?,1)",
            [id, String(repeating: "x", count: 4096)])
        try store.finish(id)
        _ = try store.cleanup(cap: 1024)
        XCTAssertTrue(try store.exec("SELECT * FROM live_previews").isEmpty)
        XCTAssertTrue(try store.exec("SELECT * FROM sessions").isEmpty)
    }
    func testWrittenHookIsAfterSuccessfulArchiveAndExactAtBoundary() throws {
        let id = try session()
        let writer = ChunkWriter(store: store, session: id, model: "unified")
        var observed = 0
        var positions: [Double] = []
        writer.onWritten = { buffer, offset in
            observed += Int(buffer.frameLength); positions.append(offset)
        }
        let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 160001)!
        b.frameLength = b.frameCapacity
        memset(b.floatChannelData![0], 0, Int(b.frameLength) * 4)
        try writer.write(b); try writer.finish()
        XCTAssertEqual(writer.writtenDuration, 10.0000625, accuracy: 0.0000001)
        XCTAssertEqual(observed, 160001); XCTAssertEqual(positions, [0, 10])
        XCTAssertEqual(try store.chunks(session: id).count, 2)
    }
    func testLiveLeaseCompressesWithoutRunningASRThenResumesDurableQueue() throws {
        let id = try session()
        let processor = try Processor(store: store, project: root)
        let acquired = expectation(description: "live lease acquired")
        processor.prepareLive { acquired.fulfill() }
        wait(for: [acquired], timeout: 3)
        let writer = ChunkWriter(store: store, session: id, model: "unified")
        let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16000)!
        b.frameLength = b.frameCapacity
        for i in 0..<16000 { b.floatChannelData![0][i] = Float(sin(Double(i) * 0.07) * 0.1) }
        try writer.write(b); try writer.finish(); try store.finish(id)
        processor.schedule(); processor.waitUntilIdle()
        let compressed = try XCTUnwrap(store.chunks(session: id).first)
        XCTAssertEqual(compressed.status, "queued")
        XCTAssertTrue(compressed.path.hasSuffix(".gz"))
        processor.resumeBatch(); processor.waitUntilIdle()
        XCTAssertEqual(try store.chunks(session: id).first?.status, "failed")
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: store.root.appendingPathComponent(compressed.path).path))
    }
    func testCrashRecoveryClosesLivePreviewWithoutDeletingTranscript() throws {
        let id = try session()
        try store.exec("INSERT INTO live_previews VALUES(?,0,1,'surviving preview',0)", [id])
        try Archive.recover(store)
        XCTAssertEqual(try store.exec("SELECT final FROM live_previews").first?["final"], "1")
        XCTAssertEqual(try LiveDocument.page(store, session: id).first?.text, "surviving preview")
    }
    func testWarmupQueueBoundedAndArchiveUnaffected() throws {
        let id = try session()
        let live = LiveTranscriber(store: store, session: id, project: root)
        let finished = expectation(description: "warmup overload releases")
        live.onFinished = { finished.fulfill() }
        let writer = ChunkWriter(store: store, session: id, model: "unified")
        writer.onWritten = { b, offset in live.offer(b, offset: offset) }
        let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1280)!
        b.frameLength = b.frameCapacity
        memset(b.floatChannelData![0], 0, 1280 * 4)
        for _ in 0..<100 { try writer.write(b) }
        try writer.finish()
        wait(for: [finished], timeout: 3)
        XCTAssertEqual(writer.writtenDuration, 8)
        let chunk = try XCTUnwrap(store.chunks(session: id).first)
        XCTAssertEqual(chunk.duration, 8)
    }
    func testMissingModelAndStopBeforeStartReleaseWorker() throws {
        let id = try session()
        let live = LiveTranscriber(store: store, session: id, project: root)
        let done = expectation(description: "failed worker releases")
        live.onFinished = { done.fulfill() }
        live.start(); wait(for: [done], timeout: 5)
        let other = LiveTranscriber(store: store, session: id, project: root)
        let canceled = expectation(description: "cancel before start releases once")
        other.onFinished = { canceled.fulfill() }
        other.stop(); other.start(); wait(for: [canceled], timeout: 5)
    }
}
