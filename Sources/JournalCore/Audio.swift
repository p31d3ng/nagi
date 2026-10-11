import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation

public struct InputDevice: Identifiable, Hashable {
    public let id: String
    public let name: String
    public let audioID: AudioDeviceID
}
public enum Devices {
    public static func inputs() -> [InputDevice] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard
            AudioObjectGetPropertyDataSize(
                AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr
        else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr
        else { return [] }
        return ids.compactMap { id in
            var a = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreams, mScope: kAudioDevicePropertyScopeInput,
                mElement: kAudioObjectPropertyElementMain)
            var s: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &a, 0, nil, &s) == noErr, s > 0 else {
                return nil
            }
            func string(_ selector: AudioObjectPropertySelector) -> String {
                var a = AudioObjectPropertyAddress(
                    mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                    mElement: kAudioObjectPropertyElementMain)
                var value: CFString = "" as CFString
                var s = UInt32(MemoryLayout<CFString>.size)
                guard AudioObjectGetPropertyData(id, &a, 0, nil, &s, &value) == noErr else {
                    return ""
                }
                return value as String
            }
            return InputDevice(
                id: string(kAudioDevicePropertyDeviceUID), name: string(kAudioObjectPropertyName),
                audioID: id)
        }
    }
}

public enum LocalProcess {
    /// No shell interpolation. Disk logs avoid pipe deadlocks and bounded output memory.
    @discardableResult public static func run(
        _ executable: String, _ args: [String], log: URL? = nil, timeout: Double = 180,
        environment: [String: String] = [:]
    ) throws -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = args
        p.qualityOfService = .utility
        if !environment.isEmpty {
            p.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new
            }
        }
        let logURL =
            log
            ?? FileManager.default.temporaryDirectory.appendingPathComponent(
                "nagi-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: logURL)
        defer {
            try? handle.close()
            if log == nil { try? FileManager.default.removeItem(at: logURL) }
        }
        p.standardOutput = handle
        p.standardError = handle
        try p.run()
        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if p.isRunning {
            p.terminate()
            Thread.sleep(forTimeInterval: 0.2)
            if p.isRunning { kill(p.processIdentifier, SIGKILL) }
            p.waitUntilExit()
            throw JournalError(
                "Local worker exceeded \(Int(timeout)) seconds; recording is safe. Retry with a smaller model."
            )
        }
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            let details = logTail(logURL)
            throw JournalError(
                "Local worker failed (\(p.terminationStatus)): \(String(details.suffix(500)))")
        }
        return p.terminationStatus
    }
    public static func logTail(_ url: URL, bytes: Int = 4096) -> String {
        guard bytes > 0, let input = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? input.close() }
        guard let end = try? input.seekToEnd() else { return "" }
        try? input.seek(toOffset: end > UInt64(bytes) ? end - UInt64(bytes) : 0)
        return String(decoding: (try? input.read(upToCount: bytes)) ?? Data(), as: UTF8.self)
    }
}

public enum Archive {
    public static func readable(_ chunk: Chunk, store: Store) -> URL {
        store.root.appendingPathComponent(chunk.path)
    }
    public static func unpack(_ chunk: Chunk, store: Store) -> URL {
        store.root.appendingPathComponent("derived/\(chunk.id).\(UUID().uuidString).caf")
    }
    public static func decompress(_ chunk: Chunk, store: Store) throws -> URL {
        guard store.audioAvailable(chunk) else {
            throw JournalError(
                "Audio has expired or is missing. Its transcript is still available.")
        }
        let source = readable(chunk, store: store)
        if source.pathExtension != "gz" { return source }
        let dest = unpack(chunk, store: store)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        process.arguments = ["-dc", source.path]
        FileManager.default.createFile(atPath: dest.path, contents: nil)
        let out = try FileHandle(forWritingTo: dest)
        defer { try? out.close() }
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw JournalError("Audio archive is damaged; transcript is safe.")
        }
        return dest
    }
    public static func compress(_ chunk: Chunk, store: Store) throws {
        let source = readable(chunk, store: store)
        guard source.pathExtension == "caf" else { return }
        let dest = source.appendingPathExtension("gz")
        let tmp = dest.appendingPathExtension("partial")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        process.arguments = ["-1", "-c", source.path]
        FileManager.default.createFile(atPath: tmp.path, contents: nil)
        let out = try FileHandle(forWritingTo: tmp)
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        try out.synchronize()
        try out.close()
        guard process.terminationStatus == 0 else {
            try? FileManager.default.removeItem(at: tmp)
            throw JournalError("Compression failed; original CAF retained")
        }
        try FileManager.default.moveItem(at: tmp, to: dest)
        try store.exec("UPDATE chunks SET path=? WHERE id=?", [chunk.path + ".gz", chunk.id])
        try FileManager.default.removeItem(at: source)
    }
    public static func recover(_ store: Store) throws {
        try store.recover()
        _ = try store.cleanup(cap: 0)
        // No worker/playback survives app startup; remove crash-left SDK temporary audio too.
        for url in try FileManager.default.contentsOfDirectory(
            at: store.root.appendingPathComponent("derived"), includingPropertiesForKeys: nil)
        { try FileManager.default.removeItem(at: url) }
        for chunk in try store.chunksWithAudio() {
            let source = readable(chunk, store: store)
            // Crash between compression rename, SQLite commit and original removal.
            if source.pathExtension == "caf",
                FileManager.default.fileExists(atPath: source.appendingPathExtension("gz").path)
            {
                try store.exec(
                    "UPDATE chunks SET path=? WHERE id=?", [chunk.path + ".gz", chunk.id])
                try? FileManager.default.removeItem(at: source)
            }
            if chunk.status == "writing" {
                do {
                    let file = try AVAudioFile(forReading: source)
                    try store.seal(
                        chunk.id, duration: Double(file.length) / file.processingFormat.sampleRate)
                } catch {
                    try store.exec(
                        "UPDATE chunks SET status='failed',error='Incomplete final chunk; earlier chunks remain intact' WHERE id=?",
                        [chunk.id])
                }
            }
        }
        // Remove only orphaned/completed temporary files in our audio directory.
        let known = Set(try store.chunksWithAudio().map(\.path))
        for url in try FileManager.default.contentsOfDirectory(
            at: store.root.appendingPathComponent("audio"), includingPropertiesForKeys: nil)
        {
            let relative = "audio/" + url.lastPathComponent
            if !known.contains(relative) { try? FileManager.default.removeItem(at: url) }
        }
    }
    public static func wav(_ source: URL, to dest: URL) throws {
        try LocalProcess.run(
            "/usr/bin/afconvert",
            [source.path, dest.path, "-f", "WAVE", "-d", "LEI16@16000", "-c", "1", "--mix"])
    }
    /// Bounded ASR-only context; the original continuous archive has no overlap or omissions.
    public static func context(_ chunk: Chunk, central: URL, to dest: URL, store: Store) throws
        -> Double
    {
        var samples: [Float] = []
        var lead = 0.0
        var captured = chunk.captured
        func append(_ url: URL, tail: Bool?, seconds: Double = 0.75) throws -> Int {
            let f = try AVAudioFile(forReading: url)
            let n = tail == nil ? Int(f.length) : min(Int(f.length), Int(seconds * 16000))
            if tail == true { f.framePosition = f.length - Int64(n) }
            guard let b = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: 4096)
            else {
                throw JournalError("Cannot allocate bounded context")
            }
            var read = 0
            while read < n {
                try f.read(into: b, frameCount: AVAudioFrameCount(min(4096, n - read)))
                guard b.frameLength > 0 else {
                    throw JournalError("Unexpected end of context audio")
                }
                if let data = b.floatChannelData {
                    samples.append(
                        contentsOf: UnsafeBufferPointer(start: data[0], count: Int(b.frameLength)))
                }
                read += Int(b.frameLength)
            }
            return read
        }
        func adjacent(before: Bool) throws {
            guard let other = try store.neighbor(chunk, before: before),
                store.audioAvailable(other),
                abs(
                    before
                        ? other.offset + other.duration - chunk.offset
                        : chunk.offset + chunk.duration - other.offset) < 0.002
            else { return }
            captured = min(captured, other.captured)
            let source = try decompress(other, store: store)
            let temporary = store.root.appendingPathComponent("derived/\(chunk.id).neighbor.wav")
            defer {
                try? FileManager.default.removeItem(at: temporary)
                if source.path.contains("/derived/") {
                    try? FileManager.default.removeItem(at: source)
                }
            }
            try wav(source, to: temporary)
            let count = try append(temporary, tail: before)
            if before { lead = Double(count) / 16000 }
        }
        try adjacent(before: true)
        _ = try append(central, tail: nil)
        try adjacent(before: false)
        guard samples.count <= 16000 * 12 else {
            throw JournalError("Context exceeds bounded ASR job")
        }
        let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        let buffer = AVAudioPCMBuffer(
            pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
        buffer.frameLength = buffer.frameCapacity
        samples.withUnsafeBufferPointer {
            buffer.floatChannelData![0].update(from: $0.baseAddress!, count: $0.count)
        }
        let floatURL = store.root.appendingPathComponent("derived/\(chunk.id).context.caf")
        defer { try? FileManager.default.removeItem(at: floatURL) }
        var output: AVAudioFile? = try AVAudioFile(forWriting: floatURL, settings: format.settings)
        try output!.write(from: buffer)
        output!.close()
        output = nil
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: captured)], ofItemAtPath: floatURL.path)
        try wav(floatURL, to: dest)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: captured)], ofItemAtPath: dest.path)
        return lead
    }
    public static func rms(_ source: URL) throws -> Double {
        let file = try AVAudioFile(forReading: source)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096)
        else { return 0 }
        var sums = [Double](repeating: 0, count: Int(file.processingFormat.channelCount))
        var count = 0
        while file.framePosition < file.length {
            try file.read(into: buffer)
            if let data = buffer.floatChannelData {
                for channel in sums.indices {
                    for i in 0..<Int(buffer.frameLength) {
                        let v = Double(data[channel][i])
                        sums[channel] += v * v
                    }
                }
                count += Int(buffer.frameLength)
            }
        }
        return count > 0 ? sqrt((sums.max() ?? 0) / Double(count)) : 0
    }
}

/// Capture never waits for ASR. At most 64 queued buffers; overload stops with an explicit gap.
public final class ChunkWriter: @unchecked Sendable {
    public let store: Store
    public let session: String
    public let model: String
    private var file: AVAudioFile?
    private var chunkID = ""
    private var frames: Int64 = 0
    private var total: Int64 = 0
    private var rate: Double = 0
    private let started: Double
    private let queue = DispatchQueue(
        label: "nagi.capture.write", qos: .userInitiated, autoreleaseFrequency: .workItem)
    private let slots = DispatchSemaphore(value: 64)
    public var onLevel: ((Double) -> Void)?
    public var onError: ((String) -> Void)?
    public var onChunk: (() -> Void)?
    private var failed = false
    private var imported = false
    private let admission = NSLock()
    private var stopped = false
    public init(
        store: Store, session: String, model: String, started: Double = Date().timeIntervalSince1970
    ) {
        self.store = store
        self.session = session
        self.model = model
        self.started = started
    }
    @discardableResult public func enqueue(_ buffer: AVAudioPCMBuffer) -> Bool {
        admission.lock()
        if stopped {
            admission.unlock()
            return false
        }
        guard slots.wait(timeout: .now()) == .success else {
            stopped = true
            admission.unlock()
            onError?("Storage could not keep up; recording stopped with a gap.")
            return false
        }
        admission.unlock()
        guard
            let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength)
        else {
            slots.signal()
            return false
        }
        copy.frameLength = buffer.frameLength
        let src = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        let dst = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for i in 0..<src.count {
            if let a = src[i].mData, let b = dst[i].mData {
                memcpy(b, a, Int(src[i].mDataByteSize))
            }
        }
        queue.async {
            defer { self.slots.signal() }
            do { try self.write(copy) } catch {
                self.failed = true
                self.admission.lock()
                self.stopped = true
                self.admission.unlock()
                self.onError?(error.localizedDescription)
            }
        }
        return true
    }
    public func write(_ buffer: AVAudioPCMBuffer) throws {
        guard !failed else { return }
        let target = Int64(buffer.format.sampleRate * 10)
        let remaining = target - (file == nil ? 0 : frames)
        if Int64(buffer.frameLength) > remaining {
            // Split exactly at the original-rate frame boundary, never drop or repeat samples.
            for (offset, count) in [
                (0, Int(remaining)), (Int(remaining), Int(buffer.frameLength) - Int(remaining)),
            ] {
                let part = AVAudioPCMBuffer(
                    pcmFormat: buffer.format, frameCapacity: AVAudioFrameCount(count))!
                part.frameLength = part.frameCapacity
                let src = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
                let dst = UnsafeMutableAudioBufferListPointer(part.mutableAudioBufferList)
                for i in 0..<src.count {
                    let stride = Int(src[i].mDataByteSize) / Int(buffer.frameLength)
                    memcpy(
                        dst[i].mData!, src[i].mData!.advanced(by: offset * stride), count * stride)
                }
                try write(part)
            }
            return
        }
        if file == nil {
            rate = buffer.format.sampleRate
            try store.set(
                "format-" + session,
                "\(rate) Hz · \(buffer.format.channelCount) channels · original Float32 CAF / gzip")
            let path = "audio/\(UUID().uuidString).caf"
            chunkID = try store.registerChunk(
                session: session, path: path,
                captured: started + (imported ? 0 : Double(total) / rate),
                offset: Double(total) / rate, model: model)
            file = try AVAudioFile(
                forWriting: store.root.appendingPathComponent(path),
                settings: buffer.format.settings)
            frames = 0
        }
        guard buffer.format.sampleRate == rate else {
            throw JournalError("Input format changed; finalize and start a new recording.")
        }
        try file!.write(from: buffer)
        frames += Int64(buffer.frameLength)
        total += Int64(buffer.frameLength)
        if let data = buffer.floatChannelData {
            var peak = 0.0
            for channel in 0..<Int(buffer.format.channelCount) {
                var sum = 0.0
                for i in 0..<Int(buffer.frameLength) {
                    sum += Double(data[channel][i] * data[channel][i])
                }
                peak = max(peak, sqrt(sum / max(1, Double(buffer.frameLength))))
            }
            onLevel?(peak)
        }
        if Double(frames) / rate >= 10 { try closeChunk() }
    }
    private func closeChunk() throws {
        guard file != nil else { return }
        let url = file!.url
        file!.close()
        file = nil
        let handle = try FileHandle(forWritingTo: url)
        try handle.synchronize()
        try handle.close()
        try store.seal(chunkID, duration: Double(frames) / rate)
        onChunk?()
    }
    public func finish() throws {
        var thrown: Error?
        queue.sync { do { try closeChunk() } catch { thrown = error } }
        if let thrown { throw thrown }
    }
    public func importFile(_ url: URL) throws {
        imported = true
        let input = try AVAudioFile(forReading: url)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: 4096)
        else { throw JournalError("Cannot allocate import buffer") }
        while input.framePosition < input.length {
            try autoreleasepool {
                try input.read(into: buffer)
                try write(buffer)
            }
        }
        try closeChunk()
    }
}

public final class Capture {
    private let engine = AVAudioEngine()
    private var writer: ChunkWriter?
    public init() {}
    public func start(device: InputDevice, writer: ChunkWriter) throws {
        guard Devices.inputs().contains(where: { $0.id == device.id }) else {
            throw JournalError(
                "Selected input is disconnected. No fallback microphone will be used.")
        }
        let node = engine.inputNode
        guard let unit = node.audioUnit else { throw JournalError("Input audio unit unavailable") }
        var id = device.audioID
        let code = AudioUnitSetProperty(
            unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id,
            UInt32(MemoryLayout<AudioDeviceID>.size))
        guard code == noErr else { throw JournalError("Cannot select input device (\(code)).") }
        var actual: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard
            AudioUnitGetProperty(
                unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &actual,
                &size)
                == noErr, actual == device.audioID
        else { throw JournalError("Input UID verification failed. Recording has not started.") }
        let format = node.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw JournalError("Device has no usable input format")
        }
        self.writer = writer
        node.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
            var actual: AudioDeviceID = 0
            var size = UInt32(MemoryLayout<AudioDeviceID>.size)
            guard
                AudioUnitGetProperty(
                    unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                    &actual, &size)
                    == noErr, actual == device.audioID
            else {
                writer.onError?(
                    "Selected input changed or disappeared. No fallback buffer was saved.")
                return
            }
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceUID, mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            var uid: CFString = "" as CFString
            var uidSize = UInt32(MemoryLayout<CFString>.size)
            guard AudioObjectGetPropertyData(actual, &address, 0, nil, &uidSize, &uid) == noErr,
                (uid as String) == device.id
            else {
                writer.onError?("Input UID changed. No replacement-device audio was saved.")
                return
            }
            writer.enqueue(buffer)
        }
        do { try engine.start() } catch {
            node.removeTap(onBus: 0)
            self.writer = nil
            throw error
        }
    }
    public func stop() throws {
        engine.stop()
        if writer != nil { engine.inputNode.removeTap(onBus: 0) }
        let pending = writer
        writer = nil
        try pending?.finish()
    }
}
