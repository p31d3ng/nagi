import XCTest
import AVFoundation
@testable import JournalCore
final class JournalTests:XCTestCase {
    var root:URL!;var store:Store!
    override func setUpWithError() throws {root=FileManager.default.temporaryDirectory.appendingPathComponent("stillpoint-test-\(UUID())");store=try Store(root:root)}
    override func tearDownWithError() throws {store=nil;try? FileManager.default.removeItem(at:root)}
    func session(_ at:Double=Date().timeIntervalSince1970) throws -> String {try store.createSession(title:"Synthetic",device:"fixture",model:"unified",at:at)}
    func testFailureLogTailIsBounded() throws {
        let log=root.appendingPathComponent("large-worker.log")
        try Data((String(repeating:"x",count:2_000_000)+"tail-marker").utf8).write(to:log)
        let tail=LocalProcess.logTail(log)
        XCTAssertEqual(tail.utf8.count,4096);XCTAssertTrue(tail.hasSuffix("tail-marker"))
        XCTAssertEqual(LocalProcess.logTail(log,bytes:0),"")
    }
    func testSpeakerCatalogIsBoundedAndKnownIdentitiesRemainMatchable() throws {
        let id=try session(),processor=try Processor(store:store,project:root)
        func vector(_ index:Int)->[Float] {var v=[Float](repeating:0,count:256);v[index]=1;return v}
        for i in 0..<130 {_ = try processor.mapSpeakers(["speaker":vector(i)],session:id)}
        XCTAssertEqual(try store.exec("SELECT count(*) AS n FROM speaker_vectors").first?["n"],"128")
        XCTAssertEqual(try processor.mapSpeakers(["speaker":vector(130)],session:id)["speaker"],"Unknown")
        XCTAssertEqual(try processor.mapSpeakers(["speaker":vector(0)],session:id)["speaker"],"Speaker 2")
    }
    func testTimelineResultBoundWithGrowingDatabase() throws {
        let id=try session()
        try store.transaction {for i in 0..<10000 {try store.insertSegment(session:id,offset:Double(i),end:Double(i+1),raw:"Synthetic capacity \(i)",corrected:"Synthetic capacity \(i)",speaker:"Speaker 2",language:"en",chunk:"")}}
        XCTAssertEqual(try store.segments(session:id).count,2000)
        XCTAssertEqual(try store.segments(query:"capacity").count,2000)
        XCTAssertEqual(try store.segments(session:id).last?.offset,1999)
    }
    func testFTSSpeakerLanguageAndQuotes() throws {let id=try session();try store.insertSegment(session:id,offset:4,end:8,raw:"Meet Kyoto",corrected:"Meet Kyoto",speaker:"Me",language:"en",chunk:"");XCTAssertEqual(try store.segments(query:"Kyoto",speaker:"Me",language:"en").first?.offset,4);XCTAssertTrue(try store.segments(query:"Kyoto",speaker:"Speaker 2").isEmpty);XCTAssertNoThrow(try store.segments(query:"\" OR *"))}
    func testCorrectionHistoryRawAndUndo() throws {let id=try session();try store.insertSegment(session:id,offset:0,end:1,raw:"SQ Lite",corrected:"SQLite",speaker:"Unknown",language:"en",chunk:"");let s=try XCTUnwrap(store.segments().first);try store.edit(s.id,text:"SQLite 3",speaker:"Me");try store.undo(s.id);XCTAssertEqual(try store.segments().first?.corrected,"SQLite");XCTAssertEqual(try store.segments().first?.raw,"SQ Lite");try store.undo(s.id);XCTAssertEqual(try store.segments().first?.corrected,"SQ Lite")}
    func testCJKSubstringSearch() throws {let id=try session();try store.insertSegment(session:id,offset:5,end:9,raw:"今日は会議の計画を話します",corrected:"今日は会議の計画を話します",speaker:"Unknown",language:"ja",chunk:"");XCTAssertEqual(try store.segments(query:"会議").first?.offset,5)}
    func testAlreadyExpiredQueueStillDeletesAudio() throws {let id=try session(1);let c=try store.registerChunk(session:id,path:"audio/expired.caf",captured:1,offset:0,model:"unified");try Data([1]).write(to:root.appendingPathComponent("audio/expired.caf"));try store.exec("UPDATE chunks SET status='expired' WHERE id=?",[c]);XCTAssertEqual(try store.cleanup(now:172802),1);XCTAssertTrue(FileManager.default.fileExists(atPath:root.path));XCTAssertEqual(try store.cleanup(now:172802),0)}
    func testExactRules() {XCTAssertEqual(DictionaryCorrection.apply("SQ Lite and SQ Lite",rules:[Replacement(from:"SQ Lite",to:"SQLite")]),"SQLite and SQLite");XCTAssertEqual(DictionaryCorrection.apply("original",rules:[Replacement(from:"",to:"bad")]),"original")}
    func testExpiryBoundaryAndDerived() throws {let id=try session(100);let c=try store.registerChunk(session:id,path:"audio/x.caf",captured:100,offset:0,model:"unified");try Data([1,2]).write(to:root.appendingPathComponent("audio/x.caf"));try Data([1]).write(to:root.appendingPathComponent("derived/temp.wav"));try store.seal(c,duration:2);let chunk=try XCTUnwrap(store.chunks().first);XCTAssertTrue(store.audioAvailable(chunk,now:172899));XCTAssertFalse(store.audioAvailable(chunk,now:172900));XCTAssertEqual(try store.cleanup(now:172900),1);XCTAssertFalse(FileManager.default.fileExists(atPath:root.appendingPathComponent("derived/temp.wav").path));XCTAssertEqual(try store.sessions().count,1)}
    func testTranscriptCapacityEvictsWholeOldestSession() throws {let a=try session(1),b=try session(2);for id in [a,b]{try store.finish(id);try store.insertSegment(session:id,offset:0,end:1,raw:String(repeating:"a",count:100),corrected:String(repeating:"a",count:100),speaker:"Me",language:"en",chunk:"")};_ = try store.cleanup(now:3,cap:250);XCTAssertEqual(try store.sessions().map(\.id),[b]);XCTAssertEqual(try store.segments().count,1)}
    func testActiveRecordingNotEvicted() throws {let id=try session();try store.insertSegment(session:id,offset:0,end:1,raw:String(repeating:"x",count:1000),corrected:"x",speaker:"Me",language:"en",chunk:"");_ = try store.cleanup(cap:1);XCTAssertEqual(try store.sessions().first?.id,id)}
    func testDisabledCapacity() throws {let id=try session();try store.insertSegment(session:id,offset:0,end:1,raw:String(repeating:"x",count:10000),corrected:"x",speaker:"Me",language:"en",chunk:"");_ = try store.cleanup(cap:0);XCTAssertEqual(try store.sessions().count,1)}
    func testRollback() throws {let id=try session();XCTAssertThrowsError(try store.transaction{try store.finish(id);throw JournalError("injected")});XCTAssertEqual(try store.sessions().first?.status,"recording")}
    func testInterruptedQueueRecovery() throws {let id=try session();let c=try store.registerChunk(session:id,path:"audio/x",captured:Date().timeIntervalSince1970,offset:0,model:"unified");try store.seal(c,duration:2);try store.exec("UPDATE chunks SET status='processing'");try store.recover();XCTAssertEqual(try store.chunks().first?.status,"queued");XCTAssertEqual(try store.sessions().first?.status,"interrupted")}
    func testVoiceUncertainty() {XCTAssertEqual(VoiceMatch.cosine([1,0],[1,0]),1);XCTAssertEqual(VoiceMatch.cosine([0,0],[1,0]),-1);XCTAssertEqual(VoiceMatch.label(score:0.9,runnerUp:0.85),"Unknown");XCTAssertEqual(VoiceMatch.label(score:0.9,runnerUp:0.5),"Me");XCTAssertEqual(VoiceMatch.label(score:0.6,runnerUp:0.1),"Unknown")}
    func testLanguageUncertainty(){XCTAssertEqual(Processor.language("计划",model:"whisper"),"zh / ja uncertain");XCTAssertEqual(Processor.language("こんにちは",model:"whisper"),"ja · script estimate");XCTAssertEqual(Processor.language("Hello 计划",model:"whisper"),"mixed / uncertain")}
    func testOriginalRateChannelsAndLosslessRoundTrip() throws {
        let id=try session(),format=AVAudioFormat(standardFormatWithSampleRate:48000,channels:2)!;let buffer=AVAudioPCMBuffer(pcmFormat:format,frameCapacity:48000)!;buffer.frameLength=48000
        for channel in 0..<2{for i in 0..<48000{buffer.floatChannelData![channel][i]=Float(sin(Double(i)*0.05))*Float(channel+1)*0.1}}
        let writer=ChunkWriter(store:store,session:id,model:"unified");try writer.write(buffer);try writer.finish();let c=try XCTUnwrap(store.chunks().first);let original=try Data(contentsOf:root.appendingPathComponent(c.path));try Archive.compress(c,store:store);let zipped=try XCTUnwrap(store.chunks().first);let restored=try Archive.decompress(zipped,store:store);XCTAssertEqual(try Data(contentsOf:restored),original);let f=try AVAudioFile(forReading:restored);XCTAssertEqual(f.processingFormat.sampleRate,48000);XCTAssertEqual(f.processingFormat.channelCount,2);XCTAssertEqual(f.length,48000)
    }
    func testMissingUIDNeverStartsAnotherDevice() throws {
        let id=try session();let writer=ChunkWriter(store:store,session:id,model:"unified")
        XCTAssertThrowsError(try Capture().start(device:InputDevice(id:"nagi-synthetic-impossible-uid",name:"Disconnected fixture",audioID:0),writer:writer))
        XCTAssertTrue(try store.chunks().isEmpty)
    }
    func testSilenceRMS() throws {let format=AVAudioFormat(standardFormatWithSampleRate:44100,channels:1)!;let b=AVAudioPCMBuffer(pcmFormat:format,frameCapacity:4410)!;b.frameLength=4410;let url=root.appendingPathComponent("silence.caf");var f:AVAudioFile?=try AVAudioFile(forWriting:url,settings:format.settings);try f?.write(from:b);f=nil;XCTAssertEqual(try Archive.rms(url),0)}
    func testDeleteExpiredSessionCannotDeleteDataRoot() throws {
        let old=try session(1),live=try session(2);let c=try store.registerChunk(session:old,path:"audio/old.caf",captured:1,offset:0,model:"unified")
        try Data([1]).write(to:root.appendingPathComponent("audio/old.caf"));try store.seal(c,duration:1);_ = try store.cleanup(now:172802,cap:0);try store.deleteSession(old)
        XCTAssertTrue(FileManager.default.fileExists(atPath:root.appendingPathComponent("journal.sqlite").path));XCTAssertEqual(try store.sessions().map(\.id),[live])
    }
    func testRetentionKeepsLiveDerivativesDeletesExpiredUnprocessedAndHistoryCap() throws {
        let old=try session(1),live=try session(172802)
        let a=try store.registerChunk(session:old,path:"audio/old.caf",captured:1,offset:0,model:"unified"),b=try store.registerChunk(session:live,path:"audio/live.caf",captured:172802,offset:0,model:"unified")
        for (id,name) in [(a,"old"),(b,"live")] {try Data([1]).write(to:root.appendingPathComponent("audio/\(name).caf"));try Data([1]).write(to:root.appendingPathComponent("derived/\(id).context.wav"))}
        _ = try store.cleanup(now:172802,cap:0)
        XCTAssertEqual(try store.chunk(a)?.status,"expired");XCTAssertFalse(FileManager.default.fileExists(atPath:root.appendingPathComponent("derived/\(a).context.wav").path));XCTAssertTrue(FileManager.default.fileExists(atPath:root.appendingPathComponent("derived/\(b).context.wav").path))
        try store.deleteSession(live);XCTAssertFalse(FileManager.default.fileExists(atPath:root.appendingPathComponent("derived/\(b).context.wav").path))
    }
    func testHistoryAndASRRawCountTowardCapacity() throws {
        let id=try session(),c=try store.registerChunk(session:id,path:"",captured:1,offset:0,model:"unified");try store.finish(id)
        try store.insertSegment(session:id,offset:0,end:1,raw:"x",corrected:"x",speaker:"Unknown",language:"en",chunk:c)
        try store.exec("INSERT INTO asr_runs VALUES(?,?,?,?)",[c,String(repeating:"z",count:100),"","en"])
        _ = try store.cleanup(now:2,cap:50);XCTAssertTrue(try store.sessions().isEmpty);XCTAssertTrue(FileManager.default.fileExists(atPath:root.path))
    }
    func testAmbiguousOverlapNeverAssignedMe() {
        let turns=[SpeakerTurn(speaker:"a",start:0,end:2),SpeakerTurn(speaker:"b",start:0.2,end:0.5)]
        XCTAssertEqual(SpeakerAttribution.label(start:0,end:2,turns:turns,labels:["a":"Me","b":"Speaker 2"]),"Unknown · overlapping speakers")
        XCTAssertEqual(SpeakerAttribution.label(start:0.6,end:1,turns:turns,labels:["a":"Me"]),"Me")
        XCTAssertTrue(SpeakerAttribution.hasOverlap(turns))
        XCTAssertEqual(SpeakerAttribution.label(start:0,end:2,turns:[SpeakerTurn(speaker:"a",start:0,end:1.5),SpeakerTurn(speaker:"b",start:1.5,end:2)],labels:["a":"Me","b":"Speaker 2"]),"Unknown · mixed speakers")
        XCTAssertEqual(SpeakerAttribution.label(start:0,end:1,turns:[turns[0]],labels:["a":"Me"],overlaps:[OverlapSpan(start:0.2,end:0.5)]),"Unknown · possible overlap")
    }
    func testTimestampOwnershipPreservesRepeatsAndClipsBoundary() {
        let rows=[ASRSegment(t0_ms:0,t1_ms:500,text:"prior"),ASRSegment(t0_ms:500,t1_ms:1000,text:"boundary"),ASRSegment(t0_ms:1100,t1_ms:1200,text:"go"),ASRSegment(t0_ms:1300,t1_ms:1400,text:"go"),ASRSegment(t0_ms:10800,t1_ms:11000,text:"next")]
        let owned=Processor.ownedRows(rows,lead:0.75,duration:10)
        XCTAssertEqual(owned.map(\.text),["boundary","go","go"]);XCTAssertEqual(owned.first?.t0_ms,0)
    }
    func testExactChunkFramesAndContinuity() throws {
        let id=try session(),format=AVAudioFormat(standardFormatWithSampleRate:16000,channels:1)!,writer=ChunkWriter(store:store,session:id,model:"unified")
        var expected:[Float]=[]
        for block in 0..<80 {let b=AVAudioPCMBuffer(pcmFormat:format,frameCapacity:4096)!;b.frameLength=4096;for i in 0..<4096 {let v=Float((block*4096+i)%997)/997;b.floatChannelData![0][i]=v;expected.append(v)};try writer.write(b)}
        try writer.finish();let chunks=try store.chunks(session:id);XCTAssertEqual(chunks.count,3);XCTAssertEqual(chunks[0].duration,10);XCTAssertEqual(chunks[1].offset,10)
        var actual:[Float]=[]
        for c in chunks {let f=try AVAudioFile(forReading:root.appendingPathComponent(c.path)),b=AVAudioPCMBuffer(pcmFormat:f.processingFormat,frameCapacity:4096)!;while f.framePosition<f.length {try f.read(into:b);actual.append(contentsOf:UnsafeBufferPointer(start:b.floatChannelData![0],count:Int(b.frameLength)))}}

        XCTAssertEqual(actual.count,expected.count);let mismatch=zip(actual,expected).enumerated().first{$0.element.0 != $0.element.1};XCTAssertNil(mismatch.map{"index=\($0.offset) actual=\($0.element.0) expected=\($0.element.1)"})
    }
    func testBackpressureStopsOnceAndDoesNotGrowQueue() throws {
        let id=try session(),format=AVAudioFormat(standardFormatWithSampleRate:16000,channels:1)!,b=AVAudioPCMBuffer(pcmFormat:format,frameCapacity:16)!,writer=ChunkWriter(store:store,session:id,model:"unified")
        b.frameLength=16;let entered=DispatchSemaphore(value:0),release=DispatchSemaphore(value:0);var errors=0
        writer.onLevel={_ in entered.signal();release.wait()};writer.onError={_ in errors+=1}
        XCTAssertTrue(writer.enqueue(b));XCTAssertEqual(entered.wait(timeout:.now()+2),.success)
        var accepted=1;for _ in 0..<100 {if writer.enqueue(b){accepted+=1}}
        XCTAssertEqual(accepted,64);XCTAssertEqual(errors,1);writer.onLevel=nil;release.signal();try writer.finish()
        XCTAssertEqual(try store.chunks().reduce(0.0){$0+$1.duration},Double(64*16)/16000,accuracy:0.000001)
    }

    func testIndependentDecompressionConsumers() throws {
        let id=try session(),format=AVAudioFormat(standardFormatWithSampleRate:16000,channels:1)!,b=AVAudioPCMBuffer(pcmFormat:format,frameCapacity:1600)!,writer=ChunkWriter(store:store,session:id,model:"unified");b.frameLength=1600;try writer.write(b);try writer.finish()
        try Archive.compress(try XCTUnwrap(store.chunks().first),store:store);let chunk=try XCTUnwrap(store.chunks().first)
        let a=try Archive.decompress(chunk,store:store),bURL=try Archive.decompress(chunk,store:store);XCTAssertNotEqual(a,bURL);XCTAssertEqual(try Data(contentsOf:a),try Data(contentsOf:bURL));try FileManager.default.removeItem(at:a);XCTAssertTrue(FileManager.default.fileExists(atPath:bURL.path))
    }
    func testStartupRemovesCrashLeftSDKAudio() throws {
        let dir=root.appendingPathComponent("derived/orphan.work");try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true);try Data([1,2,3]).write(to:dir.appendingPathComponent("sdk.pcm"));try Archive.recover(store);XCTAssertFalse(FileManager.default.fileExists(atPath:dir.path))
    }
    func testActiveSessionAudioExpiryKeepsFreshTail() throws {
        let id=try session(1),old=try store.registerChunk(session:id,path:"audio/old.caf",captured:1,offset:0,model:"unified"),tail=try store.registerChunk(session:id,path:"audio/tail.caf",captured:172802,offset:10,model:"unified")
        try store.seal(old,duration:10);for name in ["old","tail"] {try Data([1]).write(to:root.appendingPathComponent("audio/\(name).caf"))}
        _ = try store.cleanup(now:172802,cap:1);XCTAssertEqual(try store.chunk(old)?.status,"expired");XCTAssertEqual(try store.chunk(tail)?.status,"writing");XCTAssertEqual(try store.sessions().first?.status,"recording");XCTAssertTrue(FileManager.default.fileExists(atPath:root.appendingPathComponent("audio/tail.caf").path))
    }
    func testExpiredQueueDoesNotRunMissingWorkers() throws {
        let id=try session(1),c=try store.registerChunk(session:id,path:"audio/old.caf",captured:1,offset:0,model:"unified");try Data([1]).write(to:root.appendingPathComponent("audio/old.caf"));try store.seal(c,duration:1);try store.finish(id)
        let processor=try Processor(store:store,project:root.appendingPathComponent("no-workers"));processor.schedule();processor.waitUntilIdle();XCTAssertEqual(try store.chunk(c)?.status,"expired");XCTAssertEqual(try store.chunk(c)?.path,"")
    }
    func testLookaheadWaitsUntilFinish() throws {
        let id=try session(),c=try store.registerChunk(session:id,path:"audio/x.caf",captured:Date().timeIntervalSince1970,offset:0,model:"unified");try Data([1]).write(to:root.appendingPathComponent("audio/x.caf"));try store.seal(c,duration:10)
        let processor=try Processor(store:store,project:root);processor.schedule();processor.waitUntilIdle();XCTAssertEqual(try store.chunk(c)?.status,"queued");try store.finish(id);processor.schedule();processor.waitUntilIdle();XCTAssertEqual(try store.chunk(c)?.status,"failed")
    }
    func testContextPreservesExactCentralAndNeighborFrameCounts() throws {
        let id=try session(),format=AVAudioFormat(standardFormatWithSampleRate:16000,channels:1)!,b=AVAudioPCMBuffer(pcmFormat:format,frameCapacity:4096)!,writer=ChunkWriter(store:store,session:id,model:"unified")
        b.frameLength=4096;for _ in 0..<120 {try writer.write(b)};try writer.finish();let chunks=try store.chunks();let central=root.appendingPathComponent("derived/central.wav"),context=root.appendingPathComponent("derived/context.wav")
        try Archive.wav(root.appendingPathComponent(chunks[1].path),to:central);XCTAssertEqual(try Archive.context(chunks[1],central:central,to:context,store:store),0.75);let f=try AVAudioFile(forReading:context);XCTAssertEqual(f.length,184000)
    }

    func testContextExpiresWithEarliestSource() throws {
        let id=try session(),c=try store.registerChunk(session:id,path:"audio/live.caf",captured:172802,offset:10,model:"unified"),context=root.appendingPathComponent("derived/\(c).context.wav")
        try Data([1]).write(to:root.appendingPathComponent("audio/live.caf"));try Data([1]).write(to:context);try FileManager.default.setAttributes([.modificationDate:Date(timeIntervalSince1970:1)],ofItemAtPath:context.path)
        _ = try store.cleanup(now:172802,cap:0);XCTAssertTrue(try XCTUnwrap(store.chunk(c)).path != "");XCTAssertFalse(FileManager.default.fileExists(atPath:context.path))
    }
    func testExpiryNotBlockedByProcessingLane() throws {
        let oldSession=try session(1),old=try store.registerChunk(session:oldSession,path:"audio/old.caf",captured:1,offset:0,model:"unified");try Data([1]).write(to:root.appendingPathComponent("audio/old.caf"))
        let live=try session(),c=try store.registerChunk(session:live,path:"audio/live.caf",captured:Date().timeIntervalSince1970,offset:0,model:"unified");try Data([1]).write(to:root.appendingPathComponent("audio/live.caf"));try store.seal(c,duration:1);try store.finish(live)
        let processor=try Processor(store:store,project:root),entered=DispatchSemaphore(value:0),release=DispatchSemaphore(value:0),cleaned=DispatchSemaphore(value:0)
        processor.onStatus={text in if text.hasPrefix("Compressing") {entered.signal();release.wait()}};processor.onChange={cleaned.signal()};processor.schedule();XCTAssertEqual(entered.wait(timeout:.now()+2),.success)
        // Insert expired data after drain's initial cleanup, while the processing lane is held.
        try store.exec("UPDATE chunks SET status='writing',path='audio/old.caf' WHERE id=?",[old]);try Data([1]).write(to:root.appendingPathComponent("audio/old.caf"))
        processor.maintenance();let result=cleaned.wait(timeout:.now()+2);release.signal();processor.waitUntilIdle();XCTAssertEqual(result,.success);XCTAssertEqual(try store.chunk(old)?.status,"expired");XCTAssertFalse(FileManager.default.fileExists(atPath:root.appendingPathComponent("audio/old.caf").path))
    }

    func testStreamingCanonicalRejectsOfflineBoundaryInsertionAndKeepsRepeats() {
        let aligned=[ASRSegment(t0_ms:0,t1_ms:100,text:"Get,"),ASRSegment(t0_ms:100,t1_ms:300,text:"Kyoto,"),ASRSegment(t0_ms:300,t1_ms:500,text:"go"),ASRSegment(t0_ms:500,t1_ms:700,text:"go")]
        let rows=Processor.streamingRows(aligned,text:"Kyoto, go go tomorrow.")
        XCTAssertEqual(rows.map(\.text),["Kyoto,","go","go","tomorrow."]);XCTAssertEqual(rows.first?.t0_ms,100);XCTAssertEqual(rows.count,4)
    }

    func testRightOnlyStereoSpeechDoesNotSkipVAD() throws {
        let id=try session(),format=AVAudioFormat(standardFormatWithSampleRate:48000,channels:2)!,b=AVAudioPCMBuffer(pcmFormat:format,frameCapacity:4800)!,writer=ChunkWriter(store:store,session:id,model:"unified");b.frameLength=4800
        for i in 0..<4800 {b.floatChannelData![0][i]=0;b.floatChannelData![1][i]=Float(sin(Double(i)*0.1))*0.1}
        var level=0.0;writer.onLevel={level=$0};try writer.write(b);try writer.finish();let chunk=try XCTUnwrap(store.chunks().first),source=root.appendingPathComponent(chunk.path),wav=root.appendingPathComponent("derived/right.wav")
        XCTAssertGreaterThan(level,0.01);XCTAssertGreaterThan(try Archive.rms(source),0.01);try Archive.wav(source,to:wav);XCTAssertGreaterThan(try Archive.rms(wav),0.01)
    }

    func testConfigurableCapacityValidation() throws {
        XCTAssertEqual(try TranscriptCapacity.bytes(megabytes:"500"),500000000);XCTAssertEqual(try TranscriptCapacity.bytes(megabytes:"1"),1000000)
        for invalid in ["0","-1","10001","ten",""] {XCTAssertThrowsError(try TranscriptCapacity.bytes(megabytes:invalid))}
    }

}
