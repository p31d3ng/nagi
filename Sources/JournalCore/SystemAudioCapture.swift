import AVFoundation
import CoreMedia
import CoreGraphics
import ScreenCaptureKit

/// Audio-only output: no screen callback is registered and no pixels are stored.
/// Permission is preflighted before content enumeration; requesting it is a separate UI action.
public final class SystemAudioCapture: NSObject, SCStreamOutput, SCStreamDelegate,
    @unchecked Sendable
{
    public static func permitted() -> Bool { CGPreflightScreenCaptureAccess() }
    public static func requestPermission() -> Bool { CGRequestScreenCaptureAccess() }
    public static func configuration() -> SCStreamConfiguration {
        let c = SCStreamConfiguration()
        c.capturesAudio = true
        c.captureMicrophone = false
        c.excludesCurrentProcessAudio = true
        c.sampleRate = 48000; c.channelCount = 2
        c.width = 2; c.height = 2
        c.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        c.queueDepth = 3
        return c
    }
    private let permission: () -> Bool
    public init(permission: @escaping () -> Bool = SystemAudioCapture.permitted) {
        self.permission = permission
        super.init()
    }
    private func attach(_ writer: ChunkWriter) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !stopped else { return false }
        self.writer = writer
        return true
    }
    private func isClosed() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return stopped
    }
    private let lane = DispatchQueue(label: "nagi.system.audio", qos: .userInitiated)
    private var stream: SCStream?
    private var writer: ChunkWriter?
    private let lock = NSLock()
    private var stopped = false
    public var onError: ((String) -> Void)?
    public func prepare() async throws {
        try Task.checkCancellation()
        guard !isClosed() else { throw CancellationError() }
        guard permission() else {
            throw JournalError(
                "System audio permission is missing. Request it explicitly in Settings → Devices, then check again. No recording started."
            )
        }
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true)
        try Task.checkCancellation()
        guard let display = content.displays.first else {
            throw JournalError(
                "No display available for the system audio stream. Connect a display and retry.")
        }
        let filter = SCContentFilter(
            display: display,
            excludingApplications: content.applications.filter { $0.processID == getpid() },
            exceptingWindows: [])
        let stream = SCStream(filter: filter, configuration: Self.configuration(), delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: lane)
        self.stream = stream
    }
    public func start(writer: ChunkWriter) async throws {
        try Task.checkCancellation()
        guard !isClosed() else { throw CancellationError() }
        guard let stream else { throw JournalError("System audio stream has not been prepared") }
        guard attach(writer) else { throw CancellationError() }
        try Task.checkCancellation()
        try await stream.startCapture()
        try Task.checkCancellation()
    }
    /// Close admission synchronously before finalizing files. Late callbacks cannot append.
    public func close() {
        lock.lock(); stopped = true; writer = nil; lock.unlock()
        lane.sync {}
    }
    public func stop() async {
        close()
        if let stream { try? await stream.stopCapture() }
        stream = nil
    }
    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        lock.lock(); let active = !stopped; lock.unlock()
        guard active else { return }
        onError?("System audio stopped: " + error.localizedDescription)
    }
    public func stream(
        _ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .audio, sample.isValid, CMSampleBufferDataIsReady(sample),
            CMSampleBufferGetNumSamples(sample) > 0
        else { return }
        lock.lock(); let writer = stopped ? nil : writer; lock.unlock()
        guard let writer else { return }
        do {
            let buffer = try Self.copyAudio(sample)
            let now = CMClockGetTime(CMClockGetHostTimeClock()).seconds
            let pts = sample.presentationTimeStamp.seconds
            let stamp = AudioSources.timestamp(
                sample: pts, anchor: writer.hostAnchor ?? now, now: now)
            writer.enqueue(buffer, at: stamp.offset, clock: stamp.clock)
        } catch { onError?(error.localizedDescription) }
    }
    public static func copyAudio(_ sample: CMSampleBuffer) throws -> AVAudioPCMBuffer {
        let frames = CMSampleBufferGetNumSamples(sample)
        guard frames > 0, frames <= 8192, let description = sample.formatDescription else {
            throw JournalError("Invalid system audio sample")
        }
        let format = AVAudioFormat(cmAudioFormatDescription: description)
        guard
            format.commonFormat == .pcmFormatFloat32, format.channelCount <= 2,
            let result = AVAudioPCMBuffer(
                pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))
        else {
            throw JournalError(
                "Unsupported or oversized system audio sample; capture stopped without substituting a source."
            )
        }
        result.frameLength = AVAudioFrameCount(frames)
        let code = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sample, at: 0, frameCount: Int32(frames), into: result.mutableAudioBufferList)
        guard code == noErr else { throw JournalError("Cannot copy system audio sample (\(code))") }
        return result
    }
}
