import AVFoundation
import CoreMedia
import XCTest
@testable import JournalCore

final class AudioSourcesTests: XCTestCase {
    var root: URL!
    var store: Store!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "nagi-sources-\(UUID())")
        store = try Store(root: root)
    }
    override func tearDownWithError() throws {
        store = nil; try? FileManager.default.removeItem(at: root)
    }
    func buffer(
        _ frames: Int = 4096, rate: Double = 16000, frequency: Double = 271,
        channels: AVAudioChannelCount = 1
    )
        -> AVAudioPCMBuffer
    {
        let b = AVAudioPCMBuffer(
            pcmFormat: AVAudioFormat(standardFormatWithSampleRate: rate, channels: channels)!,
            frameCapacity: AVAudioFrameCount(frames))!
        b.frameLength = b.frameCapacity
        for i in 0..<frames {
            b.floatChannelData![0][i] = Float(
                sin(Double(i) * frequency * 2 * Double.pi / rate) * 0.1)
        }
        return b
    }
    func session() throws -> String {
        try store.createSession(title: "Synthetic sources", device: "fixture", model: "unified")
    }
    func testSourceClockGapsAndFinishRejectsLateBuffers() throws {
        let id = try session()
        let writer = ChunkWriter(
            store: store, session: id, model: "unified", origin: .system, hostAnchor: 1)
        let b = buffer(1600)
        XCTAssertTrue(writer.enqueue(b, at: 0.25, clock: "host"))
        XCTAssertTrue(writer.enqueue(b, at: 1.25, clock: "host"))
        try writer.finish()
        XCTAssertFalse(writer.enqueue(b, at: 2, clock: "host"))
        let chunks = try store.chunks(session: id)
        XCTAssertEqual(chunks.count, 2)
        XCTAssertEqual(chunks[0].offset, 0.25, accuracy: 0.000001)
        XCTAssertEqual(
            try XCTUnwrap(AudioSources.firstOffset(store, session: id, origin: .system)), 0.25,
            accuracy: 0.000001)
        XCTAssertNil(try AudioSources.firstOffset(store, session: id, origin: .microphone))
        XCTAssertEqual(chunks[1].offset, 1.25, accuracy: 0.000001)
        XCTAssertEqual(chunks[0].duration, 0.1, accuracy: 0.000001)
        XCTAssertEqual(AudioSources.origin(store, chunk: chunks[1].id), .system)
        let gaps = try store.exec("SELECT * FROM source_gaps WHERE session=? ORDER BY start", [id])
        XCTAssertEqual(gaps.count, 2)
        XCTAssertEqual(Double(gaps[1]["start"]!)!, 0.35, accuracy: 0.00001)
        XCTAssertThrowsError(try writer.write(b, at: 0.1, clock: "host"))
    }
    func testInvalidDriverTimestampsCannotCreateFutureExpiryOrConfidentAlignment() {
        let good = AudioSources.timestamp(sample: 12, anchor: 10, now: 12.1)
        XCTAssertEqual(good.offset, 2); XCTAssertEqual(good.clock, "host")
        for value in [Double.infinity, Double.nan, 1, 1e12] {
            let fallback = AudioSources.timestamp(sample: value, anchor: 10, now: 12)
            XCTAssertEqual(fallback.offset, 2); XCTAssertEqual(fallback.clock, "arrival")
        }
        XCTAssertEqual(AudioSources.timestamp(sample: nil, anchor: 10, now: 12).clock, "arrival")
    }
    func testMixedSourcesNeverBecomeNeighborsOrASRContext() throws {
        let id = try session()
        let mic = ChunkWriter(store: store, session: id, model: "unified", origin: .microphone)
        let sys = ChunkWriter(store: store, session: id, model: "unified", origin: .system)
        for _ in 0..<50 { try mic.write(buffer()); try sys.write(buffer(frequency: 900)) }
        try mic.finish(); try sys.finish()
        let chunks = try store.chunks(session: id)
        let first = try XCTUnwrap(
            chunks.first { AudioSources.origin(store, chunk: $0.id) == .microphone })
        let next = try XCTUnwrap(store.neighbor(first, before: false))
        XCTAssertEqual(AudioSources.origin(store, chunk: next.id), .microphone)
        XCTAssertEqual(next.offset, 10, accuracy: 0.000001)
        let central = root.appendingPathComponent("derived/\(first.id).central.wav")
        let context = root.appendingPathComponent("derived/\(first.id).context.wav")
        try Archive.wav(Archive.readable(first, store: store), to: central)
        XCTAssertEqual(try Archive.context(first, central: central, to: context, store: store), 0)
        let f = try AVAudioFile(forReading: context)
        XCTAssertEqual(Double(f.length) / f.processingFormat.sampleRate, 10.75, accuracy: 0.001)
        let rms = try Archive.rms(context)
        XCTAssertGreaterThan(rms, 0.05)
    }
    func testSourcesSurviveRecoveryAndExpireWithAllDerivedAudio() throws {
        let id = try session()
        for origin in [AudioOrigin.microphone, .system] {
            let w = ChunkWriter(
                store: store, session: id, model: "unified", started: 1, origin: origin)
            try w.write(buffer()); try w.finish()
            try AudioSources.status(store, session: id, origin: origin, status: "recording")
        }
        try store.recover()
        XCTAssertEqual(
            try store.exec("SELECT * FROM source_status WHERE status='interrupted'").count, 2)
        for c in try store.chunks(session: id) {
            try Data([1, 2, 3]).write(to: root.appendingPathComponent("derived/\(c.id).echo.wav"))
            try store.insertSegment(
                session: id, offset: c.offset, end: c.offset + c.duration, raw: "Keep original",
                corrected: "Keep corrected", speaker: "Me", language: "en", chunk: c.id)
            try Archive.compress(c, store: store)
        }
        _ = try store.cleanup(now: 172802, cap: 0)
        XCTAssertTrue(
            try store.chunks(session: id).allSatisfy { !store.audioAvailable($0, now: 172802) })
        XCTAssertTrue(
            try FileManager.default
                .contentsOfDirectory(atPath: root.appendingPathComponent("derived").path).isEmpty)
        let rows = try store.segments(session: id)
        XCTAssertEqual(Set(rows.map(\.origin)), Set([.microphone, .system]))
        XCTAssertTrue(
            rows.allSatisfy {
                $0.raw == "Keep original" && $0.corrected == "Keep corrected" && $0.speaker == "Me"
            })
        try store.deleteSession(id)
        XCTAssertTrue(try store.exec("SELECT * FROM chunk_sources").isEmpty)
    }
    func testSystemPermissionDenialPreventsContentEnumerationWithoutPrompt() async throws {
        var reads = 0
        let capture = SystemAudioCapture(permission: {
            reads += 1; return false
        })
        do { try await capture.prepare(); XCTFail("Must refuse denied permission") } catch {
            XCTAssertTrue(error.localizedDescription.contains("permission"))
        }
        XCTAssertEqual(reads, 1)
        await capture.stop()
        let c = SystemAudioCapture.configuration()
        XCTAssertTrue(c.capturesAudio); XCTAssertFalse(c.captureMicrophone)
        XCTAssertTrue(c.excludesCurrentProcessAudio); XCTAssertEqual(c.queueDepth, 3)
    }
    func testCancelledStartupCannotReopenAdmissionOrRequestPermission() async throws {
        var permissionReads = 0
        let capture = SystemAudioCapture(permission: {
            permissionReads += 1; return false
        })
        capture.close()
        do { try await capture.prepare(); XCTFail("Closed startup must remain closed") } catch {
            XCTAssertTrue(error is CancellationError)
        }
        let id = try session()
        let writer = ChunkWriter(store: store, session: id, model: "unified", origin: .system)
        do {
            try await capture.start(writer: writer);
            XCTFail("Cancelled startup cannot attach a writer")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(permissionReads, 0)
        await capture.stop(); try writer.finish()
        XCTAssertTrue(try store.chunks(session: id).isEmpty)
    }
    func testSystemPCMAdapterCopiesSamplesAndRejectsOversize() throws {
        let b = buffer(1600, channels: 2)
        var desc: CMAudioFormatDescription?
        var asbd = b.format.streamDescription.pointee
        XCTAssertEqual(
            CMAudioFormatDescriptionCreate(
                allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0, layout: nil,
                magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &desc),
            noErr)
        var sample: CMSampleBuffer?
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 16000),
            presentationTimeStamp: CMTime(value: 1, timescale: 1), decodeTimeStamp: .invalid)
        XCTAssertEqual(
            CMSampleBufferCreate(
                allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: false,
                makeDataReadyCallback: nil, refcon: nil, formatDescription: desc, sampleCount: 1600,
                sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 0,
                sampleSizeArray: nil, sampleBufferOut: &sample), noErr)
        let s = try XCTUnwrap(sample)
        XCTAssertEqual(
            CMSampleBufferSetDataBufferFromAudioBufferList(
                s, blockBufferAllocator: kCFAllocatorDefault,
                blockBufferMemoryAllocator: kCFAllocatorDefault, flags: 0,
                bufferList: b.audioBufferList), noErr)
        let copy = try SystemAudioCapture.copyAudio(s)
        XCTAssertEqual(copy.frameLength, b.frameLength)
        XCTAssertEqual(
            copy.floatChannelData![0][100], b.floatChannelData![0][100], accuracy: 0.000001)
        let w = ChunkWriter(store: store, session: try session(), model: "unified", origin: .system)
        XCTAssertFalse(w.enqueue(buffer(8193)))
        XCTAssertFalse(w.enqueue(buffer(1600)))
        try w.finish()
    }
    func testSummarySeparatesSourcesWithoutChangingWireSchemaOrSpeakerIdentity() throws {
        let id = try session()
        for (i, origin) in [AudioOrigin.microphone, .system].enumerated() {
            let w = ChunkWriter(store: store, session: id, model: "unified", origin: origin)
            try w.write(buffer()); try w.finish()
            let c = try XCTUnwrap(
                try store.chunks(session: id)
                    .first { AudioSources.origin(store, chunk: $0.id) == origin })
            try store.exec("UPDATE chunks SET status='done' WHERE id=?", [c.id])
            try store.insertSegment(
                session: id, offset: Double(i) * 0.3, end: Double(i) * 0.3 + 0.1, raw: "Boundary",
                corrected: "Boundary", speaker: "Me", language: "en", chunk: c.id)
        }
        try store.finish(id)
        let snap = try SummaryStorage.snapshot(store, session: id)
        XCTAssertEqual(snap.input.segments.count, 2)
        XCTAssertEqual(snap.input.segments[0].speakerId, snap.input.segments[1].speakerId)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: snap.body) as? [String: Any])
        let turns = try XCTUnwrap(json["segments"] as? [[String: Any]])
        XCTAssertNil(turns[0]["audioOrigin"])
        XCTAssertTrue(
            snap.input.segments.allSatisfy { $0.id.hasPrefix("s") && $0.text == "Boundary" })
    }
    func testEchoEvidenceDelayOverlapNoiseAndIndependentRepetition() throws {
        var rng: UInt64 = 42
        func noise(_ n: Int) -> [Float] {
            (0..<n)
                .map { _ in
                    rng = rng &* 6364136223846793005 &+ 1;
                    return Float(Int((rng >> 32) % 10000) - 5000) / 10000
                }
        }
        let source = noise(8000), other = noise(8000), delay = 200
        let leaked =
            [Float](repeating: 0, count: delay) + Array(source.dropLast(delay)).map { $0 * 0.35 }
        let hit = try XCTUnwrap(EchoEvidence.match(microphone: leaked, system: source))
        XCTAssertEqual(hit.lag, 0.1, accuracy: 0.006)
        XCTAssertNil(EchoEvidence.match(microphone: zip(leaked, other).map(+), system: source))
        XCTAssertNil(EchoEvidence.match(microphone: other, system: source))
        XCTAssertNil(EchoEvidence.match(microphone: source, system: source))  // independent simultaneous repetition, no delay
        XCTAssertNil(
            EchoEvidence.match(microphone: Array(repeating: 0, count: 8000), system: source))
    }
    func testDualWriterStressProfileBoundedChunksAndLosslessFrames() throws {
        let id = try session(), start = Date()
        let mic = ChunkWriter(store: store, session: id, model: "unified", origin: .microphone)
        let sys = ChunkWriter(store: store, session: id, model: "unified", origin: .system)
        let b = buffer(4096, rate: 48000)
        let stereo = buffer(4096, rate: 48000, channels: 2)
        for _ in 0..<1407 { try mic.write(b); try sys.write(stereo) }
        try mic.finish(); try sys.finish()
        let writing = Date().timeIntervalSince(start)
        let chunks = try store.chunks(session: id)
        XCTAssertEqual(chunks.count, 26)
        for origin in [AudioOrigin.microphone, .system] {
            let list = chunks.filter { AudioSources.origin(store, chunk: $0.id) == origin }
            let frames = try list.reduce(Int64(0)) {
                try $0 + AVAudioFile(forReading: Archive.readable($1, store: store)).length
            }
            XCTAssertEqual(frames, Int64(1407 * 4096))
        }
        let compression = Date()
        for c in chunks { try Archive.compress(c, store: store) }
        print(
            "SYSTEM_WRITER_PROFILE audio_s=120.064 sources=2 chunks=\(chunks.count) write_wall_s=\(writing) compression_wall_s=\(Date().timeIntervalSince(compression))"
        )
    }
    func testGeneratedVoicesEchoAnnotationsCanBeDismissedWithoutChangingTextOrAudio() throws {
        func voice(_ name: String, _ text: String) throws -> [Float] {
            let url = root.appendingPathComponent(name + ".aiff")
            try LocalProcess.run(
                "/usr/bin/say", ["-v", name, "-r", "155", "-o", url.path, text], timeout: 30)
            let f = try AVAudioFile(forReading: url)
            let wav = root.appendingPathComponent(name + ".wav")
            try Archive.wav(url, to: wav)
            let input = try AVAudioFile(forReading: wav)
            let b = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: 4096)!
            var result: [Float] = [], sum: Float = 0, count = 0
            while input.framePosition < input.length && result.count < 20000 {
                try input.read(into: b)
                for i in 0..<Int(b.frameLength) {
                    sum += b.floatChannelData![0][i]; count += 1;
                    if count == 8 { result.append(sum / 8); sum = 0; count = 0 }
                }
            }
            XCTAssertGreaterThan(f.length, 0)
            return result
        }
        let
            a = try voice(
                "Samantha",
                "Today we planned a meeting about the microphone receiver and the Kyoto boundary."),
            b = try voice(
                "Daniel", "We should review the budget and ask a different question tomorrow.")
        let n = min(a.count, b.count), sys = Array(a.prefix(n)), other = Array(b.prefix(n)),
            delay = 200
        let mic = [Float](repeating: 0, count: delay) + Array(sys.dropLast(delay)).map { $0 * 0.5 }
        let hit = try XCTUnwrap(EchoEvidence.match(microphone: mic, system: sys))
        XCTAssertEqual(hit.lag, 0.1, accuracy: 0.006)
        XCTAssertNil(EchoEvidence.match(microphone: zip(mic, other).map(+), system: sys))
        let id = try session()
        let m = try store.registerChunk(
            session: id, path: "audio/m.caf", captured: Date().timeIntervalSince1970, offset: 0,
            model: "unified", origin: .microphone)
        let s = try store.registerChunk(
            session: id, path: "audio/s.caf", captured: Date().timeIntervalSince1970, offset: 0,
            model: "unified", origin: .system)
        try store.exec(
            "INSERT INTO echo_annotations(mic,system,score,lag) VALUES(?,?,?,?)",
            [m, s, hit.score, hit.lag])
        try store.insertSegment(
            session: id, offset: 0, end: 1, raw: "Do not delete overlap",
            corrected: "Do not delete overlap", speaker: "Unknown", language: "en", chunk: m)
        XCTAssertTrue(try store.segments(session: id)[0].possibleEcho)
        try AudioSources.dismissEcho(store, chunk: m, dismissed: true)
        let row = try store.segments(session: id)[0]
        XCTAssertFalse(row.possibleEcho); XCTAssertTrue(row.echoDismissed)
        XCTAssertEqual(row.raw, "Do not delete overlap")
        try AudioSources.dismissEcho(store, chunk: m, dismissed: false)
        XCTAssertTrue(try store.segments(session: id)[0].possibleEcho)
    }

}
