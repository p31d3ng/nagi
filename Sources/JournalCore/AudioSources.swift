import Foundation

/// Capture origin is independent of a person's speaker identity.
public enum AudioOrigin: String, CaseIterable, Sendable {
    case legacy, microphone, system, file
    public var title: String {
        switch self {
        case .legacy: return "Original audio"
        case .microphone: return "Microphone"
        case .system: return "System audio"
        case .file: return "Imported audio"
        }
    }
}
public enum AudioSources {
    public static func timestamp(sample: Double?, anchor: Double, now: Double) -> (
        offset: Double, clock: String
    ) {
        if let sample, sample.isFinite, sample >= anchor, abs(sample - now) < 5 {
            return (sample - anchor, "host")
        }
        return (max(0, now - anchor), "arrival")
    }
    public static func install(_ store: Store) throws {
        try store.exec(
            "CREATE TABLE IF NOT EXISTS chunk_sources(chunk TEXT PRIMARY KEY REFERENCES chunks(id) ON DELETE CASCADE,origin TEXT NOT NULL,clock TEXT NOT NULL)"
        )
        try store.exec(
            "CREATE TABLE IF NOT EXISTS source_gaps(session TEXT REFERENCES sessions(id) ON DELETE CASCADE,origin TEXT,start REAL,end REAL,reason TEXT,PRIMARY KEY(session,origin,start))"
        )
        try store.exec(
            "CREATE TABLE IF NOT EXISTS source_status(session TEXT REFERENCES sessions(id) ON DELETE CASCADE,origin TEXT,status TEXT,detail TEXT,PRIMARY KEY(session,origin))"
        )
        try store.exec(
            "CREATE TABLE IF NOT EXISTS echo_checks(mic TEXT REFERENCES chunks(id) ON DELETE CASCADE,system TEXT REFERENCES chunks(id) ON DELETE CASCADE,PRIMARY KEY(mic,system))"
        )
        try store.exec(
            "CREATE TABLE IF NOT EXISTS echo_annotations(mic TEXT REFERENCES chunks(id) ON DELETE CASCADE,system TEXT REFERENCES chunks(id) ON DELETE CASCADE,score REAL,lag REAL,dismissed INTEGER DEFAULT 0,PRIMARY KEY(mic,system))"
        )
    }
    public static func origin(_ store: Store, chunk: String) -> AudioOrigin {
        AudioOrigin(
            rawValue: (try? store.exec("SELECT origin FROM chunk_sources WHERE chunk=?", [chunk])
                .first?["origin"]) ?? "legacy") ?? .legacy
    }
    public static func status(
        _ store: Store, session: String, origin: AudioOrigin, status: String, detail: String = ""
    ) throws {
        try store.exec(
            "INSERT OR REPLACE INTO source_status VALUES(?,?,?,?)",
            [session, origin.rawValue, status, detail])
    }
    public static func gap(
        _ store: Store, session: String, origin: AudioOrigin, start: Double, end: Double,
        reason: String
    ) throws {
        guard start.isFinite, end.isFinite, end > start else { return }
        try store.exec(
            "INSERT OR REPLACE INTO source_gaps VALUES(?,?,?,?,?)",
            [session, origin.rawValue, start, end, reason])
    }
    public static func echo(_ store: Store, chunk: String) -> Bool {
        ((try? store.exec(
            "SELECT 1 FROM echo_annotations WHERE mic=? AND dismissed=0 LIMIT 1", [chunk]
        )
        .isEmpty) == false)
    }
    public static func dismissEcho(_ store: Store, chunk: String, dismissed: Bool) throws {
        try store.exec(
            "UPDATE echo_annotations SET dismissed=? WHERE mic=?", [dismissed ? 1 : 0, chunk])
    }
    // Missing rows deliberately retain legacy behavior, without guessing their source.
    public static let sameOriginSQL =
        "COALESCE((SELECT origin FROM chunk_sources WHERE chunk=chunks.id),'legacy')=?"
    public static func firstOffset(_ store: Store, session: String, origin: AudioOrigin) throws
        -> Double?
    {
        let row =
            try store.exec(
                "SELECT offset FROM chunks WHERE session=? AND " + sameOriginSQL
                    + " ORDER BY offset LIMIT 1", [session, origin.rawValue]
            )
            .first
        return row?["offset"].flatMap(Double.init)
    }
}

/// Evidence only. Never alters audio, text, labels, or timestamps; high similarity isn't proof of echo.
public enum EchoEvidence {
    public static func match(microphone: [Float], system: [Float], rate: Int = 2000) -> (
        score: Double, lag: Double
    )? {
        guard rate > 0, microphone.count <= rate * 12, system.count <= rate * 12,
            min(microphone.count, system.count) >= rate,
            microphone.allSatisfy(\.isFinite), system.allSatisfy(\.isFinite)
        else { return nil }
        var best = (score: 0.0, lag: 0.0)
        // Three separate windows must agree, suppressing short coincidental similarities.
        for lag in stride(from: max(1, rate / 50), through: rate / 2, by: max(1, rate / 200)) {
            let n = min(microphone.count - lag, system.count)
            guard n >= rate else { continue }
            var scores: [Double] = []
            for window in 0..<3 {
                let lo = window * n / 3, hi = (window + 1) * n / 3
                var xy = 0.0, xx = 0.0, yy = 0.0
                for i in lo..<hi {
                    let a = Double(microphone[i + lag]), b = Double(system[i])
                    xy += a * b; xx += a * a; yy += b * b
                }
                guard xx > 0.0001, yy > 0.0001 else { scores = []; break }
                scores.append(xy / sqrt(xx * yy))
            }
            if scores.count == 3, let score = scores.min(), score > best.score {
                best = (score, Double(lag) / Double(rate))
            }
        }
        return best.score >= 0.985 ? best : nil
    }
}
