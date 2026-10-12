import Foundation

/// Native worker evidence only; ignore arbitrary log text and unknown stage names.
public enum WorkerStage {
    public static func last(in log: String) -> String? {
        let allowed: Set<String> = ["model_loading", "transcribing", "aligning"]
        return log.split(separator: "\n").reversed()
            .compactMap { line -> String? in
                guard line.hasPrefix("NAGI_STAGE ") else { return nil }
                let stage = String(line.dropFirst("NAGI_STAGE ".count))
                return allowed.contains(stage) ? stage : nil
            }
            .first
    }
}
