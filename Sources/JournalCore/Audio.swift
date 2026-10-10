import Foundation
import AVFoundation
import CoreAudio
import AudioToolbox

public struct InputDevice: Identifiable, Hashable { public let id:String; public let name:String; public let audioID:AudioDeviceID }
public enum Devices {
    public static func inputs()->[InputDevice] {
        var address=AudioObjectPropertyAddress(mSelector:kAudioHardwarePropertyDevices,mScope:kAudioObjectPropertyScopeGlobal,mElement:kAudioObjectPropertyElementMain)
        var size:UInt32=0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject),&address,0,nil,&size)==noErr else {return []}
        var ids=[AudioDeviceID](repeating:0,count:Int(size)/MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),&address,0,nil,&size,&ids)==noErr else {return []}
        return ids.compactMap { id in
            var a=AudioObjectPropertyAddress(mSelector:kAudioDevicePropertyStreams,mScope:kAudioDevicePropertyScopeInput,mElement:kAudioObjectPropertyElementMain);var s:UInt32=0
            guard AudioObjectGetPropertyDataSize(id,&a,0,nil,&s)==noErr,s>0 else {return nil}
            func string(_ selector:AudioObjectPropertySelector)->String {
                var a=AudioObjectPropertyAddress(mSelector:selector,mScope:kAudioObjectPropertyScopeGlobal,mElement:kAudioObjectPropertyElementMain);var value:CFString="" as CFString;var s=UInt32(MemoryLayout<CFString>.size)
                guard AudioObjectGetPropertyData(id,&a,0,nil,&s,&value)==noErr else {return ""};return value as String
            }
            return InputDevice(id:string(kAudioDevicePropertyDeviceUID),name:string(kAudioObjectPropertyName),audioID:id)
        }
    }
}

public enum LocalProcess {
    /// No shell interpolation. Disk logs avoid pipe deadlocks and bounded output memory.
    @discardableResult public static func run(_ executable:String,_ args:[String],log:URL? = nil,timeout:Double = 180) throws -> Int32 {
        let p=Process();p.executableURL=URL(fileURLWithPath:executable);p.arguments=args;p.qualityOfService = .utility
        let logURL=log ?? FileManager.default.temporaryDirectory.appendingPathComponent("stillpoint-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath:logURL.path,contents:nil);let handle=try FileHandle(forWritingTo:logURL);defer {try? handle.close();if log==nil {try? FileManager.default.removeItem(at:logURL)}}
        p.standardOutput=handle;p.standardError=handle;try p.run();let deadline=Date().addingTimeInterval(timeout)
        while p.isRunning && Date()<deadline { Thread.sleep(forTimeInterval:0.05) }
        if p.isRunning { p.terminate();Thread.sleep(forTimeInterval:0.2);if p.isRunning {kill(p.processIdentifier,SIGKILL)};p.waitUntilExit();throw JournalError("Local worker exceeded \(Int(timeout)) seconds; recording is safe. Retry with a smaller model.") }
        p.waitUntilExit();guard p.terminationStatus==0 else { let details=(try? String(contentsOf:logURL,encoding:.utf8)) ?? "";throw JournalError("Local worker failed (\(p.terminationStatus)): \(String(details.suffix(500)))") }; return p.terminationStatus
    }
}

public enum Archive {
    public static func readable(_ chunk:Chunk,store:Store)->URL { store.root.appendingPathComponent(chunk.path) }
    public static func unpack(_ chunk:Chunk,store:Store)->URL {
        store.root.appendingPathComponent("derived/\(chunk.id).caf")
    }
    public static func decompress(_ chunk:Chunk,store:Store) throws -> URL {
        guard store.audioAvailable(chunk) else {throw JournalError("Audio has expired or is missing. Its transcript is still available.")}
        let source=readable(chunk,store:store)
        if source.pathExtension != "gz" {return source}
        let dest=unpack(chunk,store:store)
        let process=Process();process.executableURL=URL(fileURLWithPath:"/usr/bin/gzip");process.arguments=["-dc",source.path]
        FileManager.default.createFile(atPath:dest.path,contents:nil);let out=try FileHandle(forWritingTo:dest);defer{try? out.close()};process.standardOutput=out;process.standardError=FileHandle.nullDevice;try process.run();process.waitUntilExit();guard process.terminationStatus==0 else {throw JournalError("Audio archive is damaged; transcript is safe.")};return dest
    }
    public static func compress(_ chunk:Chunk,store:Store) throws {
        let source=readable(chunk,store:store);guard source.pathExtension=="caf" else {return}
        let dest=source.appendingPathExtension("gz"),tmp=dest.appendingPathExtension("partial")
        let process=Process();process.executableURL=URL(fileURLWithPath:"/usr/bin/gzip");process.arguments=["-1","-c",source.path]
        FileManager.default.createFile(atPath:tmp.path,contents:nil);let out=try FileHandle(forWritingTo:tmp);process.standardOutput=out;process.standardError=FileHandle.nullDevice;try process.run();process.waitUntilExit();try out.synchronize();try out.close()
        guard process.terminationStatus==0 else {try? FileManager.default.removeItem(at:tmp);throw JournalError("Compression failed; original CAF retained")}
        try FileManager.default.moveItem(at:tmp,to:dest)
        try store.exec("UPDATE chunks SET path=? WHERE id=?",[chunk.path+".gz",chunk.id]);try FileManager.default.removeItem(at:source)
    }
    public static func recover(_ store:Store) throws {
        try store.recover()
        for chunk in try store.chunks() {
            let source=readable(chunk,store:store)
            // Crash between compression rename, SQLite commit and original removal.
            if source.pathExtension == "caf",FileManager.default.fileExists(atPath:source.appendingPathExtension("gz").path) {
                try store.exec("UPDATE chunks SET path=? WHERE id=?",[chunk.path+".gz",chunk.id]);try? FileManager.default.removeItem(at:source)
            }
            if chunk.status=="writing" {
                do {let file=try AVAudioFile(forReading:source);try store.seal(chunk.id,duration:Double(file.length)/file.processingFormat.sampleRate)}
                catch {try store.exec("UPDATE chunks SET status='failed',error='Incomplete final chunk; earlier chunks remain intact' WHERE id=?",[chunk.id])}
            }
        }
        // Remove only orphaned/completed temporary files in our audio directory.
        let known=Set(try store.chunks().map(\.path))
        for url in try FileManager.default.contentsOfDirectory(at:store.root.appendingPathComponent("audio"),includingPropertiesForKeys:nil) {
            let relative="audio/"+url.lastPathComponent
            if !known.contains(relative) {try? FileManager.default.removeItem(at:url)}
        }
    }
    public static func wav(_ source:URL,to dest:URL) throws {
        try LocalProcess.run("/usr/bin/afconvert",[source.path,dest.path,"-f","WAVE","-d","LEI16@16000","-c","1"])
    }
    public static func rms(_ source:URL) throws -> Double {
        let file=try AVAudioFile(forReading:source);guard let buffer=AVAudioPCMBuffer(pcmFormat:file.processingFormat,frameCapacity:4096) else {return 0}
        var sum=0.0,count=0
        while file.framePosition<file.length {try file.read(into:buffer);if let data=buffer.floatChannelData {for i in 0..<Int(buffer.frameLength) {let v=Double(data[0][i]);sum += v*v;count += 1}}}
        return count>0 ? sqrt(sum/Double(count)) : 0
    }
}

/// Capture never waits for ASR. At most 64 queued buffers; overload stops with an explicit gap.
public final class ChunkWriter: @unchecked Sendable {
    public let store:Store;public let session:String;public let model:String
    private var file:AVAudioFile?;private var chunkID="";private var frames:Int64=0;private var total:Int64=0;private var rate:Double=0
    private let started:Double;private let queue=DispatchQueue(label:"stillpoint.capture.write",qos:.userInitiated)
    private let slots=DispatchSemaphore(value:64)
    public var onLevel:((Double)->Void)?;public var onError:((String)->Void)?;public var onChunk:(()->Void)?
    private var failed=false
    private var imported=false
    public init(store:Store,session:String,model:String,started:Double=Date().timeIntervalSince1970){self.store=store;self.session=session;self.model=model;self.started=started}
    public func enqueue(_ buffer:AVAudioPCMBuffer) {
        guard slots.wait(timeout:.now()) == .success else {onError?("Storage could not keep up; recording stopped with a gap.");return}
        guard let copy=AVAudioPCMBuffer(pcmFormat:buffer.format,frameCapacity:buffer.frameLength) else {slots.signal();return}
        copy.frameLength=buffer.frameLength
        let src=UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList),dst=UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for i in 0..<src.count {if let a=src[i].mData,let b=dst[i].mData {memcpy(b,a,Int(src[i].mDataByteSize))}}
        queue.async {defer{self.slots.signal()};do {try self.write(copy)}catch{self.failed=true;self.onError?(error.localizedDescription)}}
    }
    public func write(_ buffer:AVAudioPCMBuffer) throws {
        guard !failed else {return}
        if file==nil {
            rate=buffer.format.sampleRate;try store.set("format-"+session,"\(rate) Hz · \(buffer.format.channelCount) channels · original Float32 CAF / gzip");let path="audio/\(UUID().uuidString).caf"
            chunkID=try store.registerChunk(session:session,path:path,captured:started+(imported ? 0:Double(total)/rate),offset:Double(total)/rate,model:model)
            file=try AVAudioFile(forWriting:store.root.appendingPathComponent(path),settings:buffer.format.settings);frames=0
        }
        guard buffer.format.sampleRate==rate else {throw JournalError("Input format changed; finalize and start a new recording.")}
        try file!.write(from:buffer);frames += Int64(buffer.frameLength);total += Int64(buffer.frameLength)
        if let data=buffer.floatChannelData {var sum=0.0;for i in 0..<Int(buffer.frameLength){sum += Double(data[0][i]*data[0][i])};onLevel?(sqrt(sum/max(1,Double(buffer.frameLength))))}
        if Double(frames)/rate>=10 {try closeChunk()}
    }
    private func closeChunk() throws {guard file != nil else {return};let url=file!.url;file=nil;let handle=try FileHandle(forWritingTo:url);try handle.synchronize();try handle.close();try store.seal(chunkID,duration:Double(frames)/rate);onChunk?()}
    public func finish() throws {var thrown:Error?;queue.sync {do{try closeChunk()}catch{thrown=error}};if let thrown {throw thrown}}
    public func importFile(_ url:URL) throws {
        imported=true
        let input=try AVAudioFile(forReading:url)
        guard let buffer=AVAudioPCMBuffer(pcmFormat:input.processingFormat,frameCapacity:4096) else {throw JournalError("Cannot allocate import buffer")}
        while input.framePosition<input.length {try input.read(into:buffer);try write(buffer)};try closeChunk()
    }
}

public final class Capture {
    private let engine=AVAudioEngine();private var writer:ChunkWriter?
    public init(){}
    public func start(device:InputDevice,writer:ChunkWriter) throws {
        guard Devices.inputs().contains(where:{$0.id==device.id}) else {throw JournalError("Selected input is disconnected. No fallback microphone will be used.")}
        let node=engine.inputNode;guard let unit=node.audioUnit else {throw JournalError("Input audio unit unavailable")};var id=device.audioID
        let code=AudioUnitSetProperty(unit,kAudioOutputUnitProperty_CurrentDevice,kAudioUnitScope_Global,0,&id,UInt32(MemoryLayout<AudioDeviceID>.size))
        guard code==noErr else {throw JournalError("Cannot select input device (\(code)).")}
        var actual:AudioDeviceID=0;var size=UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioUnitGetProperty(unit,kAudioOutputUnitProperty_CurrentDevice,kAudioUnitScope_Global,0,&actual,&size)==noErr,actual==device.audioID else {throw JournalError("Input UID verification failed. Recording has not started.")}
        let format=node.outputFormat(forBus:0);guard format.sampleRate>0,format.channelCount>0 else {throw JournalError("Device has no usable input format")}
        self.writer=writer;node.installTap(onBus:0,bufferSize:4096,format:format){buffer,_ in
            var actual:AudioDeviceID=0;var size=UInt32(MemoryLayout<AudioDeviceID>.size)
            guard AudioUnitGetProperty(unit,kAudioOutputUnitProperty_CurrentDevice,kAudioUnitScope_Global,0,&actual,&size)==noErr,actual==device.audioID else {writer.onError?("Selected input changed or disappeared. No fallback buffer was saved.");return}
            var address=AudioObjectPropertyAddress(mSelector:kAudioDevicePropertyDeviceUID,mScope:kAudioObjectPropertyScopeGlobal,mElement:kAudioObjectPropertyElementMain)
            var uid:CFString="" as CFString;var uidSize=UInt32(MemoryLayout<CFString>.size)
            guard AudioObjectGetPropertyData(actual,&address,0,nil,&uidSize,&uid)==noErr,(uid as String)==device.id else {writer.onError?("Input UID changed. No replacement-device audio was saved.");return}
            writer.enqueue(buffer)
        }
        do {try engine.start()} catch {node.removeTap(onBus:0);self.writer=nil;throw error}
    }
    public func stop() throws {engine.stop();if writer != nil {engine.inputNode.removeTap(onBus:0)};try writer?.finish();writer=nil}
}
