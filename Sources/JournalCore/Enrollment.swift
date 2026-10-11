import Foundation

/// Enrollment only replaces a profile after the complete, explicit sample has passed validation.
public enum Enrollment {
    public static let model = "Community1/fc8c3e4"
    public static func centroid(_ vectors: [[Float]]) throws -> [Float] {
        guard !vectors.isEmpty,
            vectors.allSatisfy({
                $0.count == 256 && $0.allSatisfy(\.isFinite) && VoiceMatch.cosine($0, $0) > 0.99
            })
        else {
            throw JournalError(
                "Enrollment did not produce a valid Community-1 voice signature. Please retry.")
        }
        guard vectors.dropFirst().allSatisfy({ VoiceMatch.cosine(vectors[0], $0) >= 0.8 }) else {
            throw JournalError(
                "The enrollment sample contained inconsistent voices. Retry alone with the same microphone position."
            )
        }
        let normalized = vectors.map { v -> [Float] in
            let length = sqrt(v.reduce(Float(0)) { $0 + $1 * $1 })
            return v.map { $0 / length }
        }
        return (0..<256)
            .map { i in normalized.reduce(Float(0)) { $0 + $1[i] } / Float(vectors.count) }
    }
    public static func finalize(_ store: Store) throws {
        let id = store.setting("enrollment-session")
        guard !id.isEmpty, store.setting("enrollment-finalized-session") != id,
            let session = try store.exec("SELECT status FROM sessions WHERE id=?", [id]).first,
            session["status"] != "recording"
        else { return }
        let chunks = try store.chunks(session: id)
        guard !chunks.contains(where: { ["writing", "queued", "processing"].contains($0.status) })
        else { return }
        do {
            guard chunks.reduce(0, { $0 + $1.duration }) >= 8 else {
                throw JournalError(
                    "No usable enrollment audio was saved. Check input levels, then record at least 8 seconds in Voice profile. Your previous profile, if any, is unchanged."
                )
            }
            guard !chunks.contains(where: { $0.status != "done" }) else {
                throw JournalError(
                    "Enrollment did not finish successfully. Review the enrollment session and retry in a quiet room. Your previous profile is unchanged."
                )
            }
            let vectors =
                try store.exec(
                    "SELECT embedding FROM enrollment_vectors WHERE session=? ORDER BY chunk", [id]
                )
                .compactMap { row in
                    row["embedding"]
                        .flatMap { try? JSONDecoder().decode([Float].self, from: Data($0.utf8)) }
                }
            let vector = try centroid(vectors)
            let encoded = String(data: try JSONEncoder().encode(vector), encoding: .utf8)!
            try store.transaction {
                try store.exec(
                    "INSERT OR REPLACE INTO profiles VALUES('Me',?,?,?)",
                    [encoded, model, Date().timeIntervalSince1970])
                try store.set(
                    "enrollment-result",
                    "Local voice profile saved successfully · ready for future recordings")
                try store.set("enrollment-finalized-session", id)
                try store.exec("DELETE FROM enrollment_vectors WHERE session=?", [id])
            }
        } catch {
            try store.set("enrollment-result", error.localizedDescription)
            try store.set("enrollment-finalized-session", id)
        }
    }
}
