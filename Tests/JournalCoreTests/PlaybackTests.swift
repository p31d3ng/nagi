import AVFoundation
import XCTest
@testable import JournalCore

@MainActor final class PlaybackTests: XCTestCase {
    var root: URL!
    var store: Store!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "nagi-playback-test-\(UUID())")
        store = try Store(root: root)
    }
    override func tearDownWithError() throws {
        store = nil; try? FileManager.default.removeItem(at: root)
    }
    func fixture(offsets: [Double] = [0, 0.35, 0.7], expired: Bool = false) throws -> String {
        let id = try store.createSession(
            title: "Synthetic playback", device: "fixture", model: "unified")
        let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        for offset in offsets {
            let path = "audio/\(UUID()).caf"
            let chunk = try store.registerChunk(
                session: id, path: path, captured: expired ? 1 : Date().timeIntervalSince1970,
                offset: offset, model: "unified")
            let f = try AVAudioFile(
                forWriting: store.root.appendingPathComponent(path), settings: format.settings)
            let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 5600)!
            b.frameLength = b.frameCapacity
            for i in 0..<5600 { b.floatChannelData![0][i] = Float(sin(Double(i) * 0.03) * 0.1) }
            try f.write(from: b); f.close(); try store.seal(chunk, duration: 0.35)
            if !expired { try Archive.compress(try XCTUnwrap(store.chunk(chunk)), store: store) }
        }
        try store.finish(id); return id
    }
    func until(_ condition: @escaping () -> Bool, timeout: Double = 4) async throws {
        let end = Date().addingTimeInterval(timeout)
        while !condition() && Date() < end { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertTrue(condition())
    }
    func testContinuousChunkAdvancePauseResumeAndExactEnd() async throws {
        let id = try fixture(); let player = ConversationPlayback(store: store); player.volume = 0
        player.start(session: id)
        try await until({ player.state == .playing })
        try await Task.sleep(nanoseconds: 120_000_000)
        player.pause(); let at = player.position
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(player.state, .paused); XCTAssertEqual(player.position, at, accuracy: 0.01)
        player.resume(); try await until({ player.state == .ended })
        XCTAssertEqual(player.position, 1.05, accuracy: 0.002)
        XCTAssertTrue(
            try FileManager.default
                .contentsOfDirectory(atPath: root.appendingPathComponent("derived").path).isEmpty)
    }
    func testRapidStartSeekCancelDoesNotReviveOldPreparation() async throws {
        let id = try fixture(); let player = ConversationPlayback(store: store); player.volume = 0
        for _ in 0..<8 { player.start(session: id, at: 0.2); player.stop() }
        try await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertEqual(player.state, .idle)
        player.start(session: id, at: 0.65); try await until({ player.state == .ended })
        XCTAssertEqual(player.position, 1.05, accuracy: 0.002)
    }
    func testMissingExpiredAndGapNeverSilentlySkipped() async throws {
        let expired = try fixture(expired: true); let player = ConversationPlayback(store: store);
        player.volume = 0
        player.start(session: expired); try await until({ player.state == .unavailable })
        let gap = try fixture(offsets: [0, 1]); var messages: [String] = [];
        player.onMessage = { messages.append($0) }
        player.start(session: gap); try await until({ player.state == .ended })
        XCTAssertTrue(messages.contains(where: { $0.contains("gap") }));
        XCTAssertEqual(player.position, 0.35, accuracy: 0.002)
        let absent = try fixture(); let first = try XCTUnwrap(store.chunks(session: absent).first)
        try FileManager.default.removeItem(at: root.appendingPathComponent(first.path))
        player.start(session: absent); try await until({ player.state == .unavailable })
    }
    func testOverlappingChunkRangesAreTrimmedWithoutRepeatedAudio() async throws {
        let id = try fixture(offsets: [0, 0.25, 0.5]);
        let player = ConversationPlayback(store: store); player.volume = 0
        player.start(session: id); try await until({ player.state == .ended })
        XCTAssertEqual(player.position, 0.85, accuracy: 0.002)
    }
    func testDocumentedOmittedSilenceSkipsButKeepsElapsedClock() async throws {
        let id = try fixture(offsets: [0, 1]); try store.recordGap(session: id, start: 0.35, end: 1)
        let player = ConversationPlayback(store: store); player.volume = 0;
        var notices: [String] = []
        player.onSkippedSilence = { notices.append($0) }
        player.start(session: id); try await until({ player.state == .ended })
        XCTAssertEqual(player.position, 1.35, accuracy: 0.002); XCTAssertEqual(notices.count, 1)
    }
    func testExpiryWhilePausedStopsAndRemovesDerivedAudio() async throws {
        let id = try fixture(); let player = ConversationPlayback(store: store); player.volume = 0
        player.start(session: id); try await until({ player.state == .playing })
        player.pause()
        try store.exec("UPDATE chunks SET captured=1 WHERE session=?", [id])
        try store.cleanup()
        player.resume(); XCTAssertEqual(player.state, .unavailable)
        try await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertTrue(
            try FileManager.default
                .contentsOfDirectory(atPath: root.appendingPathComponent("derived").path).isEmpty)
    }
    func testMissingNextStopsAtBoundaryAndSessionSwitchCancelsOldAudio() async throws {
        let id = try fixture(); let player = ConversationPlayback(store: store); player.volume = 0
        let chunks = try store.chunks(session: id)
        try FileManager.default.removeItem(at: root.appendingPathComponent(chunks[1].path))
        var messages: [String] = []; player.onMessage = { messages.append($0) }
        player.start(session: id); try await until({ player.state == .ended })
        XCTAssertEqual(player.position, 0.35, accuracy: 0.002)
        XCTAssertFalse(messages.isEmpty)
        let other = try fixture()
        player.start(session: id); player.start(session: other, at: 0.7)
        try await until({ player.state == .ended })
        XCTAssertEqual(player.position, 1.05, accuracy: 0.002)
    }
    func testSourcePlaybackDoesNotCrossOriginsAndSeekKeepsSource() async throws {
        let id = try fixture(offsets: [0, 0.35])
        let chunks = try store.chunks(session: id)
        for c in chunks {
            try store.exec("UPDATE chunk_sources SET origin='system' WHERE chunk=?", [c.id])
        }
        let mic = try store.registerChunk(
            session: id, path: chunks[0].path, captured: Date().timeIntervalSince1970, offset: 0,
            model: "unified", origin: .microphone)
        try store.seal(mic, duration: 0.35)
        let player = ConversationPlayback(store: store); player.volume = 0
        player.start(session: id, origin: .microphone)
        try await until({ player.state == .ended })
        XCTAssertEqual(player.position, 0.35, accuracy: 0.002)
        player.start(session: id, origin: .system)
        try await until({ player.state == .playing })
        player.seek(to: 0.4)
        try await until({ player.state == .ended })
        XCTAssertEqual(player.position, 0.7, accuracy: 0.002)
        XCTAssertEqual(player.origin, .system)
    }

}
