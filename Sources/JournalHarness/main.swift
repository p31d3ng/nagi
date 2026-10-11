import AVFoundation
import Foundation
import JournalCore

let args = CommandLine.arguments
func measure(_ label: String, _ body: () throws -> Void) rethrows {
    let start = Date()
    try body()
    print("\(label): \(String(format:"%.6f",Date().timeIntervalSince(start))) s")
}
do {
    guard args.count >= 3 else {
        throw JournalError(
            "Usage: JournalHarness import|process|recover|stress|crash data-root [fixture] [project]"
        )
    }
    let store = try Store(root: URL(fileURLWithPath: args[2]))
    switch args[1] {
    case "summary-auth-check":
        // Deliberately malformed credential + unfinished body cannot trigger inference.
        let done = DispatchSemaphore(value: 0)
        let start = Date()
        Task.detached(priority: .utility) {
            do {
                let result = try await SummaryHTTPTransport()
                    .send(
                        endpoint: SummaryEndpoint.validate(SummaryEndpoint.suggested),
                        body: Data("{\"final\":false}".utf8), bearer: "invalid")
                let response =
                    try JSONSerialization.jsonObject(with: result.body) as? [String: String]
                guard result.status == 401, response?["error"] == "unauthorized" else {
                    throw JournalError("Unexpected authentication smoke result; response withheld")
                }
                print(
                    "Native HTTPS authentication rejection verified: HTTP 401; no inference; wall_s=\(Date().timeIntervalSince(start))"
                )
            } catch {
                fputs(
                    "Native HTTPS smoke check failed; no credential or response details displayed.\n",
                    stderr)
                exit(1)
            }
            done.signal()
        }
        guard done.wait(timeout: .now() + 50) == .success else {
            throw JournalError("Native HTTPS smoke check timed out")
        }
    case "speechgate":
        let source = URL(fileURLWithPath: args[3]); let project = URL(fileURLWithPath: args[4])
        let speechOnly = args.count <= 5 || args[5] != "continuous"
        let useLive = args.count > 6 && args[6] == "live"
        let crashAt = args.count > 7 ? Double(args[7]) ?? -1 : -1
        let workerKillAt = args.count > 8 ? Double(args[8]) ?? -1 : -1
        var workerKilled = false
        let id = try store.createSession(
            title: "Synthetic speech gate", device: "synthetic", model: "unified")
        let writer = ChunkWriter(store: store, session: id, model: "unified")
        let vad = speechOnly ? try SpeechVAD(project: project) : nil
        let gate = vad.map { SpeechGate(vad: $0) }
        if let gate { try writer.enableSpeechOnly(gate: gate) }
        var live: LiveTranscriber?; let ended = DispatchSemaphore(value: 0)
        if useLive {
            let worker = LiveTranscriber(store: store, session: id, project: project); live = worker
            let ready = DispatchSemaphore(value: 0)
            worker.onUpdate = { snapshot in
                if snapshot.ready == true { ready.signal() }
                if let text = snapshot.full, !text.isEmpty {
                    print(String(data: try! JSONEncoder().encode(snapshot), encoding: .utf8)!)
                }
            }
            worker.onFinished = { ended.signal() }; worker.onStatus = { print($0) }; worker.start()
            guard ready.wait(timeout: .now() + 40) == .success else {
                throw JournalError("VAD Live warmup failed")
            }
            writer.onWritten = { buffer, offset in worker.offer(buffer, offset: offset) }
            writer.onSpanEnded = { _ in worker.endSpan() }
        }
        let input = try AVAudioFile(forReading: source);
        let rate = input.processingFormat.sampleRate
        let begin = Date(); var inputFrames: Int64 = 0
        while input.framePosition < input.length {
            try autoreleasepool {
                let buffer = AVAudioPCMBuffer(
                    pcmFormat: input.processingFormat, frameCapacity: 4096)!
                try input.read(into: buffer); try writer.write(buffer);
                inputFrames += Int64(buffer.frameLength)
            }
            if crashAt >= 0, Double(inputFrames) / rate >= crashAt { fflush(stdout); _exit(75) }
            if !workerKilled, workerKillAt >= 0, Double(inputFrames) / rate >= workerKillAt,
                let live, live.workerPID > 0
            {
                kill(live.workerPID, SIGKILL); workerKilled = true
            }
            if useLive {
                let wait = Double(inputFrames) / rate - Date().timeIntervalSince(begin);
                if wait > 0 { Thread.sleep(forTimeInterval: wait) }
            }
        }
        try writer.finish(); try store.finish(id)
        if let live {
            live.stop();
            guard ended.wait(timeout: .now() + 20) == .success else {
                throw JournalError("VAD Live finalize timed out")
            }
        }
        let wall = Date().timeIntervalSince(begin); let chunks = try store.chunks(session: id)
        var savedFrames: Int64 = 0; var ranges: [[String: Double]] = []
        for chunk in chunks {
            let saved = try AVAudioFile(forReading: store.root.appendingPathComponent(chunk.path))
            input.framePosition = Int64((chunk.offset * rate).rounded())
            guard saved.processingFormat.sampleRate == rate,
                saved.processingFormat.channelCount == input.processingFormat.channelCount
            else { throw JournalError("VAD archive format changed") }
            while saved.framePosition < saved.length {
                let count = AVAudioFrameCount(min(4096, saved.length - saved.framePosition))
                let a = AVAudioPCMBuffer(pcmFormat: saved.processingFormat, frameCapacity: count)!
                let b = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: count)!
                try saved.read(into: a); try input.read(into: b, frameCount: count)
                guard a.frameLength == b.frameLength else {
                    throw JournalError("VAD sample length mismatch")
                }
                for c in 0..<Int(a.format.channelCount) {
                    for i in 0..<Int(a.frameLength) {
                        guard a.floatChannelData![c][i] == b.floatChannelData![c][i] else {
                            throw JournalError("VAD original sample mismatch")
                        }
                    }
                }
            }
            savedFrames += saved.length;
            ranges.append(["start": chunk.offset, "end": chunk.offset + chunk.duration])
            try Archive.compress(chunk, store: store)
        }
        let files = try FileManager.default.contentsOfDirectory(
            at: store.root.appendingPathComponent("audio"),
            includingPropertiesForKeys: [.fileSizeKey])
        let bytes = try files.reduce(0) {
            try $0 + ($1.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
        }
        let report: [String: Any] = [
            "mode": speechOnly ? "speechOnly" : "continuous",
            "worker_killed": workerKilled,
            "input_seconds": Double(inputFrames) / rate,
            "saved_seconds": Double(savedFrames) / rate, "write_vad_wall_seconds": wall,
            "rtf": wall / (Double(inputFrames) / rate),
            "peak_buffered_frames": gate?.peakBufferedFrames ?? 0, "compressed_bytes": bytes,
            "audio_files": files.count, "ranges": ranges, "sample_continuity": true,
            "gaps": try store.exec(
                "SELECT start,end,reason FROM audio_gaps WHERE session=? ORDER BY start", [id]),
        ]
        print(
            "GATE-RESULT " + String(
                data: try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]),
                encoding: .utf8)!)
    case "import":
        let id = try store.createSession(
            title: "Synthetic fixture", device: "synthetic", model: "unified")
        try measure("capture/write") {
            let writer = ChunkWriter(store: store, session: id, model: "unified")
            try writer.importFile(URL(fileURLWithPath: args[3]))
            try store.finish(id)
        }
        for chunk in try store.chunks(session: id) {
            try measure("compression") { try Archive.compress(chunk, store: store) }
        }
    case "process":
        let processor = try Processor(store: store, project: URL(fileURLWithPath: args[3]))
        processor.onStatus = { print($0) }
        try processor.retry()
        measure("processing") { processor.waitUntilIdle() }
        print(try store.segments().map(\.raw).joined(separator: "\n"))
    case "live":
        // Synthetic production write path plus persistent live preview. No microphone is opened.
        let source = URL(fileURLWithPath: args[3])
        let project = URL(fileURLWithPath: args[4])
        let duration = args.count > 5 ? Double(args[5])! : 60
        let killAt = args.count > 6 ? Double(args[6])! : -1
        let liveSpeed = args.count > 7 ? Double(args[7])! : 1
        let id = try store.createSession(
            title: "Synthetic live continuity", device: "synthetic injection", model: "unified")
        let processor = try Processor(store: store, project: project)
        let live = LiveTranscriber(
            store: store, session: id, project: project,
            responsiveness: args.count > 9
                ? LiveResponsiveness(rawValue: args[9]) ?? .balanced : .balanced)
        let ready = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        var began = Date()
        live.onUpdate = { snapshot in
            if snapshot.ready == true { ready.signal() }
            if let text = snapshot.full, !text.isEmpty {
                let object: [String: Any] = [
                    "event": "text", "wall": Date().timeIntervalSince(began),
                    "offset": snapshot.offset ?? 0,
                    "audio": snapshot.duration ?? 0, "final": snapshot.final ?? false, "text": text,
                ]
                print(
                    String(
                        data: try! JSONSerialization.data(
                            withJSONObject: object, options: [.sortedKeys]), encoding: .utf8)!)
                fflush(stdout)
            }
        }
        live.onStatus = {
            print("live-status=" + $0); fflush(stdout)
        }
        live.onFinished = {
            processor.resumeBatch(); finished.signal()
        }
        processor.prepareLive { live.start() }
        if args.count <= 8 || args[8] != "capture" {
            guard ready.wait(timeout: .now() + 40) == .success else {
                live.stop(); throw JournalError("Live worker did not become ready")
            }
            print("LIVE-READY warmup=\(Date().timeIntervalSince(began))")
            began = Date()
        } else {
            print("LIVE-WARMUP capture begins before model readiness")
            began = Date()
        }
        let writer = ChunkWriter(store: store, session: id, model: "unified")
        writer.onWritten = { buffer, offset in live.offer(buffer, offset: offset) }
        writer.onChunk = { processor.schedule() }
        let f = try AVAudioFile(forReading: source)
        let fixtureRate = f.processingFormat.sampleRate
        let total = Int64(duration * fixtureRate)
        var sent: Int64 = 0
        var killed = false
        while sent < total {
            try autoreleasepool {
                let n = AVAudioFrameCount(min(1280, min(total - sent, f.length - f.framePosition)))
                if n == 0 { f.framePosition = 0; return }
                let b = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: n)!
                try f.read(into: b)
                guard writer.enqueue(b) else {
                    throw JournalError("Synthetic archive admission failed")
                }
                sent += Int64(b.frameLength)
            }
            if !killed, killAt >= 0, Double(sent) / fixtureRate >= killAt {
                let pid = live.workerPID
                if pid > 0 { kill(pid, SIGKILL) }; killed = true
            }
            let wait = Double(sent) / fixtureRate / liveSpeed - Date().timeIntervalSince(began)
            if wait > 0 { Thread.sleep(forTimeInterval: wait) }
        }
        try writer.finish()
        try store.finish(id)
        live.stop()
        guard finished.wait(timeout: .now() + 20) == .success else {
            throw JournalError("Live worker did not finish")
        }
        processor.waitUntilIdle()
        _ = try LiveDocument.page(store, session: id)
        let chunks = try store.chunks(session: id)
        var recovered: Int64 = 0
        let audit = try AVAudioFile(forReading: source)
        // Compare every original Float32 sample, not merely duration or byte counts.
        for chunk in chunks {
            let archived = try Archive.decompress(chunk, store: store)
            defer {
                if archived.path.contains("/derived/") {
                    try? FileManager.default.removeItem(at: archived)
                }
            }
            let recorded = try AVAudioFile(forReading: archived)
            while recorded.framePosition < recorded.length {
                let n = AVAudioFrameCount(
                    min(
                        4096,
                        min(
                            recorded.length - recorded.framePosition,
                            audit.length - audit.framePosition)))
                if n == 0 { audit.framePosition = 0; continue }
                let actual = AVAudioPCMBuffer(
                    pcmFormat: recorded.processingFormat, frameCapacity: n)!
                let expected = AVAudioPCMBuffer(
                    pcmFormat: audit.processingFormat, frameCapacity: n)!
                try recorded.read(into: actual); try audit.read(into: expected)
                for channel in 0..<Int(actual.format.channelCount) {
                    for i in 0..<Int(actual.frameLength) {
                        guard
                            actual.floatChannelData![channel][i]
                                == expected.floatChannelData![channel][i]
                        else { throw JournalError("Archive sample mismatch") }
                    }
                }
                recovered += Int64(actual.frameLength)
            }
        }
        guard recovered == total else { throw JournalError("Archive frame count mismatch") }
        print(
            "LIVE-PASS session=\(id) frames=\(recovered) chunks=\(chunks.count) wall=\(Date().timeIntervalSince(began)) killed=\(killed)"
        )
    case "soak":
        let duration = Double(args.count > 5 ? args[5] : "1800")!
        let speed = Double(args.count > 6 ? args[6] : "4")!
        let id = try store.createSession(
            title: "Synthetic concurrent soak", device: "synthetic injection", model: "unified")
        let processor = try Processor(store: store, project: URL(fileURLWithPath: args[4]))
        let writer = ChunkWriter(
            store: store, session: id, model: "unified", started: Date().timeIntervalSince1970)
        let stats = NSLock()
        var gaps: [String] = []
        var chunks = 0
        writer.onError = { message in
            stats.lock()
            gaps.append(message)
            stats.unlock()
        }
        writer.onChunk = {
            processor.schedule()
            stats.lock()
            chunks += 1
            let count = chunks
            stats.unlock()
            if count % 10 == 0 {
                print("sealed=\(count) queued=\((try? store.chunks(status:"queued").count) ?? -1)")
                fflush(stdout)
            }
        }
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: args[3]))
        let rate = file.processingFormat.sampleRate
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096)!
        let start = Date()
        var fed: Int64 = 0
        var accepted: Int64 = 0
        while fed < Int64(duration * rate) {
            try autoreleasepool {
                if file.framePosition == file.length { file.framePosition = 0 }
                try file.read(
                    into: buffer,
                    frameCount: AVAudioFrameCount(min(4096, Int64(duration * rate) - fed)))
                if writer.enqueue(buffer) { accepted += Int64(buffer.frameLength) }
                fed += Int64(buffer.frameLength)
            }
            let wait = Double(fed) / rate / speed - Date().timeIntervalSince(start)
            if wait > 0 { Thread.sleep(forTimeInterval: wait) }
        }
        try writer.finish()
        try store.finish(id)
        processor.schedule()
        processor.waitUntilIdle()
        let saved = try store.chunks(session: id)
        let recorded = saved.reduce(0.0) { $0 + $1.duration }
        guard gaps.isEmpty, abs(recorded - Double(accepted) / rate) < 0.00001, accepted == fed,
            saved.allSatisfy({ $0.status == "done" || $0.status == "silence" })
        else {
            throw JournalError(
                "Soak failed: gaps=\(gaps), accepted=\(accepted)/\(fed), recorded=\(recorded), statuses=\(saved.map(\.status))"
            )
        }
        print(
            "SOAK PASS seconds=\(recorded) chunks=\(saved.count) gaps=\(gaps.count) wall=\(Date().timeIntervalSince(start)) accepted_frames=\(accepted)"
        )
    case "audit":
        for chunk in try store.chunks() {
            var url: URL!
            try measure("decompression") { url = try Archive.decompress(chunk, store: store) }
            try measure("VAD/RMS") { print("rms=\(try Archive.rms(url))") }
            let wav = store.root.appendingPathComponent("derived/audit.wav")
            try measure("resample") { try Archive.wav(url, to: wav) }
            try? FileManager.default.removeItem(at: wav)
            if url.path.contains("/derived/") { try? FileManager.default.removeItem(at: url) }
        }
    case "recover":
        try measure("recovery") { try Archive.recover(store) }
        print(try store.chunks().map { ($0.status, $0.duration) })
    case "crash":
        let id = try store.createSession(
            title: "Injected crash", device: "synthetic", model: "unified")
        let writer = ChunkWriter(store: store, session: id, model: "unified")
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: args[3]))
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096)!
        for _ in 0..<55 {
            try file.read(into: buffer)
            if buffer.frameLength == 0 {
                file.framePosition = 0
                continue
            }
            try writer.write(buffer)
        }
        print("Crash after buffers while final CAF remains open")
        fflush(stdout)
        kill(getpid(), SIGKILL)
    case "retention-stress":
        let id = try store.createSession(
            title: "Expired metadata stress", device: "synthetic", model: "unified")
        try store.finish(id)
        try measure("insert 100000 expired metadata rows") {
            try store.transaction {
                for i in 0..<100000 {
                    try store.exec(
                        "INSERT INTO chunks(id,session,path,captured,offset,duration,status,model) VALUES(?,?,'',1,?,10,'expired','unified')",
                        ["expired-\(i)", id, Double(i * 10)])
                }
            }
        }
        try measure("10 indexed audio cleanup passes, forever transcript setting") {
            for _ in 0..<10 { _ = try store.cleanup(cap: 0) }
        }
        print(
            "metadata rows retained=\(try store.exec("SELECT COUNT(*) AS n FROM chunks").first!["n"]!)"
        )
    case "stress":
        try measure("insert 10000 segments") {
            let id = try store.createSession(title: "Stress", device: "synthetic", model: "unified")
            try store.transaction {
                for i in 0..<10000 {
                    try store.insertSegment(
                        session: id, offset: Double(i), end: Double(i + 1),
                        raw: "Meeting boundary Kyoto \(i)",
                        corrected: "Meeting boundary Kyoto \(i)",
                        speaker: i % 2 == 0 ? "Me" : "Speaker 2",
                        language: "en", chunk: "")
                }
            }
            try store.finish(id)
        }
        try measure("search 100 queries") {
            for _ in 0..<100 { _ = try store.segments(query: "Kyoto", speaker: "Me") }
        }
        try measure("retention / eviction") {
            _ = try store.cleanup(now: Date().timeIntervalSince1970 + 172801, cap: 2000)
        }
        print("Remaining sessions: \(try store.sessions().count)")
    default: throw JournalError("Unknown command")
    }
} catch {
    fputs("\(error.localizedDescription)\n", stderr)
    exit(1)
}
