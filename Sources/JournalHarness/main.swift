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
