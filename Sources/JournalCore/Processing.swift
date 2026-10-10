import Foundation

public struct ModelChoice: Identifiable {public let id:String;public let name:String;public let filename:String;public let revision:String;public let checksum:String;public let languages:String}
public enum Models {
    public static let all:[ModelChoice] = [ModelChoice(id:"unified",name:"Parakeet Unified EN 0.6B",filename:"parakeet-unified-en-0.6b-Q8_0.gguf",revision:"7e948f21b7bdbac698d3318db9d350f1096f3b6c",checksum:"4b50b6dd862bf6e346929aaf4f5eaacec003bfa3f56462d6c874b41ef2f38795",languages:"English · Q8_0 · 697 MiB"),ModelChoice(id:"whisper",name:"Whisper Medium",filename:"whisper-medium-Q4_K_M.gguf",revision:"ec78f06fded51aa82cde751678b78f76f78c8b7f",checksum:"6c9cad9c41d1fa0fcc624898f7ee3485b66127627878081a5655c6f6f3ce20ab",languages:"Multilingual · Mandarin / Japanese · Q4_K_M")]
}
public struct SpeakerTurn:Codable {public let speaker:String;public let start:Double;public let end:Double}
public struct SpeakerResult:Codable {public let turns:[SpeakerTurn];public let embeddings:[String:[Float]];public let elapsed:Double;public let model:String}
public struct ASRRow:Decodable {public let text:String;public let streaming_text:String?;public let language:String?;public let segments:[ASRSegment]?;public let error:String?}
public struct ASRSegment:Decodable {public let t0_ms:Int;public let t1_ms:Int;public let text:String}

/// One serial worker lane. ML in separate, network-denied processes, with timeouts.
public final class Processor: @unchecked Sendable {
    public let store:Store;public let project:URL
    private let lane=DispatchQueue(label:"stillpoint.processing",qos:.utility)
    private let state=NSLock();private var scheduled=false
    public var onStatus:((String)->Void)?;public var onChange:(()->Void)?
    public init(store:Store,project:URL) throws {self.store=store;self.project=project;try store.exec("CREATE TABLE IF NOT EXISTS speaker_vectors(session TEXT,label TEXT,embedding TEXT,PRIMARY KEY(session,label))")}
    public func schedule() {state.lock();guard !scheduled else {state.unlock();return};scheduled=true;state.unlock();lane.async {self.drain();self.state.lock();self.scheduled=false;self.state.unlock();if ((try? self.store.chunks(status:"queued",limit:1).isEmpty == false) ?? false) {self.schedule()}}}
    public func maintenance() {lane.async {do {try self.store.cleanup(cap:Int(self.store.setting("cap",fallback:"500000000")) ?? 500000000);self.onChange?()}catch{self.onStatus?(error.localizedDescription)}}}
    public func waitUntilIdle() {lane.sync{}}
    public func retry() throws {try store.exec("UPDATE chunks SET status='queued',error='' WHERE status IN ('failed','needs_speakers')");schedule()}
    private func drain() {
        do {
            while let chunk=try store.chunks(status:"queued",limit:1).first {
                guard store.audioAvailable(chunk) else {try store.exec("UPDATE chunks SET status='expired' WHERE id=?",[chunk.id]);continue}
                do {try process(chunk)} catch {try store.exec("UPDATE chunks SET status='failed',error=? WHERE id=?",[error.localizedDescription,chunk.id]);onStatus?("Needs attention: \(error.localizedDescription)")}
                onChange?()
            }
        }catch {onStatus?(error.localizedDescription)}
        onStatus?("Idle · audio stays on this Mac")
    }
    private func process(_ original:Chunk) throws {
        try store.exec("UPDATE chunks SET status='processing' WHERE id=?",[original.id]);onStatus?("Compressing · recording continues independently")
        try Archive.compress(original,store:store)
        guard let chunk=try store.chunks().first(where:{$0.id==original.id}) else {return}
        let source=try Archive.decompress(chunk,store:store);let wav=store.root.appendingPathComponent("derived/\(chunk.id).wav");let list=store.root.appendingPathComponent("derived/\(chunk.id).list");let log=store.root.appendingPathComponent("derived/\(chunk.id).asr.log");let diarized=store.root.appendingPathComponent("derived/\(chunk.id).speakers.json")
        defer {for url in [wav,list,log,diarized,source] where url.path.contains("/derived/"){try? FileManager.default.removeItem(at:url)}}
        let rms=try Archive.rms(source)
        // Conservative energy gate skips only near digital silence, never deletes captured audio.
        guard rms>0.0001 else {try store.exec("UPDATE chunks SET status='silence' WHERE id=?",[chunk.id]);return}
        try Archive.wav(source,to:wav)
        guard let model=Models.all.first(where:{$0.id==chunk.model}) else {throw JournalError("Unknown model selection")}
        let modelURL=project.appendingPathComponent("Models/"+model.filename)
        guard FileManager.default.fileExists(atPath:modelURL.path) else {throw JournalError("Install \(model.name) in Models, then Retry")}
        let isEnrollment=store.setting("enrollment-session")==chunk.session
        var asr:ASRRow?=nil
        let existing=try store.segments(session:chunk.session).filter{$0.chunk==chunk.id}
        if !existing.isEmpty {
            asr=ASRRow(text:existing.map(\.raw).joined(separator:" "),streaming_text:nil,language:nil,segments:existing.map{ASRSegment(t0_ms:Int(($0.offset-chunk.offset)*1000),t1_ms:Int(($0.end-chunk.offset)*1000),text:$0.raw)},error:nil)
        }
        if !isEnrollment && asr==nil {
            onStatus?("Transcribing · \(model.name)")
            let executable=project.appendingPathComponent("bin/ASRWorker")
            let resultURL=store.root.appendingPathComponent("derived/\(chunk.id).asr.json")
            defer {try? FileManager.default.removeItem(at:resultURL)}
            try LocalProcess.run("/usr/bin/sandbox-exec",["-p","(version 1)(allow default)(deny network*)",executable.path,modelURL.path,wav.path,resultURL.path],log:log,timeout:180)
            asr=try JSONDecoder().decode(ASRRow.self,from:Data(contentsOf:resultURL));if let error=asr?.error {throw JournalError("ASR: "+error)}
        }
        onStatus?("Finding speakers · Community-1")
        let speakerWorker=project.appendingPathComponent(".build/debug/SpeakerWorker")
        let models=project.appendingPathComponent("Models/Community1")
        var speakers:SpeakerResult?
        do {
            try LocalProcess.run("/usr/bin/sandbox-exec",["-p","(version 1)(allow default)(deny network*)",speakerWorker.path,wav.path,diarized.path,models.path],log:log,timeout:180)
            speakers=try JSONDecoder().decode(SpeakerResult.self,from:Data(contentsOf:diarized))
            try store.exec("UPDATE sessions SET note='' WHERE id=? AND note LIKE 'Speaker analysis unavailable:%'",[chunk.session])
        }catch {
            if isEnrollment {throw error}
            if error.localizedDescription.contains("No speech detected in audio") {
                speakers=SpeakerResult(turns:[],embeddings:[:],elapsed:0,model:"Community-1 · inconclusive")
                try store.exec("UPDATE sessions SET note=? WHERE id=?",["Speaker detection was inconclusive on a short/quiet chunk. Its ASR text is preserved with Unknown labels.",chunk.session])
            } else {try store.exec("UPDATE sessions SET note=? WHERE id=?",["Speaker analysis unavailable: \(error.localizedDescription). Labels remain Unknown.",chunk.session])}
        }
        if isEnrollment {
            guard chunk.duration>=8,let speakers,speakers.embeddings.count==1,let embedding=speakers.embeddings.values.first,!embedding.isEmpty else {throw JournalError("Enrollment needs one clear voice. Please retry alone in a quiet room.")}
            let encoded=String(data:try JSONEncoder().encode(embedding),encoding:.utf8)!
            try store.exec("INSERT OR REPLACE INTO profiles VALUES('Me',?,'Community1/fc8c3e4',?)",[encoded,Date().timeIntervalSince1970])
            try store.exec("UPDATE chunks SET status='done' WHERE id=?",[chunk.id]);return
        }
        let labels=try mapSpeakers(speakers?.embeddings ?? [:],session:chunk.session)
        let rulesData=Data(store.setting("rules-"+chunk.session,fallback:store.setting("rules",fallback:"[]")).utf8);let rules=(try? JSONDecoder().decode([Replacement].self,from:rulesData)) ?? []
        guard let asr else {throw JournalError("ASR unavailable")}
        let rows=asr.segments?.isEmpty==false ? asr.segments! : [ASRSegment(t0_ms:0,t1_ms:Int(chunk.duration*1000),text:asr.text)]
        try store.transaction {
            if existing.isEmpty {try store.exec("INSERT OR REPLACE INTO asr_runs VALUES(?,?,?,?)",[chunk.id,asr.streaming_text ?? "",asr.text,asr.language ?? "uncertain"])}
            var grouped:[(start:Double,end:Double,text:String,label:String,language:String)] = []
            for row in rows {
                let start=Double(row.t0_ms)/1000,end=Double(row.t1_ms)/1000
                let turns=speakers?.turns.filter {min(end,$0.end)>max(start,$0.start)} ?? []
                let ranked=turns.sorted {min(end,$0.end)-max(start,$0.start)>min(end,$1.end)-max(start,$1.start)}
                var label="Unknown"
                if let turn=ranked.first {
                    let duration=max(0.01,end-start);let fraction=(min(end,turn.end)-max(start,turn.start))/duration
                    if fraction>=0.7 {label=labels[turn.speaker] ?? "Unknown"}
                    else if ranked.count>1 {label="Unknown · mixed speakers"}
                }
                let language=Self.language(row.text,model:chunk.model)
                if let last=grouped.last,last.label==label,last.language==language,end-last.start<8,start-last.end<1 {
                    let index=grouped.count-1;grouped[index].end=max(end,last.end);grouped[index].text += row.text.hasPrefix(" ") ? row.text : " "+row.text
                } else {grouped.append((start,max(start,end),row.text,label,language))}
            }
            for row in grouped where existing.isEmpty {
                try store.insertSegment(session:chunk.session,offset:chunk.offset+row.start,end:chunk.offset+row.end,raw:row.text,corrected:DictionaryCorrection.apply(row.text,rules:rules),speaker:row.label,language:row.language,chunk:chunk.id)
            }
            if !existing.isEmpty {
                for old in existing where old.speaker.hasPrefix("Unknown") {
                    let start=old.offset-chunk.offset,end=old.end-chunk.offset
                    let turns=speakers?.turns.filter{min(end,$0.end)>max(start,$0.start)} ?? []
                    if let best=turns.max(by:{min(end,$0.end)-max(start,$0.start)<min(end,$1.end)-max(start,$1.start)}),(min(end,best.end)-max(start,best.start))/max(0.01,end-start)>=0.7,let label=labels[best.speaker] {try store.exec("UPDATE segments SET speaker=? WHERE id=?",[label,old.id])}
                }
            }
            try store.exec("UPDATE chunks SET status=?,error=? WHERE id=?",[speakers==nil ? "needs_speakers":"done",speakers==nil ? "Speaker analysis unavailable. Retry preserves transcript corrections.":"",chunk.id])
        }
    }
    private func mapSpeakers(_ embeddings:[String:[Float]],session:String) throws -> [String:String] {
        let profile: [Float]? = try store.exec("SELECT embedding FROM profiles WHERE id='Me' AND model='Community1/fc8c3e4'").first.flatMap {$0["embedding"]}.flatMap{try? JSONDecoder().decode([Float].self,from:Data($0.utf8))}
        var saved=try store.exec("SELECT label,embedding FROM speaker_vectors WHERE session=?",[session]).compactMap {row -> (String,[Float])? in guard let label=row["label"],let value=row["embedding"],let vector=try? JSONDecoder().decode([Float].self,from:Data(value.utf8)) else {return nil};return (label,vector)}
        var result:[String:String]=[:]
        for (id,vector) in embeddings.sorted(by:{$0.key<$1.key}) {
            let me=profile.map{VoiceMatch.cosine(vector,$0)} ?? -1
            let otherMe=embeddings.filter{$0.key != id}.map{entry in profile.map{VoiceMatch.cosine(entry.value,$0)} ?? -1}.max() ?? -1
            var label=VoiceMatch.label(score:me,runnerUp:otherMe)
            if label != "Me" {
                let scores=saved.map{($0.0,VoiceMatch.cosine(vector,$0.1))}.sorted{$0.1>$1.1}
                if let best=scores.first,best.1>=0.75,best.1-(scores.dropFirst().first?.1 ?? -1)>=0.12 {label=best.0}
                else if (scores.first?.1 ?? -1)<0.6 {label="Speaker \(saved.count+2)";saved.append((label,vector));let json=String(data:try JSONEncoder().encode(vector),encoding:.utf8)!;try store.exec("INSERT OR REPLACE INTO speaker_vectors VALUES(?,?,?)",[session,label,json])}
            }
            result[id]=label
        }
        return result
    }
    public static func language(_ text:String,model:String)->String {
        let hasKana=text.unicodeScalars.contains{(0x3040...0x30ff).contains($0.value)}
        let hasHan=text.unicodeScalars.contains{(0x4e00...0x9fff).contains($0.value)}
        let hasLatin=text.unicodeScalars.contains{(65...90).contains($0.value)||(97...122).contains($0.value)}
        if (hasKana || hasHan) && hasLatin {return "mixed / uncertain"};if hasKana{return "ja · script estimate"};if hasHan{return "zh / ja uncertain"}
        return model=="unified" ? "en · model assumption" : "uncertain"
    }
}
// Future Stage 2 can implement this interface. No network implementation is shipped.
public protocol SessionExporter {func export(sessionID:String,store:Store) async throws}
