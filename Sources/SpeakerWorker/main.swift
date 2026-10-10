import Foundation
import FluidAudio
import CoreML
struct Turn:Codable {let speaker:String;let start:Double;let end:Double}
struct Result:Codable {let turns:[Turn];let embeddings:[String:[Float]];let elapsed:Double;let model:String}
@main struct Worker {
    static func main() async {
        do {
            let args=CommandLine.arguments;guard args.count>=4 else {throw NSError(domain:"Usage: SpeakerWorker audio output models-directory [--prepare]",code:1)}
            let manager=OfflineDiarizerManager();let modelsURL=URL(fileURLWithPath:args[3]);let start=Date()
            // Downloads are only authorized in the explicit setup command. Runtime must be offline.
            if !args.contains("--prepare") {
                let files=try FileManager.default.subpathsOfDirectory(atPath:modelsURL.path).map{$0.lowercased()}
                guard files.contains(where:{$0.contains("embedding")}),files.contains(where:{$0.contains("segmentation")}),files.contains(where:{$0.contains("plda")}) else {throw NSError(domain:"Install Community-1 models first",code:2)}
            }
            try await manager.prepareModels(directory:modelsURL)
            let result=try await manager.process(URL(fileURLWithPath:args[1]))
            let output=Result(turns:result.segments.map{Turn(speaker:$0.speakerId,start:Double($0.startTimeSeconds),end:Double($0.endTimeSeconds))},embeddings:result.speakerDatabase ?? [:],elapsed:Date().timeIntervalSince(start),model:"Community-1 / FluidAudio fc8c3e4")
            try JSONEncoder().encode(output).write(to:URL(fileURLWithPath:args[2]),options:.atomic)
        } catch {fputs("\(error.localizedDescription)\n",stderr);exit(1)}
    }
}
