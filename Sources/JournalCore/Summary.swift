import CryptoKit
import Foundation
import LocalAuthentication
import Security

public enum SummaryEndpoint {
    public static let suggested =
        "https://nagi-summary-dev.spring-rain-67cb.workers.dev/v1/summarize"
    public static func validate(_ text: String) throws -> URL {
        guard
            var parts = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
            parts.scheme?.lowercased() == "https", let host = parts.host, !host.isEmpty,
            parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
            parts.port.map({ (1...65535).contains($0) }) ?? true
        else {
            throw JournalError(
                "Use a direct HTTPS endpoint without credentials, query parameters or fragments.")
        }
        parts.scheme = "https"; parts.host = host.lowercased()
        if parts.port == 443 { parts.port = nil }
        if parts.path.isEmpty { parts.path = "/" }
        guard let url = parts.url else { throw JournalError("Invalid HTTPS endpoint.") }
        return url
    }
}
public protocol SummaryCredentialVault: AnyObject {
    func contains(endpoint: URL) -> Bool
    func read(endpoint: URL) throws -> String
    func save(_ bearer: String, endpoint: URL) throws
    func delete(endpoint: URL) throws
}
public final class SummaryKeychain: SummaryCredentialVault {
    private let service = "local.nagi.journal.summary"
    public init() {}
    private func query(_ endpoint: URL) -> [String: Any] {
        let context = LAContext(); context.interactionNotAllowed = true
        return [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: endpoint.absoluteString,
            kSecAttrSynchronizable as String: false,
            kSecUseAuthenticationContext as String: context,
        ]
    }
    public func contains(endpoint: URL) -> Bool {
        var q = query(endpoint); q[kSecReturnAttributes as String] = true
        return SecItemCopyMatching(q as CFDictionary, nil) == errSecSuccess
    }
    public func read(endpoint: URL) throws -> String {
        var q = query(endpoint); q[kSecReturnData as String] = true
        var result: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess,
            let data = result as? Data, let value = String(data: data, encoding: .utf8)
        else {
            throw JournalError(
                "App bearer unavailable. Unlock Keychain or enter it again in Settings.")
        }
        return value
    }
    public func save(_ bearer: String, endpoint: URL) throws {
        guard bearer.range(of: "^[A-Za-z0-9_-]{32,128}$", options: .regularExpression) != nil
        else {
            throw JournalError(
                "Enter the original app bearer (32–128 letters, numbers, _ or -), not the deploy token or SHA-256 digest."
            )
        }
        let data = Data(bearer.utf8)
        let q = query(endpoint)
        var status = SecItemUpdate(
            q as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = q; item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            throw JournalError(
                "Could not save app bearer in Keychain. No credential was written to the journal.")
        }
    }
    public func delete(endpoint: URL) throws {
        let status = SecItemDelete(query(endpoint) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw JournalError("Could not remove the Keychain credential.")
        }
    }
}
public struct SummaryTurn: Codable, Equatable, Sendable {
    public var id: String
    public var start: Double
    public var end: Double
    public var speakerId: String
    public var speakerLabel: String
    public var language: String
    public var text: String
    public var uncertain: Bool
    public var overlap: Bool
    public var attribution: String
}
public struct SummaryInput: Codable, Sendable {
    public var id: String
    public var version: Int
    public var final = true
    public var processingComplete = true
    public var segments: [SummaryTurn]
}
public struct SummarySource: Codable, Equatable, Sendable {
    public var segmentId: String
    public var start: Double
    public var end: Double
    public var speakerId: String
    public var speakerLabel: String
    public var uncertain: Bool
    public var overlap: Bool
}
public struct SummaryItem: Codable, Sendable {
    public var text: String?
    public var quote: String?
    public var sources: [SummarySource]
}
public struct GeneratedSummary: Codable, Sendable {
    public var overview: String
    public var highlights: [SummaryItem]
    public var decisions: [SummaryItem]
    public var actionItems: [SummaryItem]
    public var reviewRequired: Bool
}
public struct SummaryEnvelope: Codable, Sendable {
    public var id: String
    public var version: Int
    public var model: String
    public var summary: GeneratedSummary
    public func checked(against input: SummaryInput) throws -> SummaryEnvelope {
        guard id == input.id, version == input.version, model.utf8.count <= 200,
            summary.overview.count <= 3000
        else {
            throw JournalError(
                "The service returned a mismatched or invalid summary. It may have processed the request; retry only manually."
            )
        }
        let turns = Dictionary(uniqueKeysWithValues: input.segments.map { ($0.id, $0) })
        var result = self
        func check(_ items: [SummaryItem], quotes: Bool) throws -> [SummaryItem] {
            guard items.count <= 8 else { throw JournalError("Invalid summary item count.") }
            return try items.map { item in
                guard (1...8).contains(item.sources.count),
                    let value = quotes ? item.quote : item.text, value.count <= 1000,
                    item.sources.allSatisfy({ turns[$0.segmentId] != nil }),
                    !quotes
                        || item.sources.contains(where: {
                            turns[$0.segmentId]!.text.contains(value)
                        })
                else {
                    throw JournalError(
                        "Invalid summary evidence. The request may have been processed; retry only manually."
                    )
                }
                if quotes {
                    guard item.text == nil,
                        value.trimmingCharacters(in: .whitespacesAndNewlines).count >= 4
                    else {
                        throw JournalError(
                            "Invalid quoted summary item. Unexpected text or empty evidence was discarded."
                        )
                    }
                }
                var safe = item
                if quotes { safe.text = nil } else { safe.quote = nil }
                // Local source metadata is authoritative, even with a custom endpoint.
                safe.sources = item.sources.map { source in
                    let t = turns[source.segmentId]!
                    return SummarySource(
                        segmentId: t.id, start: t.start, end: t.end,
                        speakerId: t.speakerId, speakerLabel: t.speakerLabel,
                        uncertain: t.uncertain, overlap: t.overlap)
                }
                return safe
            }
        }
        result.summary.highlights = try check(summary.highlights, quotes: false)
        result.summary.decisions = try check(summary.decisions, quotes: true)
        result.summary.actionItems = try check(summary.actionItems, quotes: true)
        result.summary.reviewRequired = true
        return result
    }
}
public struct SummarySnapshot: Sendable {
    public var input: SummaryInput
    public var body: Data
}
public enum SummaryStorage {
    public static func install(_ store: Store) throws {
        try store.exec(
            "CREATE TABLE IF NOT EXISTS summary_changes(session TEXT PRIMARY KEY REFERENCES sessions(id) ON DELETE CASCADE,revision INTEGER NOT NULL)"
        )
        try store.exec("INSERT OR IGNORE INTO summary_changes SELECT id,1 FROM sessions")
        for (name, event, condition) in [
            ("summary_insert", "INSERT", "1"),
            (
                "summary_edit", "UPDATE OF corrected,speaker,language,offset,end",
                "new.corrected!=old.corrected OR new.speaker!=old.speaker OR new.language!=old.language OR new.offset!=old.offset OR new.end!=old.end"
            ),
        ] {
            try store.exec(
                "CREATE TRIGGER IF NOT EXISTS \(name) AFTER \(event) ON segments WHEN \(condition) BEGIN INSERT INTO summary_changes VALUES(new.session,1) ON CONFLICT(session) DO UPDATE SET revision=revision+1; END"
            )
        }
        try store.exec(
            "CREATE TABLE IF NOT EXISTS summary_attribution(segment INTEGER PRIMARY KEY REFERENCES segments(id) ON DELETE CASCADE,origin TEXT)"
        )
        try store.exec(
            "CREATE TRIGGER IF NOT EXISTS summary_note AFTER UPDATE OF note ON sessions WHEN new.note!=old.note BEGIN INSERT INTO summary_changes VALUES(new.id,1) ON CONFLICT(session) DO UPDATE SET revision=revision+1; END"
        )
        try store.exec(
            "CREATE TRIGGER IF NOT EXISTS summary_speaker_origin AFTER UPDATE OF speaker ON segments WHEN new.speaker!=old.speaker BEGIN DELETE FROM summary_attribution WHERE segment=new.id; END"
        )
        try store.exec(
            "CREATE TABLE IF NOT EXISTS summary_chunk_final(chunk TEXT PRIMARY KEY REFERENCES chunks(id) ON DELETE CASCADE)"
        )
        try store.exec(
            "INSERT OR IGNORE INTO summary_chunk_final SELECT id FROM chunks WHERE status IN ('done','silence')"
        )
        try store.exec(
            "CREATE TRIGGER IF NOT EXISTS summary_chunk_done AFTER UPDATE OF status ON chunks WHEN new.status IN ('done','silence') BEGIN INSERT OR IGNORE INTO summary_chunk_final VALUES(new.id); END"
        )
        try store.exec(
            "CREATE TRIGGER IF NOT EXISTS summary_chunk_expiring BEFORE UPDATE OF status ON chunks WHEN new.status='expired' AND old.status IN ('done','silence') BEGIN INSERT OR IGNORE INTO summary_chunk_final VALUES(old.id); END"
        )
        try store.exec(
            "CREATE TRIGGER IF NOT EXISTS summary_chunk_reprocess AFTER UPDATE OF status ON chunks WHEN new.status NOT IN ('done','silence','expired') BEGIN DELETE FROM summary_chunk_final WHERE chunk=new.id; END"
        )
        try store.exec(
            "CREATE TABLE IF NOT EXISTS summary_ready(session TEXT PRIMARY KEY REFERENCES sessions(id) ON DELETE CASCADE)"
        )
        try store.exec("CREATE INDEX IF NOT EXISTS chunks_summary_ready ON chunks(session,status)")
        try store.exec(
            "CREATE TABLE IF NOT EXISTS summary_auto(session TEXT PRIMARY KEY REFERENCES sessions(id) ON DELETE CASCADE,endpoint TEXT,state TEXT DEFAULT 'waiting')"
        )
        try store.exec(
            "CREATE INDEX IF NOT EXISTS summary_auto_ready ON summary_auto(state,endpoint)")
        try store.exec(
            "CREATE TABLE IF NOT EXISTS summaries(id TEXT PRIMARY KEY,session TEXT REFERENCES sessions(id) ON DELETE CASCADE,version INTEGER,endpoint TEXT,status TEXT,error TEXT DEFAULT '',response TEXT DEFAULT '',created REAL,automatic INTEGER)"
        )
        try store.exec("CREATE INDEX IF NOT EXISTS summaries_session ON summaries(session,created)")
    }
    public static func recordFinalized(_ store: Store) throws {
        try store.exec(
            "INSERT OR IGNORE INTO summary_ready SELECT id FROM sessions s WHERE status!='recording' AND NOT EXISTS(SELECT 1 FROM summary_ready r WHERE r.session=s.id) AND NOT EXISTS(SELECT 1 FROM chunks c WHERE c.session=s.id AND NOT (c.status IN ('done','silence') OR (c.status='expired' AND EXISTS(SELECT 1 FROM summary_chunk_final f WHERE f.chunk=c.id))))"
        )
    }
    public static func ready(_ store: Store, session: String) throws -> Bool {
        try recordFinalized(store)
        return
            !(try store.exec(
                "SELECT 1 FROM sessions s JOIN summary_ready r ON r.session=s.id WHERE s.id=? AND s.status!='recording' AND NOT EXISTS(SELECT 1 FROM chunks c WHERE c.session=s.id AND NOT (c.status IN ('done','silence') OR (c.status='expired' AND EXISTS(SELECT 1 FROM summary_chunk_final f WHERE f.chunk=c.id))))",
                [session]))
            .isEmpty
    }
    public static func revision(_ store: Store, session: String) -> Int {
        Int(
            (try? store.exec("SELECT revision FROM summary_changes WHERE session=?", [session])
                .first?["revision"]) ?? "0") ?? 0
    }
    public static func snapshot(_ store: Store, session: String) throws -> SummarySnapshot {
        var result: SummarySnapshot!
        try store.transaction {
            guard try ready(store, session: session) else {
                throw JournalError(
                    "Wait until recording is stopped and final transcription/speaker processing is complete. Failed processing must be retried first; expired incomplete audio cannot be finalized."
                )
            }
            let size = try store
                .exec(
                    "SELECT COUNT(*) AS n,COALESCE(SUM(length(CAST(corrected AS BLOB))),0) AS bytes FROM segments WHERE session=?",
                    [session]
                )
                .first!
            guard Int(size["n"]!)! <= 4096 else {
                throw JournalError(
                    "The bounded local exporter supports up to 4,096 source spans. Nothing was sent or truncated."
                )
            }
            guard Int(size["bytes"]!)! <= 16384 else {
                throw JournalError(
                    "Conversation exceeds the service's 16 KiB / 64-turn limit. Nothing was sent or truncated. Use a shorter conversation; long-transcript support is not available yet."
                )
            }
            let rows = try store.exec(
                "SELECT s.*,a.origin,COALESCE((SELECT origin FROM chunk_sources WHERE chunk=s.chunk),'legacy') AS audio_origin FROM segments s LEFT JOIN summary_attribution a ON a.segment=s.id WHERE s.session=? ORDER BY s.offset,s.id",
                [session])
            let overlap =
                ((try store.exec("SELECT note FROM sessions WHERE id=?", [session]).first?["note"])
                ?? "")
                .contains("overlapping")
            var turns: [SummaryTurn] = []
            var priorAudioOrigin = ""
            for row in rows {
                let text = row["corrected"]!.trimmingCharacters(in: .whitespacesAndNewlines)
                if text.isEmpty { continue }
                let label = row["speaker"]!, language = row["language"]!
                let start = Double(row["offset"]!)!, end = Double(row["end"]!)!
                guard label.count <= 80, language.count <= 40, text.count <= 4000,
                    start.isFinite, end.isFinite, start >= 0, end >= start, end <= 604800
                else {
                    throw JournalError(
                        "Transcript contains a span outside the service limits. Nothing was sent.")
                }
                let origin = row["origin"] ?? "unknown"
                let uncertain = origin != "manual" || label.hasPrefix("Unknown")
                let audioOrigin = row["audio_origin"] ?? "legacy"
                if audioOrigin == priorAudioOrigin, let last = turns.last,
                    last.speakerLabel == label, last.language == language,
                    last.attribution == origin, last.uncertain == uncertain,
                    start >= last.end - 0.001, start - last.end <= 1,
                    last.text.count + text.count + 1 <= 4000
                {
                    turns[turns.count - 1].text += " " + text
                    turns[turns.count - 1].end = end
                } else {
                    let speaker = SHA256.hash(data: Data(label.utf8)).prefix(8)
                        .map { String(format: "%02x", $0) }.joined()
                    turns.append(
                        SummaryTurn(
                            id: "s" + row["id"]!, start: start, end: end,
                            speakerId: "speaker_" + speaker, speakerLabel: label,
                            language: language,
                            text: text, uncertain: uncertain, overlap: overlap, attribution: origin)
                    )
                }
                priorAudioOrigin = audioOrigin
            }
            guard !turns.isEmpty else {
                throw JournalError("No finalized speech text to summarize.")
            }
            guard turns.count <= 64 else {
                throw JournalError(
                    "Conversation has more than 64 speaker turns. Nothing was sent or truncated.")
            }
            let version = revision(store, session: session)
            guard version > 0, version <= 2147483647 else {
                throw JournalError("Transcript revision is unavailable.")
            }
            let input = SummaryInput(id: session, version: version, segments: turns)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let body = try encoder.encode(input)
            guard body.count <= 16384 else {
                throw JournalError(
                    "Transcript plus speaker/timestamp metadata exceeds 16 KiB. Nothing was sent or truncated."
                )
            }
            result = SummarySnapshot(input: input, body: body)
        }
        return result
    }
}
