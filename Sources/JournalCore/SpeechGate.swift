import AVFoundation
import Darwin
import Foundation

public enum AudioSavingMode: String, CaseIterable { case speechOnly, continuous }

/// Pinned tiny CPU VAD, called only on the writer lane. Never on the microphone callback.
public final class SpeechVAD {
    private typealias Create = @convention(c) (UnsafePointer<CChar>) -> UnsafeMutableRawPointer?
    private typealias Score =
        @convention(c) (UnsafeMutableRawPointer, UnsafePointer<Float>) -> Float
    private typealias Free = @convention(c) (UnsafeMutableRawPointer) -> Void
    private let library: UnsafeMutableRawPointer
    private let handle: UnsafeMutableRawPointer
    private let score: Score
    private let free: Free
    private let resetState: Free
    public init(project: URL) throws {
        guard
            let lib = dlopen(
                project.appendingPathComponent("bin/libNagiVAD.dylib").path, RTLD_NOW | RTLD_LOCAL)
        else {
            throw JournalError(
                "Speech detector unavailable. Rebuild Nagi or choose Continuous audio in Settings → Storage."
            )
        }
        guard let c = dlsym(lib, "nagi_vad_create"), let s = dlsym(lib, "nagi_vad_score"),
            let f = dlsym(lib, "nagi_vad_free"), let r = dlsym(lib, "nagi_vad_reset")
        else {
            dlclose(lib); throw JournalError("Speech detector has an incompatible version.")
        }
        let create = unsafeBitCast(c, to: Create.self)
        guard
            let instance = project.appendingPathComponent("Models/silero-vad-v6.2-F32.gguf").path
                .withCString({ create($0) })
        else {
            dlclose(lib);
            throw JournalError(
                "Speech detector model could not load. Install the Silero model or choose Continuous audio in Settings → Storage. Recording has not started."
            )
        }
        library = lib; handle = instance; score = unsafeBitCast(s, to: Score.self);
        free = unsafeBitCast(f, to: Free.self); resetState = unsafeBitCast(r, to: Free.self)
    }
    deinit { free(handle); dlclose(library) }
    public func reset() { resetState(handle) }
    public func probability(_ samples: [Float]) throws -> Float {
        guard samples.count == 512 else { throw JournalError("Invalid speech detector frame") }
        let p = samples.withUnsafeBufferPointer { score(handle, $0.baseAddress!) }
        guard p >= 0 && p <= 1 else {
            throw JournalError(
                "Speech detector failed. Recording stopped; saved speech remains. Retry or select Continuous audio."
            )
        }
        return p
    }
}

/// Original-rate frames remain intact; the 16 kHz mono detector copy is never saved.
public final class SpeechGate {
    public struct Block { public let buffer: AVAudioPCMBuffer; public let offset: Double }
    private let score: ([Float]) throws -> Float
    private var channelScore: (([Float], Int) throws -> Float)?
    private var resetScore: (() -> Void)?
    private var lastInputEnd = 0.0
    private var pendingOffset = 0.0
    private var epochStarted = false
    private var pending: AVAudioPCMBuffer?
    private var pendingCount = 0
    private var inputFrames: Int64 = 0
    private var blockIndex: Int64 = 0
    private var format: AVAudioFormat?
    private var preRoll: [Block] = []
    private var lastSpeechEnd = -Double.infinity
    private var saving = false
    private var omittedStart = 0.0
    private var reportedEnd = 0.0
    private var finished = false
    public var onKeep: ((AVAudioPCMBuffer, Double) throws -> Void)?
    public var onClose: ((Double) throws -> Void)?
    public var onGap: ((Double, Double) throws -> Void)?
    public var onDiscontinuity: ((Double, Double) throws -> Void)?
    public var onActivity: ((Bool) -> Void)?
    public private(set) var peakBufferedFrames = 0
    public init(score: @escaping ([Float]) throws -> Float) { self.score = score }
    public convenience init(vad: SpeechVAD) { self.init(score: { try vad.probability($0) }) }
    /// One recurrent state per channel. Keep all original channels if any detects speech.
    public convenience init(project: URL) throws {
        var detectors = [try SpeechVAD(project: project)]
        self.init(score: { try detectors[0].probability($0) })
        channelScore = { samples, channel in
            while detectors.count <= channel { detectors.append(try SpeechVAD(project: project)) }
            return try detectors[channel].probability(samples)
        }
        resetScore = { for detector in detectors { detector.reset() } }
    }
    public convenience init(
        channelScore: @escaping ([Float], Int) throws -> Float, reset: @escaping () -> Void = {}
    ) {
        self.init(score: { try channelScore($0, 0) })
        self.channelScore = channelScore
        resetScore = reset
    }
    public var confirmedOmissionEnd: Double { reportedEnd }
    public var duration: Double { lastInputEnd }
    private func length(_ index: Int64) -> Int {
        let rate = format!.sampleRate
        return Int(floor(Double(index + 1) * rate * 0.032) - floor(Double(index) * rate * 0.032))
    }
    public func feed(_ buffer: AVAudioPCMBuffer, at offset: Double? = nil) throws {
        guard !finished else { throw JournalError("Speech gate already finalized") }
        if format == nil {
            guard buffer.format.commonFormat == .pcmFormatFloat32, buffer.format.sampleRate >= 8000,
                buffer.format.sampleRate <= 192000, buffer.format.channelCount <= 16
            else {
                throw JournalError(
                    "Speech-only saving requires Float32 audio at 8–192 kHz with at most 16 channels. Choose Continuous audio for this format."
                )
            }
            format = buffer.format
        }
        guard buffer.format == format else {
            throw JournalError("Input format changed; restart recording.")
        }
        let position = offset ?? duration
        guard position.isFinite, position >= 0 else {
            throw JournalError("Invalid speech gate clock")
        }
        if epochStarted, abs(position - duration) > 0.02 {
            let oldEnd = duration
            try endEpoch()
            try onDiscontinuity?(oldEnd, position)
        }
        if !epochStarted {
            lastInputEnd = position; omittedStart = position; reportedEnd = position
            epochStarted = true
        }
        var consumed = 0
        while consumed < Int(buffer.frameLength) {
            let target = length(blockIndex)
            if pending == nil {
                pendingOffset = position + Double(consumed) / format!.sampleRate
                pending = AVAudioPCMBuffer(
                    pcmFormat: format!, frameCapacity: AVAudioFrameCount(target))!
            }
            let n = min(target - pendingCount, Int(buffer.frameLength) - consumed)
            copy(buffer, from: consumed, to: pending!, at: pendingCount, count: n)
            consumed += n; pendingCount += n; inputFrames += Int64(n)
            lastInputEnd = position + Double(consumed) / format!.sampleRate
            if pendingCount == target {
                let block = pending!; block.frameLength = AVAudioFrameCount(target)
                pending = nil; pendingCount = 0
                try process(
                    Block(
                        buffer: block,
                        offset: pendingOffset))
                blockIndex += 1
            }
        }
    }
    private func copy(
        _ src: AVAudioPCMBuffer, from: Int, to dst: AVAudioPCMBuffer, at: Int, count: Int
    ) {
        let a = UnsafeMutableAudioBufferListPointer(src.mutableAudioBufferList)
        let b = UnsafeMutableAudioBufferListPointer(dst.mutableAudioBufferList)
        let stride = Int(format!.streamDescription.pointee.mBytesPerFrame)
        for i in 0..<a.count {
            memcpy(
                b[i].mData!.advanced(by: at * stride), a[i].mData!.advanced(by: from * stride),
                count * stride)
        }
    }
    private func process(_ block: Block) throws {
        let buffer = block.buffer; let n = Int(buffer.frameLength);
        let data = buffer.floatChannelData!
        let channels = Int(buffer.format.channelCount);
        let interleaved = buffer.format.isInterleaved
        func sample(_ channel: Int, _ i: Int) -> Float {
            interleaved ? data[0][i * channels + channel] : data[channel][i]
        }
        // Select strongest channel for VAD; downmix could cancel two channels. Save every channel.
        var chosen = 0; var power: Float = -1
        for c in 0..<channels {
            var energy: Float = 0; for i in 0..<n { let x = sample(c, i); energy += x * x }
            if energy > power { power = energy; chosen = c }
        }
        func mono(_ channel: Int) -> [Float] {
            var result = [Float](repeating: 0, count: 512)
            for i in 0..<512 {
                let x = Double(i) * Double(n) / 512
                let lo = min(n - 1, Int(x)), hi = min(n - 1, lo + 1)
                result[i] =
                    sample(channel, lo) + Float(x - Double(lo))
                    * (sample(channel, hi) - sample(channel, lo))
            }
            return result
        }
        var p: Float = 0
        if let channelScore {
            for channel in 0..<channels {
                let value = try channelScore(mono(channel), channel)
                guard value.isFinite, value >= 0, value <= 1 else {
                    throw JournalError("Invalid channel speech probability")
                }
                p = max(p, value)
            }
        } else {
            p = try score(mono(chosen))
        }
        guard p.isFinite, p >= 0, p <= 1 else {
            throw JournalError("Invalid speech detection probability")
        }
        let end = block.offset + Double(n) / buffer.format.sampleRate
        if p >= (saving ? 0.20 : 0.35) { lastSpeechEnd = end }
        if !saving && p >= 0.35 {
            let start = preRoll.first?.offset ?? block.offset
            if start > omittedStart { try onGap?(omittedStart, start) }
            saving = true; onActivity?(true)
            for prior in preRoll { try onKeep?(prior.buffer, prior.offset) }
            preRoll.removeAll(keepingCapacity: true)
        }
        if saving {
            try onKeep?(buffer, block.offset)
            if end - lastSpeechEnd >= 1 {
                try onClose?(end); saving = false; omittedStart = end; reportedEnd = end;
                onActivity?(false)
            }
        } else {
            preRoll.append(block)
            while let first = preRoll.first, end - first.offset > 1.032 { preRoll.removeFirst() }
            let durableEnd = preRoll.first?.offset ?? end
            if durableEnd - reportedEnd >= 1 {
                try onGap?(omittedStart, durableEnd); reportedEnd = durableEnd
            }
        }
        peakBufferedFrames = max(
            peakBufferedFrames, preRoll.reduce(0) { $0 + Int($1.buffer.frameLength) } + pendingCount
        )
    }
    private func flushEpoch() throws {
        if let pending, pendingCount > 0 {
            let count = pendingCount
            pending.frameLength = AVAudioFrameCount(count)
            self.pending = nil; pendingCount = 0
            try process(
                Block(buffer: pending, offset: pendingOffset)
            )
        }
        if saving {
            try onClose?(duration)
        } else if duration > omittedStart {
            try onGap?(omittedStart, duration)
        }
        preRoll.removeAll(); saving = false
    }
    public func endEpoch() throws {
        guard !finished else { throw JournalError("Speech gate already finalized") }
        try flushEpoch()
        pending = nil; pendingCount = 0; inputFrames = 0; blockIndex = 0
        lastSpeechEnd = -.infinity; epochStarted = false
        resetScore?()
    }
    public func finish() throws {
        guard !finished else { return }
        finished = true
        try flushEpoch()
    }
}
