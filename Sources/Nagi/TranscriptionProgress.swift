import Foundation

/// Describes queue evidence, without guessing that RAM, silence or a wireless link is the cause.
enum TranscriptionProgress {
    static func queue(_ rows: [[String: String]]) -> String {
        let queued = rows.first { $0["status"] == "queued" }
        let n = Int(queued?["n"] ?? "0") ?? 0, seconds = Double(queued?["seconds"] ?? "0") ?? 0
        let processing = Int(rows.first { $0["status"] == "processing" }?["n"] ?? "0") ?? 0
        let errors = rows.filter { ["failed", "needs_speakers"].contains($0["status"] ?? "") }
            .reduce(0) { $0 + (Int($1["n"] ?? "0") ?? 0) }
        if n + processing + errors == 0 { return "Queue clear" }
        return
            "\(n) queued (\(String(format:"%.1f",seconds)) s of source audio) · \(processing) processing"
            + (errors > 0 ? " · \(errors) need attention" : "")
    }
    static func liveHint(model: String, dual: Bool) -> String {
        if model == "whisper" {
            return
                "Whisper has no incremental live preview. Text appears after saved chunks are finalized and processed (up to 10 saved audio seconds, or Stop). Check Timeline for results and errors."
        }
        if dual {
            return
                "Microphone + system audio use finalized chunk updates. Text appears after processing; no incremental preview in dual-source mode."
        }
        return
            "English streaming preview; final words and speaker labels may change after processing."
    }
    static func describe(
        model: String, recording: Bool, speechOnly: Bool, statuses: [String: Int], transcripts: Int
    ) -> String {
        let total = statuses.values.reduce(0, +), bad = statuses["failed", default: 0],
            queued = statuses["queued", default: 0], working = statuses["processing", default: 0],
            writing = statuses["writing", default: 0]
        if bad > 0 {
            return
                "\(bad) audio chunk(s) failed processing. Read the error below, check Settings → Models, then Retry. Saved audio remains until expiry."
        }
        if queued + working > 0 {
            return
                "\(queued) queued · \(working) processing · \(transcripts) transcript span(s). ASR and speaker analysis run sequentially."
        }
        if total == 0 || writing == total {
            if recording {
                return speechOnly
                    ? "Waiting for saved speech. VAD may omit quiet/short speech; try Continuous for diagnosis. Stop finalizes a partial chunk."
                    : "Waiting for a finalized audio chunk (up to 10 audio seconds). Stop saves and processes a partial chunk."
            }
            return
                "No finalized audio to transcribe. Check received-audio levels and try a short Continuous recording; speech-only detection can omit faint/short speech."
        }
        if statuses["needs_speakers", default: 0] > 0 {
            return
                "Transcription saved; speaker analysis needs attention. Retry preserves text and corrections."
        }
        if statuses["silence", default: 0] == total {
            return
                "Saved audio was near digital silence; ASR was skipped. Quiet audio does not prove transmitter disconnection."
        }
        if transcripts == 0 && statuses["expired", default: 0] > 0 {
            return "Audio has expired; it cannot be retranscribed. Any existing transcript remains."
        }
        if transcripts == 0 {
            return
                "Processing completed without speech text. Check received audio and the selected model/language; try Continuous. This is not proof of a memory limitation."
        }
        return "\(transcripts) transcript span(s) saved. "
            + (model == "whisper"
                ? "Whisper uses finalized chunk updates, not incremental live text." : "")
    }
}
