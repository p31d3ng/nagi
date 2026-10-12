import AVFoundation
import Foundation

public enum LiveResponsiveness: String, CaseIterable, Sendable {
    case balanced, accuracy
}
public struct LiveSnapshot: Codable, Sendable {
    public let ready: Bool?
    public let offset: Double?
    public let duration: Double?
    public let full: String?
    public let committed: String?
    public let tentative: String?
    public let final: Bool?
}
public struct LiveParagraph: Identifiable, Equatable, Sendable {
    public let id: String
    public let offset: Double
    public let text: String
    public let detail: String
}
public enum LiveDocument {
    public static func page(
        _ store: Store, session: String, before: Double = .greatestFiniteMagnitude,
        limit: Int = 200
    ) throws -> [LiveParagraph] {
        let limit = max(1, min(200, limit))
        // A preview is replaced only when every overlapping archival chunk has finished.
        // Saved text/corrections are never overwritten by a preview.
        try store.exec(
            """
            DELETE FROM live_previews WHERE session=? AND final=1
            AND EXISTS(SELECT 1 FROM chunks WHERE chunks.session=live_previews.session
                AND chunks.offset < live_previews.offset+live_previews.duration
                AND chunks.offset+chunks.duration > live_previews.offset)
            AND NOT EXISTS(SELECT 1 FROM chunks WHERE chunks.session=live_previews.session
                AND chunks.offset < live_previews.offset+live_previews.duration
                AND chunks.offset+chunks.duration > live_previews.offset
                AND chunks.status != 'done')
            """, [session])
        let rows = try store.exec(
            """
            SELECT * FROM (
                SELECT 's-'||segments.id AS id,segments.offset,corrected AS text,
                    speaker||' · '||language||' · '||COALESCE((SELECT CASE origin WHEN 'microphone' THEN 'Microphone' WHEN 'system' THEN 'System audio' WHEN 'file' THEN 'Imported audio' ELSE 'Original audio' END FROM chunk_sources WHERE chunk=segments.chunk),'Original audio') AS detail FROM segments WHERE session=?
                    AND NOT EXISTS(SELECT 1 FROM live_previews p WHERE p.session=segments.session
                        AND segments.offset < p.offset+p.duration AND segments.end > p.offset)
                UNION ALL
                SELECT 'p-'||offset AS id,offset,text,
                    CASE WHEN EXISTS(SELECT 1 FROM chunks c WHERE c.session=live_previews.session AND c.status='expired' AND c.offset<live_previews.offset+live_previews.duration AND c.offset+c.duration>live_previews.offset) THEN 'Preview · audio expired; final alignment unavailable'
                    WHEN final=1 THEN 'Preview · speaker pending · saved alignment pending'
                    ELSE 'Live preview · tentative words may change · speaker pending' END AS detail
                    FROM live_previews WHERE session=?
            ) WHERE offset < ? ORDER BY offset DESC LIMIT ?
            """, [session, session, before, limit])
        return rows.reversed()
            .map {
                LiveParagraph(
                    id: $0["id"]!, offset: Double($0["offset"]!)!, text: $0["text"] ?? "",
                    detail: $0["detail"] ?? "")
            }
    }
}

/// One network-denied model process; at most 64 immutable source buffers await conversion/writing.
/// Only a post-archive-write callback offers buffers. Live overload never stops archival capture.
public final class LiveTranscriber: @unchecked Sendable {
    private let lane = DispatchQueue(
        label: "nagi.live.feed", qos: .utility, autoreleaseFrequency: .workItem)
    private let lock = NSLock()
    private let slots = DispatchSemaphore(value: 64)
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let store: Store
    private let session: String
    private let project: URL
    private let responsiveness: LiveResponsiveness
    private var registeredWorker: UUID?
    public var workerPID: Int32 { process.isRunning ? process.processIdentifier : 0 }
    private enum Event { case audio(AVAudioPCMBuffer, Double), endSpan }
    private var preRoll: [Event] = []
    private var accepting = false
    private var stopped = false
    private var failed = false
    private var lastProgress = Date()
    private let readerLock = NSRecursiveLock()
    private var reader = Data()
    private var converter: AVAudioConverter?
    private var sourceRate: Double = 0
    private var previousInputEnd: Double?
    private var lastInput = Date()
    private var logURL: URL?
    private var log: FileHandle?
    private var watchdog: DispatchSourceTimer?
    public var onUpdate: ((LiveSnapshot) -> Void)?
    public var onStatus: ((String) -> Void)?
    public var onFinished: (() -> Void)?
    public init(
        store: Store, session: String, project: URL, responsiveness: LiveResponsiveness = .balanced
    ) {
        self.store = store; self.session = session; self.project = project
        self.responsiveness = responsiveness
    }
    public func start() {
        lane.async { [self] in
            lock.lock(); let canceled = stopped; lock.unlock()
            guard !canceled else { return }
            do {
                let model = project.appendingPathComponent(
                    "Models/" + Models.all.first { $0.id == "unified" }!.filename)
                guard FileManager.default.fileExists(atPath: model.path) else {
                    throw JournalError("Install the English Unified model first")
                }
                let logURL = store.root.appendingPathComponent(
                    "derived/live-\(UUID().uuidString).log")
                self.logURL = logURL
                FileManager.default.createFile(atPath: logURL.path, contents: nil)
                log = try FileHandle(forWritingTo: logURL)
                process.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
                process.arguments = [
                    "-p", "(version 1)(allow default)(deny network*)",
                    project.appendingPathComponent("bin/LiveASRWorker").path, model.path,
                    responsiveness.rawValue,
                ]
                process.qualityOfService = .utility
                process.standardInput = input; process.standardOutput = output;
                process.standardError = log
                output.fileHandleForReading.readabilityHandler = { [weak self] handle in
                    guard let self else { return }
                    self.readerLock.lock(); defer { self.readerLock.unlock() }
                    autoreleasepool {
                        let data = handle.availableData
                        self.receive(data)
                    }
                }
                process.terminationHandler = { [weak self] p in
                    guard let self else { return }
                    self.lock.lock(); let worker = self.registeredWorker;
                    self.registeredWorker = nil
                    let intentional = self.stopped; self.lock.unlock()
                    WorkerRegistry.shared.end(worker)
                    if !intentional || p.terminationStatus != 0 {
                        self.fail(
                            "Live worker exited; archival recording continues. Saved audio will be transcribed in chunks."
                        )
                    }
                }
                try process.run()
                lock.lock()
                registeredWorker = WorkerRegistry.shared.start(
                    pid: process.processIdentifier, role: .transcription)
                if !process.isRunning {
                    WorkerRegistry.shared.end(registeredWorker); registeredWorker = nil
                }
                lock.unlock()
                try? output.fileHandleForWriting.close()
                try? input.fileHandleForReading.close()
                let timer = DispatchSource.makeTimerSource(
                    queue: DispatchQueue.global(qos: .utility))
                timer.schedule(deadline: .now() + 5, repeating: 5)
                timer.setEventHandler { [weak self] in
                    guard let self else { return }
                    self.lock.lock();
                    let stale =
                        !self.stopped
                        && (!self.accepting || Date().timeIntervalSince(self.lastInput) < 3)
                        && Date().timeIntervalSince(self.lastProgress) > 45;
                    self.lock.unlock()
                    if stale {
                        self.fail(
                            "Live worker stalled; returning to chunk processing. Audio recording continues."
                        )
                    }
                }
                watchdog = timer; timer.resume()
                onStatus?("Warming English model · audio continues saving")
            } catch { fail(error.localizedDescription) }
        }
    }
    private func receive(_ data: Data) {
        // This handler runs on one Foundation pipe reader; bounded NDJSON snapshots only.
        guard !data.isEmpty else { return }
        readerLock.lock(); defer { readerLock.unlock() }
        reader.append(data)
        if reader.count > 262144 {
            fail("Oversized live response; returning to saved audio processing.");
            reader.removeAll(); return
        }
        while let end = reader.firstIndex(of: 10) {
            let line = reader.prefix(upTo: end); reader.removeSubrange(...end)
            do {
                let snapshot = try JSONDecoder().decode(LiveSnapshot.self, from: line)
                lock.lock(); lastProgress = Date()
                let becameReady = snapshot.ready == true && !stopped
                if becameReady {
                    accepting = true
                    for event in preRoll {
                        switch event {
                        case .audio(let buffer, let offset): queue(buffer, offset: offset)
                        case .endSpan: queueEnd()
                        }
                    }
                    preRoll.removeAll(keepingCapacity: false)
                }
                lock.unlock()
                if becameReady {
                    onStatus?("Live English preview · speaker labels follow after recording")
                }
                if let offset = snapshot.offset, let duration = snapshot.duration,
                    let full = snapshot.full
                {
                    guard full.utf8.count <= 65536 else {
                        throw JournalError("Live text exceeded its bounded window")
                    }
                    try store.exec(
                        "INSERT OR REPLACE INTO live_previews VALUES(?,?,?,?,?)",
                        [session, offset, duration, full, snapshot.final == true ? 1 : 0])
                }
                onUpdate?(snapshot)
            } catch { fail("Live response error: \(error.localizedDescription)") }
        }
    }
    public func offer(_ buffer: AVAudioPCMBuffer, offset: Double) {
        lock.lock()
        lastInput = Date()
        guard !stopped else { lock.unlock(); return }
        guard slots.wait(timeout: .now()) == .success else {
            lock.unlock()
            fail("Live preview fell behind; audio is safe. Returning to chunk processing.")
            return
        }
        if accepting {
            queue(buffer, offset: offset)
        } else {
            preRoll.append(.audio(buffer, offset))
        }
        lock.unlock()
    }
    public func endSpan() {
        lock.lock()
        guard !stopped else { lock.unlock(); return }
        guard slots.wait(timeout: .now()) == .success else {
            lock.unlock(); fail("Live preview fell behind while finalizing speech"); return
        }
        if accepting { queueEnd() } else { preRoll.append(.endSpan) }
        lock.unlock()
    }
    private func queueEnd() {
        lane.async { [self] in
            defer { slots.signal() }
            lock.lock(); let canceled = failed; lock.unlock(); guard !canceled else { return }
            do {
                var marker = UInt32.max
                try input.fileHandleForWriting.write(contentsOf: Data(bytes: &marker, count: 4))
                converter = nil; previousInputEnd = nil
            } catch { fail(error.localizedDescription) }
        }
    }
    private func queue(_ buffer: AVAudioPCMBuffer, offset: Double) {
        lane.async { [self] in
            defer { slots.signal() }
            lock.lock(); let canceled = failed; lock.unlock()
            guard !canceled else { return }
            do { try send(buffer, offset: offset) } catch { fail(error.localizedDescription) }
        }
    }
    private func send(_ buffer: AVAudioPCMBuffer, offset: Double) throws {
        if let end = previousInputEnd, abs(offset - end) > 0.01 { converter = nil }
        previousInputEnd = offset + Double(buffer.frameLength) / buffer.format.sampleRate
        guard let channels = buffer.floatChannelData else {
            throw JournalError("Live input requires Float32 audio")
        }
        let rate = buffer.format.sampleRate
        let mono = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
        let mixed = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: buffer.frameLength)!
        mixed.frameLength = buffer.frameLength
        for i in 0..<Int(buffer.frameLength) {
            var sum: Float = 0
            for channel in 0..<Int(buffer.format.channelCount) {
                sum +=
                    buffer.format.isInterleaved
                    ? channels[0][i * Int(buffer.format.channelCount) + channel]
                    : channels[channel][i]
            }
            mixed.floatChannelData![0][i] = sum / Float(buffer.format.channelCount)
        }
        if converter == nil || sourceRate != rate {
            converter = AVAudioConverter(
                from: mono, to: AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!)
            sourceRate = rate
        }
        let converted = AVAudioPCMBuffer(
            pcmFormat: converter!.outputFormat,
            frameCapacity: AVAudioFrameCount(ceil(Double(buffer.frameLength) * 16000 / rate) + 128))!
        var supplied = false
        var error: NSError?
        let result = converter!
            .convert(to: converted, error: &error) { _, status in
                if supplied { status.pointee = .noDataNow; return nil }
                supplied = true; status.pointee = .haveData; return mixed
            }
        if result == .error { throw error ?? JournalError("Live resampling failed") as NSError }
        if converted.frameLength == 0 { return }
        guard converted.frameLength <= 16384 else {
            throw JournalError("Live input buffer exceeds bounded packet size")
        }
        var count = UInt32(converted.frameLength)
        var position = offset
        var packet = Data(bytes: &count, count: 4)
        packet.append(Data(bytes: &position, count: 8))
        packet.append(Data(bytes: converted.floatChannelData![0], count: Int(count) * 4))
        try input.fileHandleForWriting.write(contentsOf: packet)
    }
    private func fail(_ message: String) {
        lock.lock(); guard !failed else { lock.unlock(); return }; failed = true; accepting = false;
        lock.unlock()
        onStatus?("\(message) · audio saving continues under the selected mode")
        stop()
    }
    public func stop() {
        lock.lock(); guard !stopped else { lock.unlock(); return }; stopped = true;
        accepting = false
        let unused = preRoll.count
        preRoll.removeAll(keepingCapacity: false)
        lock.unlock()
        for _ in 0..<unused { slots.signal() }
        watchdog?.cancel()
        // A blocked pipe write must not prevent timeout or capture. SIGTERM releases its queue.
        DispatchQueue.global(qos: .utility)
            .asyncAfter(deadline: .now() + 12) { [weak self] in
                guard let self, self.process.isRunning else { return }
                self.process.terminate()
                DispatchQueue.global(qos: .utility)
                    .asyncAfter(deadline: .now() + 1) { [weak self] in
                        guard let self, self.process.isRunning else { return };
                        kill(self.process.processIdentifier, SIGKILL)
                    }
            }
        lane.async { [self] in
            try? input.fileHandleForWriting.close()
            try? output.fileHandleForWriting.close()
            if process.isRunning { process.waitUntilExit() }
            lock.lock(); let worker = registeredWorker; registeredWorker = nil; lock.unlock()
            WorkerRegistry.shared.end(worker)
            output.fileHandleForReading.readabilityHandler = nil
            // Drain final NDJSON before releasing the model lease to batch ML.
            readerLock.lock()
            let remaining = output.fileHandleForReading.readDataToEndOfFile()
            receive(remaining)
            readerLock.unlock()
            try? log?.close(); log = nil
            if let logURL { try? FileManager.default.removeItem(at: logURL) }
            try? store.exec("UPDATE live_previews SET final=1 WHERE session=?", [session])
            onFinished?()
        }
    }
}

/// Routes post-write audio without involving the main thread or its event backlog.
public final class LiveFeed: @unchecked Sendable {
    private let lock = NSLock()
    private var target: LiveTranscriber?
    public init() {}
    public func set(_ target: LiveTranscriber?) {
        lock.lock(); self.target = target; lock.unlock()
    }
    public func offer(_ buffer: AVAudioPCMBuffer, offset: Double) {
        lock.lock(); let current = target; lock.unlock()
        current?.offer(buffer, offset: offset)
    }
    public func endSpan() { lock.lock(); let current = target; lock.unlock(); current?.endSpan() }
}
