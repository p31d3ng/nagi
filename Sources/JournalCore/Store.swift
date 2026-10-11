import CSQLite
import Foundation

public struct JournalError: LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}
public struct Session: Identifiable, Sendable, Equatable {
    public let id: String
    public let title: String
    public let started: Double
    public let device: String
    public let model: String
    public let status: String
    public let note: String
}
public struct Segment: Identifiable, Sendable, Equatable {
    public let id: Int
    public let session: String
    public let offset: Double
    public let end: Double
    public let raw: String
    public let corrected: String
    public let speaker: String
    public let language: String
    public let chunk: String
}
public struct Chunk: Sendable {
    public let id: String
    public let session: String
    public let path: String
    public let captured: Double
    public let offset: Double
    public let duration: Double
    public let status: String
    public let model: String
}

/// Single serialized SQLite connection. WAL + FULL sync, bound parameters everywhere.
public final class Store: @unchecked Sendable {
    public let root: URL
    private var db: OpaquePointer?
    private let lock = NSRecursiveLock()
    private let cleanupLock = NSLock()
    public init(root: URL) throws {
        self.root = root
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("audio"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("derived"), withIntermediateDirectories: true)
        // Backup metadata can block in the filesystem. Never put it on app startup/capture.
        DispatchQueue.global(qos: .utility)
            .async {
                var excluded = root
                var values = URLResourceValues()
                values.isExcludedFromBackup = true
                try? excluded.setResourceValues(values)
            }
        guard
            sqlite3_open_v2(
                root.appendingPathComponent("journal.sqlite").path, &db,
                SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil)
                == SQLITE_OK
        else { throw JournalError("Cannot open local journal database") }
        sqlite3_busy_timeout(db, 5000)
        try exec("PRAGMA journal_mode=WAL")
        try exec("PRAGMA synchronous=FULL")
        try exec("PRAGMA foreign_keys=ON")
        try exec(
            "CREATE TABLE IF NOT EXISTS sessions(id TEXT PRIMARY KEY,title TEXT,started REAL,device TEXT,model TEXT,status TEXT,note TEXT DEFAULT '')"
        )
        try exec(
            "CREATE TABLE IF NOT EXISTS chunks(id TEXT PRIMARY KEY,session TEXT REFERENCES sessions(id) ON DELETE CASCADE,path TEXT,captured REAL,offset REAL,duration REAL,status TEXT,model TEXT,error TEXT DEFAULT '')"
        )
        try exec(
            "CREATE TABLE IF NOT EXISTS segments(id INTEGER PRIMARY KEY,session TEXT REFERENCES sessions(id) ON DELETE CASCADE,offset REAL,end REAL,raw TEXT,corrected TEXT,speaker TEXT,language TEXT,chunk TEXT)"
        )
        try exec(
            "CREATE TABLE IF NOT EXISTS versions(id INTEGER PRIMARY KEY,segment INTEGER REFERENCES segments(id) ON DELETE CASCADE,text TEXT,created REAL)"
        )
        try exec(
            "CREATE VIRTUAL TABLE IF NOT EXISTS search USING fts5(text,content='segments',content_rowid='id')"
        )
        try exec(
            "CREATE TRIGGER IF NOT EXISTS seg_ai AFTER INSERT ON segments BEGIN INSERT INTO search(rowid,text) VALUES(new.id,new.corrected); END"
        )
        try exec(
            "CREATE TRIGGER IF NOT EXISTS seg_ad AFTER DELETE ON segments BEGIN INSERT INTO search(search,rowid,text) VALUES('delete',old.id,old.corrected); END"
        )
        try exec(
            "CREATE TRIGGER IF NOT EXISTS seg_au AFTER UPDATE OF corrected ON segments BEGIN INSERT INTO search(search,rowid,text) VALUES('delete',old.id,old.corrected); INSERT INTO search(rowid,text) VALUES(new.id,new.corrected); END"
        )
        try exec(
            "CREATE TABLE IF NOT EXISTS asr_runs(chunk TEXT PRIMARY KEY REFERENCES chunks(id) ON DELETE CASCADE,streaming TEXT,aligned TEXT,language TEXT)"
        )
        try exec("CREATE TABLE IF NOT EXISTS settings(key TEXT PRIMARY KEY,value TEXT)")
        try exec(
            "CREATE TABLE IF NOT EXISTS audio_gaps(session TEXT REFERENCES sessions(id) ON DELETE CASCADE,start REAL,end REAL,reason TEXT,PRIMARY KEY(session,start))"
        )
        try exec(
            "CREATE TABLE IF NOT EXISTS capture_progress(session TEXT PRIMARY KEY REFERENCES sessions(id) ON DELETE CASCADE,end REAL,mode TEXT)"
        )
        try exec(
            "CREATE TABLE IF NOT EXISTS live_previews(session TEXT REFERENCES sessions(id) ON DELETE CASCADE,offset REAL,duration REAL,text TEXT,final INTEGER,PRIMARY KEY(session,offset))"
        )
        try exec(
            "CREATE TABLE IF NOT EXISTS speaker_vectors(session TEXT,label TEXT,embedding TEXT,PRIMARY KEY(session,label))"
        )
        try exec(
            "CREATE TABLE IF NOT EXISTS enrollment_vectors(session TEXT REFERENCES sessions(id) ON DELETE CASCADE,chunk TEXT PRIMARY KEY REFERENCES chunks(id) ON DELETE CASCADE,embedding TEXT)"
        )
        try exec("CREATE INDEX IF NOT EXISTS chunks_queue ON chunks(status,captured,offset)")
        try exec("CREATE INDEX IF NOT EXISTS chunks_neighbors ON chunks(session,offset)")
        try exec(
            "CREATE INDEX IF NOT EXISTS chunks_retention ON chunks(captured) WHERE status!='expired' OR path!=''"
        )
        try exec("CREATE INDEX IF NOT EXISTS segments_chunk ON segments(chunk)")
        try exec("CREATE INDEX IF NOT EXISTS segments_session_offset ON segments(session,offset)")
        try exec("CREATE INDEX IF NOT EXISTS segments_offset ON segments(offset)")
        try exec(
            "CREATE TABLE IF NOT EXISTS profiles(id TEXT PRIMARY KEY,embedding TEXT,model TEXT,created REAL)"
        )
        try SummaryStorage.install(self)
    }
    deinit { sqlite3_close(db) }
    @discardableResult public func exec(_ sql: String, _ bindings: [Any] = []) throws -> [[String:
        String]]
    {
        lock.lock()
        defer { lock.unlock() }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw JournalError(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (i, value) in bindings.enumerated() {
            if let s = value as? String {
                sqlite3_bind_text(stmt, Int32(i + 1), s, -1, transient)
            } else if let n = value as? Double {
                sqlite3_bind_double(stmt, Int32(i + 1), n)
            } else if let n = value as? Int {
                sqlite3_bind_int64(stmt, Int32(i + 1), Int64(n))
            }
        }
        var rows: [[String: String]] = []
        while true {
            let code = sqlite3_step(stmt)
            if code == SQLITE_DONE { break }
            guard code == SQLITE_ROW else {
                throw JournalError(String(cString: sqlite3_errmsg(db)))
            }
            var row: [String: String] = [:]
            for i in 0..<sqlite3_column_count(stmt) {
                if let p = sqlite3_column_text(stmt, i) {
                    row[String(cString: sqlite3_column_name(stmt, i))] = String(cString: p)
                }
            }
            rows.append(row)
        }
        return rows
    }
    public func transaction(_ work: () throws -> Void) throws {
        lock.lock()
        defer { lock.unlock() }
        try exec("BEGIN IMMEDIATE")
        do {
            try work()
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }
    public func setting(_ key: String, fallback: String = "") -> String {
        (try? exec("SELECT value FROM settings WHERE key=?", [key]).first?["value"]) ?? fallback
    }
    public func set(_ key: String, _ value: String) throws {
        try exec("INSERT OR REPLACE INTO settings VALUES(?,?)", [key, value])
    }
    public func createSession(
        title: String, device: String, model: String, at: Double = Date().timeIntervalSince1970
    ) throws -> String {
        let id = UUID().uuidString
        try exec(
            "INSERT INTO sessions(id,title,started,device,model,status) VALUES(?,?,?,?,?,'recording')",
            [id, title, at, device, model])
        return id
    }
    public func sessions() throws -> [Session] {
        try exec("SELECT * FROM sessions ORDER BY started DESC LIMIT 500")
            .map {
                Session(
                    id: $0["id"]!, title: $0["title"]!, started: Double($0["started"]!)!,
                    device: $0["device"]!,
                    model: $0["model"]!, status: $0["status"]!, note: $0["note"] ?? "")
            }
    }
    public func finish(_ id: String, note: String = "") throws {
        try exec("UPDATE sessions SET status='finished',note=? WHERE id=?", [note, id])
    }
    public func recordGap(
        session: String, start: Double, end: Double, reason: String = "omitted_nonspeech"
    ) throws {
        guard end > start else { return }
        try exec(
            "INSERT INTO audio_gaps VALUES(?,?,?,?) ON CONFLICT(session,start) DO UPDATE SET end=excluded.end,reason=excluded.reason",
            [session, start, end, reason])
    }
    public func isOmittedSilence(session: String, start: Double, end: Double) -> Bool {
        ((try? exec(
            "SELECT 1 AS found FROM audio_gaps WHERE session=? AND start<=? AND end>=? AND reason='omitted_nonspeech' LIMIT 1",
            [session, start + 0.002, end - 0.002]
        )
        .isEmpty) == false)
    }
    public func registerChunk(
        session: String, path: String, captured: Double, offset: Double, model: String
    ) throws -> String {
        let id = UUID().uuidString
        try exec(
            "INSERT INTO chunks(id,session,path,captured,offset,duration,status,model) VALUES(?,?,?,?,?,0,'writing',?)",
            [id, session, path, captured, offset, model])
        return id
    }
    public func seal(_ id: String, duration: Double) throws {
        try exec("UPDATE chunks SET duration=?,status='queued' WHERE id=?", [duration, id])
    }
    public func chunks(session: String? = nil, status: String? = nil, limit: Int? = nil) throws
        -> [Chunk]
    {
        var whereClauses: [String] = []
        var bindings: [Any] = []
        if let session {
            whereClauses.append("session=?")
            bindings.append(session)
        }
        if let status {
            whereClauses.append("status=?")
            bindings.append(status)
        }
        return try readChunks(
            "SELECT * FROM chunks"
                + (whereClauses.isEmpty ? "" : " WHERE " + whereClauses.joined(separator: " AND "))
                + " ORDER BY captured,offset" + (limit.map { " LIMIT \($0)" } ?? ""), bindings)
    }
    private func readChunks(_ sql: String, _ values: [Any] = []) throws -> [Chunk] {
        return try exec(sql, values)
            .map {
                Chunk(
                    id: $0["id"]!, session: $0["session"]!, path: $0["path"]!,
                    captured: Double($0["captured"]!)!, offset: Double($0["offset"]!)!,
                    duration: Double($0["duration"]!)!, status: $0["status"]!, model: $0["model"]!)
            }
    }
    public func chunksWithAudio() throws -> [Chunk] {
        try readChunks("SELECT * FROM chunks WHERE path!=''")
    }
    public func chunk(_ id: String) throws -> Chunk? {
        try readChunks("SELECT * FROM chunks WHERE id=?", [id]).first
    }
    public func neighbor(_ chunk: Chunk, before: Bool) throws -> Chunk? {
        try readChunks(
            "SELECT * FROM chunks WHERE session=? AND offset" + (before ? "<?" : " >?")
                + " AND status!='writing' ORDER BY offset " + (before ? "DESC" : "ASC")
                + " LIMIT 1",
            [chunk.session, chunk.offset]
        )
        .first
    }
    public func segments(
        session: String? = nil, query: String = "", speaker: String = "", language: String = "",
        chunkID: String? = nil
    ) throws -> [Segment] {
        var predicates: [String] = []
        var values: [Any] = []
        if let session {
            predicates.append("session=?")
            values.append(session)
        }
        if let chunkID {
            predicates.append("chunk=?")
            values.append(chunkID)
        }
        if !query.isEmpty {
            if query.unicodeScalars.contains(where: { $0.value >= 0x3000 }) {
                predicates.append("instr(corrected,?)>0")
                values.append(query)
            } else {
                predicates.append("id IN (SELECT rowid FROM search WHERE search MATCH ?)")
                values.append("\"" + query.replacingOccurrences(of: "\"", with: "\"\"") + "\"*")
            }
        }
        if !speaker.isEmpty {
            predicates.append("speaker=?")
            values.append(speaker)
        }
        if !language.isEmpty {
            predicates.append("language=?")
            values.append(language)
        }
        return try exec(
            "SELECT * FROM segments"
                + (predicates.isEmpty ? "" : " WHERE " + predicates.joined(separator: " AND "))
                + " ORDER BY session,offset LIMIT 2000", values
        )
        .map {
            Segment(
                id: Int($0["id"]!)!, session: $0["session"]!, offset: Double($0["offset"]!)!,
                end: Double($0["end"]!)!, raw: $0["raw"]!, corrected: $0["corrected"]!,
                speaker: $0["speaker"]!, language: $0["language"]!, chunk: $0["chunk"]!)
        }
    }
    public func insertSegment(
        session: String, offset: Double, end: Double, raw: String, corrected: String,
        speaker: String,
        language: String, chunk: String
    ) throws {
        try exec(
            "INSERT INTO segments(session,offset,end,raw,corrected,speaker,language,chunk) VALUES(?,?,?,?,?,?,?,?)",
            [session, offset, end, raw, corrected, speaker, language, chunk])
    }
    public func edit(_ id: Int, text: String, speaker: String) throws {
        try transaction {
            try exec(
                "INSERT INTO versions(segment,text,created) SELECT id,corrected,? FROM segments WHERE id=?",
                [Date().timeIntervalSince1970, id])
            let prior = try exec("SELECT speaker FROM segments WHERE id=?", [id]).first?["speaker"]
            try exec("UPDATE segments SET corrected=?,speaker=? WHERE id=?", [text, speaker, id])
            if prior != speaker {
                try exec("INSERT OR REPLACE INTO summary_attribution VALUES(?,'manual')", [id])
            }
            try exec(
                "UPDATE summary_changes SET revision=revision+1 WHERE session=(SELECT session FROM segments WHERE id=?)",
                [id])
        }
    }
    public func undo(_ id: Int) throws {
        try transaction {
            if let row = try exec(
                "SELECT id,text FROM versions WHERE segment=? ORDER BY id DESC LIMIT 1", [id]
            )
            .first {
                try exec("UPDATE segments SET corrected=? WHERE id=?", [row["text"]!, id])
                try exec("DELETE FROM versions WHERE id=?", [Int(row["id"]!)!])
            } else {
                try exec("UPDATE segments SET corrected=raw WHERE id=?", [id])
            }
        }
    }
    public func deleteSession(_ id: String) throws {
        for chunk in try readChunks("SELECT * FROM chunks WHERE session=? AND path!=''", [id]) {
            if !chunk.path.isEmpty {
                let file = root.appendingPathComponent(chunk.path)
                if FileManager.default.fileExists(atPath: file.path) {
                    try FileManager.default.removeItem(at: file)
                }
            }
        }
        for file
            in (try? FileManager.default.contentsOfDirectory(
                at: root.appendingPathComponent("derived"), includingPropertiesForKeys: nil)) ?? []
        {
            let owner = file.lastPathComponent.components(separatedBy: ".").first ?? ""
            if try chunk(owner)?.session == id { try FileManager.default.removeItem(at: file) }
        }
        try exec("DELETE FROM speaker_vectors WHERE session=?", [id])
        try exec(
            "DELETE FROM settings WHERE key IN (?,?,?)",
            ["metadata-" + id, "rules-" + id, "format-" + id])
        try exec("DELETE FROM sessions WHERE id=?", [id])
    }
    /// Deletes audio and all temporary derivatives by the original capture timestamp.
    /// Expiry can only execute while the machine/app runs; expired playback is disabled separately.
    public func cleanup(now: Double = Date().timeIntervalSince1970, cap: Int = 500_000_000) throws
        -> Int
    {
        cleanupLock.lock()
        defer { cleanupLock.unlock() }
        var removed = 0
        try SummaryStorage.recordFinalized(self)
        while true {
            let batch = try readChunks(
                "SELECT * FROM chunks WHERE captured<=? AND (status!='expired' OR path!='') LIMIT 128",
                [now - 172800])
            if batch.isEmpty { break }
            for chunk in batch {
                let url = root.appendingPathComponent(chunk.path)
                if !chunk.path.isEmpty, FileManager.default.fileExists(atPath: url.path) {
                    try FileManager.default.removeItem(at: url)
                    removed += 1
                }
                try exec("UPDATE chunks SET status='expired',path='' WHERE id=?", [chunk.id])
            }
        }
        let derived = root.appendingPathComponent("derived")
        for url
            in (try? FileManager.default.contentsOfDirectory(
                at: derived, includingPropertiesForKeys: nil))
            ?? []
        {
            let owner = url.lastPathComponent.components(separatedBy: ".").first ?? ""
            let contextExpired =
                url.lastPathComponent.contains(".context.")
                && ((try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]
                    as? Date)?
                    .timeIntervalSince1970 ?? now) <= now - 172800
            if let ownerChunk = try chunk(owner), audioAvailable(ownerChunk, now: now),
                !contextExpired
            {
                continue
            }
            try FileManager.default.removeItem(at: url)
        }
        if cap > 0 {
            while let size = try exec(
                "SELECT COALESCE(SUM(length(CAST(raw AS BLOB))+length(CAST(corrected AS BLOB))),0)+(SELECT COALESCE(SUM(length(CAST(text AS BLOB))),0) FROM versions)+(SELECT COALESCE(SUM(length(CAST(streaming AS BLOB))+length(CAST(aligned AS BLOB))),0) FROM asr_runs)+(SELECT COALESCE(SUM(length(CAST(text AS BLOB))),0) FROM live_previews) +(SELECT COALESCE(SUM(length(CAST(response AS BLOB))),0) FROM summaries) AS bytes FROM segments"
            )
            .first?["bytes"], Int(size)! > cap,
                let oldest = try exec(
                    "SELECT id FROM sessions WHERE status != 'recording' ORDER BY started LIMIT 1"
                )
                .first?["id"]
            { try deleteSession(oldest) }
        }
        return removed
    }
    public func audioAvailable(_ chunk: Chunk, now: Double = Date().timeIntervalSince1970) -> Bool {
        !chunk.path.isEmpty && now < chunk.captured + 172800
            && FileManager.default.fileExists(atPath: root.appendingPathComponent(chunk.path).path)
    }
    public func recover() throws {
        try exec(
            "UPDATE chunks SET status='queued',error='Worker interrupted; retry available' WHERE status='processing'"
        )
        try exec(
            "UPDATE sessions SET status='interrupted',note='Recording interrupted. Durable chunks recovered; check the final chunk.' WHERE status='recording'"
        )
    }
}

public struct Replacement: Codable, Equatable {
    public var from: String
    public var to: String
    public init(from: String, to: String) {
        self.from = from
        self.to = to
    }
}
public enum DictionaryCorrection {
    public static func apply(_ text: String, rules: [Replacement]) -> String {
        rules.reduce(text) { result, rule in
            rule.from.isEmpty ? result : result.replacingOccurrences(of: rule.from, with: rule.to)
        }
    }
}
public enum VoiceMatch {
    public static func cosine(_ a: [Float], _ b: [Float]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return -1 }
        let dot = zip(a, b).reduce(0.0) { $0 + Double($1.0 * $1.1) }
        let na = a.reduce(0.0) { $0 + Double($1 * $1) }
        let nb = b.reduce(0.0) { $0 + Double($1 * $1) }
        return na > 0 && nb > 0 ? dot / sqrt(na * nb) : -1
    }
    public static func label(score: Double, runnerUp: Double, threshold: Double = 0.8) -> String {
        score >= threshold && score - runnerUp >= 0.12 ? "Me" : "Unknown"
    }
}

public enum TranscriptCapacity {
    public static func bytes(megabytes: String) throws -> Int {
        guard let value = Int(megabytes), value >= 1, value <= 10000 else {
            throw JournalError(
                "Choose a transcript cap from 1 to 10,000 MB, or turn the cap off to keep transcripts until deleted."
            )
        }
        return value * 1_000_000
    }
}
