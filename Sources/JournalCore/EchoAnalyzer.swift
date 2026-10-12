import AVFoundation
import Foundation

/// Runs on the existing serial processing lane, after ASR/diarization, never in capture callbacks.
public enum EchoAnalyzer {
    public static func analyze(_ chunk: Chunk, store: Store) throws {
        let origin = AudioSources.origin(store, chunk: chunk.id)
        guard origin == .microphone || origin == .system else { return }
        let opposite = origin == .microphone ? AudioOrigin.system : .microphone
        let peers = try store.exec(
            "SELECT chunks.id FROM chunks JOIN chunk_sources s ON s.chunk=chunks.id WHERE session=? AND s.origin=? AND s.clock='host' AND status!='writing' AND offset<? AND offset+duration>? ORDER BY offset LIMIT 3",
            [chunk.session, opposite.rawValue, chunk.offset + chunk.duration, chunk.offset])
        guard
            (try store.exec("SELECT clock FROM chunk_sources WHERE chunk=?", [chunk.id]).first?[
                "clock"]) == "host"
        else { return }
        for row in peers {
            guard let id = row["id"], let peer = try store.chunk(id), store.audioAvailable(chunk),
                store.audioAvailable(peer)
            else { continue }
            let mic = origin == .microphone ? chunk : peer
            let sys = origin == .system ? chunk : peer
            guard
                try store.exec(
                    "SELECT 1 FROM echo_checks WHERE mic=? AND system=?", [mic.id, sys.id]
                )
                .isEmpty
            else { continue }
            let start = max(mic.offset, sys.offset),
                end = min(mic.offset + mic.duration, sys.offset + sys.duration)
            guard end - start >= 1 else { continue }
            let expiry = min(mic.captured, sys.captured) + 172800
            let a = try read(mic, store: store, start: start, end: end, expiry: expiry)
            let b = try read(sys, store: store, start: start, end: end, expiry: expiry)
            guard store.audioAvailable(mic), store.audioAvailable(sys) else { continue }
            if let evidence = EchoEvidence.match(microphone: a, system: b) {
                try store.exec(
                    "INSERT OR IGNORE INTO echo_annotations(mic,system,score,lag) VALUES(?,?,?,?)",
                    [mic.id, sys.id, evidence.score, evidence.lag])
            }
            try store.exec("INSERT OR IGNORE INTO echo_checks VALUES(?,?)", [mic.id, sys.id])
        }
    }
    private static func read(
        _ chunk: Chunk, store: Store, start: Double, end: Double, expiry: Double
    ) throws -> [Float] {
        let source = try Archive.decompress(chunk, store: store)
        let wav = store.root.appendingPathComponent(
            "derived/\(chunk.id).echo.\(UUID().uuidString).wav")
        defer {
            try? FileManager.default.removeItem(at: wav)
            if source.path.contains("/derived/") { try? FileManager.default.removeItem(at: source) }
        }
        let remaining = expiry - Date().timeIntervalSince1970
        guard remaining > 0 else { throw JournalError("Echo evidence audio expired") }
        try LocalProcess.run(
            "/usr/bin/afconvert",
            [source.path, wav.path, "-f", "WAVE", "-d", "LEI16@16000", "-c", "1", "--mix"],
            timeout: min(30, remaining))
        let file = try AVAudioFile(forReading: wav)
        file.framePosition = Int64(max(0, start - chunk.offset) * 16000)
        let count = min(Int((end - start) * 16000), Int(file.length - file.framePosition))
        guard count <= 16000 * 12,
            let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096)
        else { throw JournalError("Echo evidence exceeds bounded window") }
        var output: [Float] = []
        var read = 0, group = 0, sum: Float = 0
        while read < count {
            try file.read(into: buffer, frameCount: AVAudioFrameCount(min(4096, count - read)))
            guard buffer.frameLength > 0, let samples = buffer.floatChannelData else { break }
            for i in 0..<Int(buffer.frameLength) {
                sum += samples[0][i]; group += 1
                if group == 8 { output.append(sum / 8); sum = 0; group = 0 }
            }
            read += Int(buffer.frameLength)
        }
        return output
    }
}
