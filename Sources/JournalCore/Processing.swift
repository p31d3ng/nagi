import Foundation

public struct ModelChoice: Identifiable {
    public let id: String
    public let name: String
    public let filename: String
    public let revision: String
    public let checksum: String
    public let languages: String
}
public enum Models {
    public static let all: [ModelChoice] = [
        ModelChoice(
            id: "unified", name: "Parakeet Unified EN 0.6B",
            filename: "parakeet-unified-en-0.6b-Q8_0.gguf",
            revision: "7e948f21b7bdbac698d3318db9d350f1096f3b6c",
            checksum: "4b50b6dd862bf6e346929aaf4f5eaacec003bfa3f56462d6c874b41ef2f38795",
            languages: "English · Q8_0 · 697 MiB"),
        ModelChoice(
            id: "whisper", name: "Whisper Medium", filename: "whisper-medium-Q4_K_M.gguf",
            revision: "ec78f06fded51aa82cde751678b78f76f78c8b7f",
            checksum: "6c9cad9c41d1fa0fcc624898f7ee3485b66127627878081a5655c6f6f3ce20ab",
            languages: "Multilingual · Mandarin / Japanese · Q4_K_M"),
    ]
}
public struct SpeakerTurn: Codable {
    public let speaker: String
    public let start: Double
    public let end: Double
}
public struct OverlapSpan: Codable {
    public let start: Double
    public let end: Double
}
public struct SpeakerResult: Codable {
    public var overlaps: [OverlapSpan]? = nil
    public let turns: [SpeakerTurn]
    public let embeddings: [String: [Float]]
    public let elapsed: Double
    public let model: String
}
public struct ASRRow: Decodable {
    public let text: String
    public let streaming_text: String?
    public let language: String?
    public let segments: [ASRSegment]?
    public let error: String?
}
public struct ASRSegment: Decodable {
    public let t0_ms: Int
    public let t1_ms: Int
    public let text: String
}

/// One serial worker lane. ML in separate, network-denied processes, with timeouts.
public final class Processor: @unchecked Sendable {
    public let store: Store
    public let project: URL
    private let lane = DispatchQueue(
        label: "stillpoint.processing", qos: .utility, autoreleaseFrequency: .workItem)
    private let retentionLane = DispatchQueue(
        label: "nagi.audio.expiry", qos: .utility, autoreleaseFrequency: .workItem)
    private let state = NSLock()
    private var scheduled = false
    private var lastCleanup = Date.distantPast
    public var onStatus: ((String) -> Void)?
    public var onChange: (() -> Void)?
    public init(store: Store, project: URL) throws {
        self.store = store
        self.project = project
        try store.exec(
            "CREATE TABLE IF NOT EXISTS speaker_vectors(session TEXT,label TEXT,embedding TEXT,PRIMARY KEY(session,label))"
        )
    }
    public func schedule() {
        state.lock()
        guard !scheduled else {
            state.unlock()
            return
        }
        scheduled = true
        state.unlock()
        lane.async {
            self.drain()
            self.state.lock()
            self.scheduled = false
            self.state.unlock()
            if (try? self.readyChunk()) != nil { self.schedule() }
        }
    }
    public func maintenance() {
        // Audio expiry is independent of a long-running ML job. Transcript eviction stays serial with ML.
        retentionLane.async {
            do {
                try self.store.cleanup(cap: 0)
                self.onChange?()
            } catch { self.onStatus?(error.localizedDescription) }
        }
        lane.async {
            do {
                try self.store.cleanup(
                    cap: Int(self.store.setting("cap", fallback: "500000000")) ?? 500_000_000)
                self.onChange?()
            } catch { self.onStatus?(error.localizedDescription) }
        }
    }
    public func waitUntilIdle() { lane.sync {} }
    public func retry() throws {
        try store.exec(
            "UPDATE chunks SET status='queued',error='' WHERE status IN ('failed','needs_speakers')"
        )
        schedule()
    }
    private func readyChunk() throws -> Chunk? {
        guard let chunk = try store.chunks(status: "queued", limit: 1).first else { return nil }
        if !store.audioAvailable(chunk) { return chunk }
        if chunk.model == "unified", store.setting("enrollment-session") != chunk.session,
            try store.exec("SELECT status FROM sessions WHERE id=?", [chunk.session]).first?[
                "status"]
                == "recording",
            try store.exec(
                "SELECT id FROM chunks WHERE session=? AND offset>? AND status!='writing' LIMIT 1",
                [chunk.session, chunk.offset]
            )
            .isEmpty
        {
            // Wait for bounded look-ahead; finishing the session releases the final chunk.
            return nil
        }
        return chunk
    }
    private func drain() {
        do {
            while let chunk = try readyChunk() {
                // A continuous backlog must not starve retention behind the drain loop.
                if Date().timeIntervalSince(lastCleanup) >= 60 {
                    try store.cleanup(
                        cap: Int(store.setting("cap", fallback: "500000000")) ?? 500_000_000)
                    lastCleanup = Date()
                }
                guard store.audioAvailable(chunk) else {
                    try store.exec("UPDATE chunks SET status='expired' WHERE id=?", [chunk.id])
                    continue
                }
                do { try autoreleasepool { try process(chunk) } } catch {
                    try store.exec(
                        "UPDATE chunks SET status='failed',error=? WHERE id=?",
                        [error.localizedDescription, chunk.id])
                    onStatus?("Needs attention: \(error.localizedDescription)")
                }
                onChange?()
            }
        } catch { onStatus?(error.localizedDescription) }
        onStatus?("Idle · audio stays on this Mac")
    }
    private func process(_ original: Chunk) throws {
        try store.exec("UPDATE chunks SET status='processing' WHERE id=?", [original.id])
        onStatus?("Compressing · recording continues independently")
        try Archive.compress(original, store: store)
        guard let chunk = try store.chunk(original.id) else { return }
        let temporary = store.root.appendingPathComponent("derived/\(chunk.id).work")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        let workerEnvironment = ["TMPDIR": temporary.path + "/"]
        defer { try? FileManager.default.removeItem(at: temporary) }
        let source = try Archive.decompress(chunk, store: store)
        let wav = store.root.appendingPathComponent("derived/\(chunk.id).wav")
        let list = store.root.appendingPathComponent("derived/\(chunk.id).list")
        let log = store.root.appendingPathComponent("derived/\(chunk.id).asr.log")
        let diarized = store.root.appendingPathComponent("derived/\(chunk.id).speakers.json")
        defer {
            for url in [wav, list, log, diarized, source] where url.path.contains("/derived/") {
                try? FileManager.default.removeItem(at: url)
            }
        }
        let rms = try Archive.rms(source)
        // Conservative energy gate skips only near digital silence, never deletes captured audio.
        guard rms > 0.0001 else {
            try store.exec("UPDATE chunks SET status='silence' WHERE id=?", [chunk.id])
            return
        }
        try Archive.wav(source, to: wav)
        guard let model = Models.all.first(where: { $0.id == chunk.model }) else {
            throw JournalError("Unknown model selection")
        }
        let modelURL = project.appendingPathComponent("Models/" + model.filename)
        guard FileManager.default.fileExists(atPath: modelURL.path) else {
            throw JournalError("Install \(model.name) in Models, then Retry")
        }
        let isEnrollment = store.setting("enrollment-session") == chunk.session
        var asr: ASRRow? = nil
        let existing = try store.segments(session: chunk.session, chunkID: chunk.id)
        if !existing.isEmpty {
            asr = ASRRow(
                text: existing.map(\.raw).joined(separator: " "), streaming_text: nil,
                language: nil,
                segments: existing.map {
                    ASRSegment(
                        t0_ms: Int(($0.offset - chunk.offset) * 1000),
                        t1_ms: Int(($0.end - chunk.offset) * 1000), text: $0.raw)
                }, error: nil)
        }
        if !isEnrollment && asr == nil {
            onStatus?("Transcribing · \(model.name)")
            let executable = project.appendingPathComponent("bin/ASRWorker")
            let resultURL = store.root.appendingPathComponent("derived/\(chunk.id).asr.json")
            defer { try? FileManager.default.removeItem(at: resultURL) }
            let contextual = store.root.appendingPathComponent("derived/\(chunk.id).context.wav")
            defer { try? FileManager.default.removeItem(at: contextual) }
            let lead =
                chunk.model == "unified"
                ? try Archive.context(chunk, central: wav, to: contextual, store: store) : 0
            let input = chunk.model == "unified" ? contextual : wav
            let remaining =
                chunk.captured + 172800 - Date().timeIntervalSince1970 - (lead > 0 ? 10 : 0)
            guard remaining > 0 else {
                throw JournalError("Audio context expired; its transcript remains")
            }
            try LocalProcess.run(
                "/usr/bin/sandbox-exec",
                [
                    "-p", "(version 1)(allow default)(deny network*)", executable.path,
                    modelURL.path,
                    input.path, resultURL.path,
                ], log: log, timeout: min(180, remaining), environment: workerEnvironment)
            let raw = try JSONDecoder().decode(ASRRow.self, from: Data(contentsOf: resultURL))
            if let error = raw.error { throw JournalError("ASR: " + error) }
            asr = ASRRow(
                text: raw.text, streaming_text: raw.streaming_text, language: raw.language,
                segments: raw.segments.map {
                    Self.ownedRows(
                        chunk.model == "unified"
                            ? Self.streamingRows($0, text: raw.streaming_text ?? "") : $0,
                        lead: lead, duration: chunk.duration)
                }, error: nil)
        }
        onStatus?("Finding speakers · Community-1")
        let speakerWorker = project.appendingPathComponent(".build/debug/SpeakerWorker")
        let models = project.appendingPathComponent("Models/Community1")
        var speakers: SpeakerResult?
        do {
            let remaining = chunk.captured + 172800 - Date().timeIntervalSince1970
            guard remaining > 0 else { throw JournalError("Audio expired; its transcript remains") }
            try LocalProcess.run(
                "/usr/bin/sandbox-exec",
                [
                    "-p", "(version 1)(allow default)(deny network*)", speakerWorker.path, wav.path,
                    diarized.path, models.path,
                ], log: log, timeout: min(180, remaining), environment: workerEnvironment)
            speakers = try JSONDecoder()
                .decode(SpeakerResult.self, from: Data(contentsOf: diarized))
            try store.exec(
                "UPDATE sessions SET note='' WHERE id=? AND note LIKE 'Speaker analysis unavailable:%'",
                [chunk.session])
            if !(speakers?.overlaps ?? []).isEmpty {
                try store.exec(
                    "UPDATE sessions SET note=? WHERE id=?",
                    [
                        "Possible overlapping voices detected. Their ASR text is preserved with Unknown labels; quieter speech may still be omitted.",
                        chunk.session,
                    ])
            }
        } catch {
            if isEnrollment { throw error }
            if error.localizedDescription.contains("No speech detected in audio") {
                speakers = SpeakerResult(
                    turns: [], embeddings: [:], elapsed: 0, model: "Community-1 · inconclusive")
                try store.exec(
                    "UPDATE sessions SET note=? WHERE id=?",
                    [
                        "Speaker detection was inconclusive on a short/quiet chunk. Its ASR text is preserved with Unknown labels.",
                        chunk.session,
                    ])
            } else {
                try store.exec(
                    "UPDATE sessions SET note=? WHERE id=?",
                    [
                        "Speaker analysis unavailable: \(error.localizedDescription). Labels remain Unknown.",
                        chunk.session,
                    ])
            }
        }
        if isEnrollment {
            guard chunk.duration >= 8, let speakers, speakers.embeddings.count == 1,
                !SpeakerAttribution.hasOverlap(speakers.turns), (speakers.overlaps ?? []).isEmpty,
                let embedding = speakers.embeddings.values.first, !embedding.isEmpty
            else {
                throw JournalError(
                    "Enrollment needs one clear voice. Please retry alone in a quiet room.")
            }
            let encoded = String(data: try JSONEncoder().encode(embedding), encoding: .utf8)!
            try store.exec(
                "INSERT OR REPLACE INTO profiles VALUES('Me',?,'Community1/fc8c3e4',?)",
                [encoded, Date().timeIntervalSince1970])
            try store.exec("UPDATE chunks SET status='done' WHERE id=?", [chunk.id])
            return
        }
        let labels = try mapSpeakers(speakers?.embeddings ?? [:], session: chunk.session)
        let rulesData = Data(
            store.setting(
                "rules-" + chunk.session, fallback: store.setting("rules", fallback: "[]")
            )
            .utf8
        )
        let rules = (try? JSONDecoder().decode([Replacement].self, from: rulesData)) ?? []
        guard let asr else { throw JournalError("ASR unavailable") }
        let rows =
            asr.segments ?? [
                ASRSegment(t0_ms: 0, t1_ms: Int(chunk.duration * 1000), text: asr.text)
            ]
        try store.transaction {
            if existing.isEmpty {
                try store.exec(
                    "INSERT OR REPLACE INTO asr_runs VALUES(?,?,?,?)",
                    [chunk.id, asr.streaming_text ?? "", asr.text, asr.language ?? "uncertain"])
            }
            var grouped:
                [(start: Double, end: Double, text: String, label: String, language: String)] =
                    []
            for row in rows {
                let start = Double(row.t0_ms) / 1000
                let end = Double(row.t1_ms) / 1000
                let label = SpeakerAttribution.label(
                    start: start, end: end, turns: speakers?.turns ?? [], labels: labels,
                    overlaps: speakers?.overlaps ?? [])
                let language = Self.language(row.text, model: chunk.model)
                if let last = grouped.last, last.label == label, last.language == language,
                    end - last.start < 8, start - last.end < 1
                {
                    let index = grouped.count - 1
                    grouped[index].end = max(end, last.end)
                    grouped[index].text += row.text.hasPrefix(" ") ? row.text : " " + row.text
                } else {
                    grouped.append((start, max(start, end), row.text, label, language))
                }
            }
            for row in grouped where existing.isEmpty {
                try store.insertSegment(
                    session: chunk.session, offset: chunk.offset + row.start,
                    end: chunk.offset + row.end,
                    raw: row.text, corrected: DictionaryCorrection.apply(row.text, rules: rules),
                    speaker: row.label, language: row.language, chunk: chunk.id)
            }
            if !existing.isEmpty {
                for old in existing where old.speaker.hasPrefix("Unknown") {
                    let start = old.offset - chunk.offset
                    let end = old.end - chunk.offset
                    let label = SpeakerAttribution.label(
                        start: start, end: end, turns: speakers?.turns ?? [], labels: labels,
                        overlaps: speakers?.overlaps ?? [])
                    if !label.hasPrefix("Unknown") {
                        try store.exec("UPDATE segments SET speaker=? WHERE id=?", [label, old.id])
                    }
                }
            }
            try store.exec(
                "UPDATE chunks SET status=?,error=? WHERE id=?",
                [
                    speakers == nil ? "needs_speakers" : "done",
                    speakers == nil
                        ? "Speaker analysis unavailable. Retry preserves transcript corrections."
                        : "",
                    chunk.id,
                ])
        }
    }
    func mapSpeakers(_ embeddings: [String: [Float]], session: String) throws -> [String: String] {
        let profile: [Float]? =
            try store.exec(
                "SELECT embedding FROM profiles WHERE id='Me' AND model='Community1/fc8c3e4'"
            )
            .first.flatMap { $0["embedding"] }
            .flatMap {
                try? JSONDecoder().decode([Float].self, from: Data($0.utf8))
            }
        var saved =
            try store.exec(
                "SELECT label,embedding FROM speaker_vectors WHERE session=? ORDER BY label LIMIT 128",
                [session]
            )
            .compactMap { row -> (String, [Float])? in
                guard let label = row["label"], let value = row["embedding"],
                    let vector = try? JSONDecoder().decode([Float].self, from: Data(value.utf8))
                else { return nil }
                return (label, vector)
            }
        var result: [String: String] = [:]
        for (id, vector) in embeddings.sorted(by: { $0.key < $1.key }) {
            let me = profile.map { VoiceMatch.cosine(vector, $0) } ?? -1
            let otherMe =
                embeddings.filter { $0.key != id }
                .map { entry in
                    profile.map { VoiceMatch.cosine(entry.value, $0) } ?? -1
                }
                .max() ?? -1
            var label = VoiceMatch.label(score: me, runnerUp: otherMe)
            if label != "Me" {
                let scores = saved.map { ($0.0, VoiceMatch.cosine(vector, $0.1)) }
                    .sorted { $0.1 > $1.1 }
                if let best = scores.first, best.1 >= 0.75,
                    best.1 - (scores.dropFirst().first?.1 ?? -1) >= 0.12
                {
                    label = best.0
                } else if (scores.first?.1 ?? -1) < 0.6, saved.count < 128 {
                    label = "Speaker \(saved.count+2)"
                    saved.append((label, vector))
                    let json = String(data: try JSONEncoder().encode(vector), encoding: .utf8)!
                    try store.exec(
                        "INSERT OR REPLACE INTO speaker_vectors VALUES(?,?,?)",
                        [session, label, json])
                }
            }
            result[id] = label
        }
        return result
    }
    /// The requested streaming decoder is canonical. The separate alignment pass estimates times;
    /// it must not introduce its own boundary hallucinations into the streaming transcript.
    public static func streamingRows(_ aligned: [ASRSegment], text: String) -> [ASRSegment] {
        let tokens = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !tokens.isEmpty else { return aligned }
        guard tokens.count <= 512, aligned.count <= 512 else { return aligned }
        func key(_ value: String) -> String {
            String(
                value.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
            )
        }
        let a = tokens.map(key)
        let b = aligned.map { key($0.text) }
        let n = a.count
        let m = b.count
        var dp = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        if n > 0, m > 0 {
            for i in stride(from: n - 1, through: 0, by: -1) {
                for j in stride(from: m - 1, through: 0, by: -1) {
                    dp[i][j] = a[i] == b[j] ? dp[i + 1][j + 1] + 1 : max(dp[i + 1][j], dp[i][j + 1])
                }
            }
        }
        var matched: [Int: Int] = [:]
        var i = 0
        var j = 0
        while i < n, j < m {
            if a[i] == b[j] {
                matched[i] = j
                i += 1
                j += 1
            } else if dp[i + 1][j] >= dp[i][j + 1] {
                i += 1
            } else {
                j += 1
            }
        }
        return tokens.enumerated()
            .map { index, token in
                if let match = matched[index] {
                    return ASRSegment(
                        t0_ms: aligned[match].t0_ms, t1_ms: aligned[match].t1_ms, text: token)
                }
                let prior = matched.keys.filter { $0 < index }.max()
                let next = matched.keys.filter { $0 > index }.min()
                let lower = prior.map { aligned[matched[$0]!].t1_ms } ?? 0
                let upper = max(
                    lower,
                    next.map { aligned[matched[$0]!].t0_ms }
                        ?? max(lower + 100, aligned.last?.t1_ms ?? 100))
                let first = (prior ?? -1) + 1
                let last = (next ?? n) - 1
                let count = max(1, last - first + 1)
                let start = lower + (upper - lower) * (index - first) / count
                let end = lower + (upper - lower) * (index - first + 1) / count
                return ASRSegment(t0_ms: start, t1_ms: end, text: token)
            }
    }
    /// Timestamp ownership, not textual deduplication: legitimate repeated words survive.
    public static func ownedRows(_ rows: [ASRSegment], lead: Double, duration: Double)
        -> [ASRSegment]
    {
        rows.compactMap { row in
            let start = Double(row.t0_ms) / 1000 - lead
            let end = Double(row.t1_ms) / 1000 - lead
            let mid = (start + end) / 2
            guard mid >= 0, mid < duration else { return nil }
            return ASRSegment(
                t0_ms: Int(max(0, start) * 1000), t1_ms: Int(min(duration, max(start, end)) * 1000),
                text: row.text)
        }
    }
    public static func language(_ text: String, model: String) -> String {
        let hasKana = text.unicodeScalars.contains { (0x3040...0x30ff).contains($0.value) }
        let hasHan = text.unicodeScalars.contains { (0x4e00...0x9fff).contains($0.value) }
        let hasLatin = text.unicodeScalars.contains {
            (65...90).contains($0.value) || (97...122).contains($0.value)
        }
        if (hasKana || hasHan) && hasLatin { return "mixed / uncertain" }
        if hasKana { return "ja · script estimate" }
        if hasHan { return "zh / ja uncertain" }
        return model == "unified" ? "en · model assumption" : "uncertain"
    }
}
// Future Stage 2 can implement this interface. No network implementation is shipped.
public protocol SessionExporter { func export(sessionID: String, store: Store) async throws }

public enum SpeakerAttribution {
    public static func hasOverlap(_ turns: [SpeakerTurn]) -> Bool {
        for (i, a) in turns.enumerated() {
            for b in turns.dropFirst(i + 1) where a.speaker != b.speaker {
                if min(a.end, b.end) - max(a.start, b.start) > 0.03 { return true }
            }
        }
        return false
    }
    public static func label(
        start: Double, end: Double, turns: [SpeakerTurn], labels: [String: String],
        overlaps: [OverlapSpan] = []
    ) -> String {
        if overlaps.contains(where: { min(end, $0.end) > max(start, $0.start) }) {
            return "Unknown · possible overlap"
        }
        let clipped = turns.compactMap { turn -> SpeakerTurn? in
            let a = max(start, turn.start)
            let b = min(end, turn.end)
            return b > a ? SpeakerTurn(speaker: turn.speaker, start: a, end: b) : nil
        }
        if hasOverlap(clipped) { return "Unknown · overlapping speakers" }
        let totals = Dictionary(grouping: clipped, by: \.speaker)
            .mapValues {
                $0.reduce(0.0) { $0 + $1.end - $1.start }
            }
        let ranked = totals.sorted { $0.value > $1.value }
        if ranked.count > 1, ranked[1].value / max(0.01, end - start) > 0.1 {
            return "Unknown · mixed speakers"
        }
        if let best = ranked.first, best.value / max(0.01, end - start) >= 0.7 {
            return labels[best.key] ?? "Unknown"
        }
        return ranked.count > 1 ? "Unknown · mixed speakers" : "Unknown"
    }
}
