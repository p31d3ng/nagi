import AVFoundation
import CoreML
import FluidAudio
import Foundation

struct Turn: Codable {
    let speaker: String
    let start: Double
    let end: Double
}
struct Overlap: Codable {
    let start: Double
    let end: Double
}
struct Result: Codable {
    let overlaps: [Overlap]
    let turns: [Turn]
    let embeddings: [String: [Float]]
    let elapsed: Double
    let model: String
}
// Pinned Community-1 powerset mapping: empty, three singletons, then pairs/triple.
// Preserve overlap evidence BEFORE speaker clustering can merge both voices into one identity.
func overlapHints(audio: URL, models: URL) throws -> [Overlap] {
    let url = models.appendingPathComponent("speaker-diarization/Segmentation.mlmodelc")
    let config = MLModelConfiguration()
    config.computeUnits = .cpuAndNeuralEngine
    let model = try MLModel(contentsOf: url, configuration: config)
    let file = try AVAudioFile(forReading: audio)
    guard file.processingFormat.sampleRate == 16000, file.processingFormat.channelCount == 1 else {
        throw NSError(domain: "Overlap probe needs 16 kHz mono", code: 3)
    }
    let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096)!
    let window = 160000
    var result: [Overlap] = []
    while file.framePosition < file.length {
        let offset = Double(file.framePosition) / 16000
        let input = try MLMultiArray(shape: [1, 1, NSNumber(value: window)], dataType: .float32)
        let ptr = input.dataPointer.assumingMemoryBound(to: Float.self)
        ptr.initialize(repeating: 0, count: window)
        var count = 0
        while count < window, file.framePosition < file.length {
            try file.read(into: buffer, frameCount: AVAudioFrameCount(min(4096, window - count)))
            guard buffer.frameLength > 0 else { break }
            ptr.advanced(by: count)
                .update(
                    from: buffer.floatChannelData![0], count: Int(buffer.frameLength))
            count += Int(buffer.frameLength)
        }
        let output = try model.prediction(
            from: MLDictionaryFeatureProvider(dictionary: [
                "audio": MLFeatureValue(multiArray: input)
            ]))
        guard
            let values =
                (output.featureValue(for: "segments") ?? output.featureValue(for: "log_probs"))?
                .multiArrayValue
        else { throw NSError(domain: "Unknown pinned segmentation output", code: 4) }
        let shape = values.shape.map(\.intValue)
        guard shape.count == 3, shape[0] == 1, (7...8).contains(shape[2]) else {
            throw NSError(domain: "Unknown pinned powerset shape", code: 4)
        }
        let frames = shape[1]
        let classes = shape[2]
        let step = 10 / Double(frames)
        var start: Int? = nil
        for frame in 0...frames {
            var overlap = false
            if frame < frames, Double(frame) * step < Double(count) / 16000 {
                let logits = (0..<classes)
                    .map {
                        values[[0, NSNumber(value: frame), NSNumber(value: $0)]].doubleValue
                    }
                if let winner = logits.indices.max(by: { logits[$0] < logits[$1] }) {
                    overlap = winner >= 4
                }
            }
            if overlap && start == nil { start = frame }
            if !overlap, let first = start {
                if frame - first >= 3 {
                    result.append(
                        Overlap(
                            start: offset + Double(first) * step,
                            end: min(
                                offset + Double(frame) * step, Double(file.framePosition) / 16000)))
                }
                start = nil
            }
        }
    }
    return result
}
@main struct Worker {
    static func main() async {
        do {
            let args = CommandLine.arguments
            guard args.count >= 4 else {
                throw NSError(
                    domain: "Usage: SpeakerWorker audio output models-directory [--prepare]",
                    code: 1)
            }
            var config = OfflineDiarizerConfig.default
            config.exclusiveSegments = false
            let manager = OfflineDiarizerManager(config: config)
            let modelsURL = URL(fileURLWithPath: args[3])
            let start = Date()
            // Downloads are only authorized in the explicit setup command. Runtime must be offline.
            if !args.contains("--prepare") {
                let files = try FileManager.default.subpathsOfDirectory(atPath: modelsURL.path)
                    .map {
                        $0.lowercased()
                    }
                guard files.contains(where: { $0.contains("embedding") }),
                    files.contains(where: { $0.contains("segmentation") }),
                    files.contains(where: { $0.contains("plda") })
                else { throw NSError(domain: "Install Community-1 models first", code: 2) }
            }
            try await manager.prepareModels(directory: modelsURL)
            let result = try await manager.process(URL(fileURLWithPath: args[1]))
            let overlaps = try overlapHints(audio: URL(fileURLWithPath: args[1]), models: modelsURL)
            let output = Result(
                overlaps: overlaps,
                turns: result.segments.map {
                    Turn(
                        speaker: $0.speakerId, start: Double($0.startTimeSeconds),
                        end: Double($0.endTimeSeconds))
                }, embeddings: result.speakerDatabase ?? [:],
                elapsed: Date().timeIntervalSince(start),
                model: "Community-1 / FluidAudio fc8c3e4")
            try JSONEncoder().encode(output)
                .write(to: URL(fileURLWithPath: args[2]), options: .atomic)
        } catch {
            fputs("\(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
}
