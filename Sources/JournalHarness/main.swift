import Foundation
import JournalCore
import AVFoundation
let args=CommandLine.arguments
func measure(_ label:String,_ body:() throws -> Void) rethrows {let start=Date();try body();print("\(label): \(String(format:"%.6f",Date().timeIntervalSince(start))) s")}
do {
    guard args.count>=3 else{throw JournalError("Usage: JournalHarness import|process|recover|stress|crash data-root [fixture] [project]")}
    let store=try Store(root:URL(fileURLWithPath:args[2]))
    switch args[1] {
    case "import":
        let id=try store.createSession(title:"Synthetic fixture",device:"synthetic",model:"unified")
        try measure("capture/write"){let writer=ChunkWriter(store:store,session:id,model:"unified");try writer.importFile(URL(fileURLWithPath:args[3]));try store.finish(id)}
        for chunk in try store.chunks(session:id) {try measure("compression"){try Archive.compress(chunk,store:store)}}
    case "process":
        let processor=try Processor(store:store,project:URL(fileURLWithPath:args[3]));processor.onStatus={print($0)};try processor.retry();measure("processing"){processor.waitUntilIdle()};print(try store.segments().map(\.raw).joined(separator:"\n"))
    case "audit":
        for chunk in try store.chunks() {var url:URL!;try measure("decompression"){url=try Archive.decompress(chunk,store:store)};try measure("VAD/RMS"){print("rms=\(try Archive.rms(url))")};let wav=store.root.appendingPathComponent("derived/audit.wav");try measure("resample"){try Archive.wav(url,to:wav)};try? FileManager.default.removeItem(at:wav);if url.path.contains("/derived/"){try? FileManager.default.removeItem(at:url)}}
    case "recover":try measure("recovery"){try Archive.recover(store)};print(try store.chunks().map{($0.status,$0.duration)})
    case "crash":
        let id=try store.createSession(title:"Injected crash",device:"synthetic",model:"unified");let writer=ChunkWriter(store:store,session:id,model:"unified");let file=try AVAudioFile(forReading:URL(fileURLWithPath:args[3]));let buffer=AVAudioPCMBuffer(pcmFormat:file.processingFormat,frameCapacity:4096)!
        for _ in 0..<55 {try file.read(into:buffer);if buffer.frameLength==0{file.framePosition=0;continue};try writer.write(buffer)}
        print("Crash after buffers while final CAF remains open");fflush(stdout);kill(getpid(),SIGKILL)
    case "stress":
        try measure("insert 10000 segments"){let id=try store.createSession(title:"Stress",device:"synthetic",model:"unified");try store.transaction{for i in 0..<10000{try store.insertSegment(session:id,offset:Double(i),end:Double(i+1),raw:"Meeting boundary Kyoto \(i)",corrected:"Meeting boundary Kyoto \(i)",speaker:i%2==0 ? "Me":"Speaker 2",language:"en",chunk:"")}};try store.finish(id)}
        try measure("search 100 queries"){for _ in 0..<100{_ = try store.segments(query:"Kyoto",speaker:"Me")}}
        try measure("retention / eviction"){_ = try store.cleanup(now:Date().timeIntervalSince1970+172801,cap:2000)}
        print("Remaining sessions: \(try store.sessions().count)")
    default:throw JournalError("Unknown command")
    }
}catch{fputs("\(error.localizedDescription)\n",stderr);exit(1)}
