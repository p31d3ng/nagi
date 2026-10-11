import AVFoundation
import Foundation

/// Plays continuous audio ranges, never transcript sentence boundaries. Two files at most.
@MainActor public final class ConversationPlayback: NSObject, AVAudioPlayerDelegate {
    public enum State: String { case idle, preparing, playing, paused, ended, unavailable }
    public private(set) var state: State = .idle
    public private(set) var session: String?
    public private(set) var position = 0.0
    public var onChange: (() -> Void)?
    public var onMessage: ((String) -> Void)?
    public var onSkippedSilence: ((String) -> Void)?
    public var volume: Float = 1
    private let store: Store
    private let lane = DispatchQueue(
        label: "nagi.conversation.playback", qos: .utility, autoreleaseFrequency: .workItem)
    private var generation = 0
    private var current: AVAudioPlayer?
    private var next: AVAudioPlayer?
    private var chunk: Chunk?
    private var nextChunk: Chunk?
    private var currentURL: URL?
    private var nextURL: URL?
    private var timer: Timer?
    private var loadingNext = false
    private var reachedEnd = false
    private var waitingBoundary = false
    public init(store: Store) { self.store = store; super.init() }
    public func start(session: String, at offset: Double = 0) {
        stop(); self.session = session; position = max(0, offset)
        state = .preparing; onChange?()
        prepare(at: position, initial: true)
    }
    private func remove(_ url: URL?) {
        if let url, url.path.contains("/derived/") { try? FileManager.default.removeItem(at: url) }
    }
    public func stop() {
        generation += 1
        timer?.invalidate(); timer = nil
        current?.stop(); next?.stop(); current = nil; next = nil
        remove(currentURL); remove(nextURL); currentURL = nil; nextURL = nil
        chunk = nil; nextChunk = nil; session = nil; position = 0
        state = .idle; loadingNext = false; reachedEnd = false; waitingBoundary = false
        onChange?()
    }
    public func pause() {
        guard state == .playing || state == .preparing else { return }
        if let chunk, let current { position = chunk.offset + current.currentTime }
        current?.pause(); next?.stop()
        if let next, let nextChunk, let chunk, let current {
            next.currentTime = max(0, chunk.offset + current.duration - nextChunk.offset)
        }
        state = .paused; onChange?()
    }
    public func resume() {
        guard state == .paused else { return }
        guard let current, let chunk else { state = .preparing; onChange?(); return }
        guard store.audioAvailable(chunk), nextChunk.map({ store.audioAvailable($0) }) ?? true
        else { unavailable("Audio has expired. Transcript remains."); return }
        current.volume = volume
        guard current.play() else { unavailable("Cannot resume saved audio."); return }
        state = .playing; scheduleNext(); onChange?()
    }
    public func seek(to offset: Double) {
        guard let session else { return }; start(session: session, at: offset)
    }
    private func prepare(at offset: Double, initial: Bool) {
        guard let session else { return }
        let token = generation
        if !initial { loadingNext = true }
        let store = store
        let excluded = initial ? "" : chunk?.id ?? ""
        lane.async { [weak self] in
            var url: URL?
            do {
                let row =
                    try store.exec(
                        "SELECT id FROM chunks WHERE session=? AND offset+duration>? AND id!=? ORDER BY offset LIMIT 1",
                        [session, offset + 0.000001, excluded]
                    )
                    .first
                guard let id = row?["id"], let item = try store.chunk(id) else {
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.generation == token else { return }
                        self.reachedEnd = true; self.loadingNext = false
                        if initial || self.waitingBoundary { self.finish() }
                    }; return
                }
                guard store.audioAvailable(item) else {
                    throw JournalError(
                        "Conversation audio is missing or expired at \(Int(item.offset)) seconds. Playback stopped; transcript remains."
                    )
                }
                if item.offset > offset + 0.02 {
                    if store.isOmittedSilence(session: session, start: offset, end: item.offset) {
                        DispatchQueue.main.async { [weak self] in
                            guard let self, self.generation == token else { return }
                            self.onSkippedSilence?(
                                "Skipped \(String(format: "%.1f", item.offset - offset)) seconds of omitted non-speech. Clock keeps original elapsed time."
                            )
                        }
                    } else {
                        throw JournalError(
                            "Recording gap before \(Int(item.offset)) seconds. Choose a later timestamp to continue; missing audio was not skipped silently."
                        )
                    }
                }
                url = try Archive.decompress(item, store: store)
                let preparedURL = url!
                let player = try AVAudioPlayer(contentsOf: preparedURL)
                guard abs(player.duration - item.duration) <= 0.002 else {
                    throw JournalError(
                        "Audio length differs from its saved range. Playback stopped to avoid skipping or repeating samples."
                    )
                }
                guard player.prepareToPlay() else {
                    throw JournalError("Cannot prepare this audio chunk")
                }
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.generation == token else {
                        if preparedURL.path.contains("/derived/") {
                            try? FileManager.default.removeItem(at: preparedURL)
                        }; return
                    }
                    guard store.audioAvailable(item) else {
                        self.remove(preparedURL);
                        self.unavailable("Audio expired during preparation. Transcript remains.");
                        return
                    }
                    player.volume = self.volume
                    if initial {
                        self.current = player; self.chunk = item; self.currentURL = preparedURL
                        player.delegate = self; player.currentTime = max(0, offset - item.offset)
                        if self.state != .paused {
                            guard player.play() else {
                                self.unavailable("Cannot play saved audio"); return
                            }
                            self.state = .playing
                        }
                        self.startTimer();
                        self.prepare(at: item.offset + item.duration, initial: false)
                    } else {
                        self.next = player; self.nextChunk = item; self.nextURL = preparedURL;
                        self.loadingNext = false
                        // Trim overlapping chunk metadata; transcript overlap never duplicates audio.
                        let boundary =
                            self.chunk.map { $0.offset + (self.current?.duration ?? $0.duration) }
                            ?? offset
                        player.currentTime = max(0, boundary - item.offset)
                        if self.waitingBoundary { self.advance() } else { self.scheduleNext() }
                    }
                    self.onChange?()
                }
            } catch {
                if let url, url.path.contains("/derived/") {
                    try? FileManager.default.removeItem(at: url)
                }
                let message = error.localizedDescription
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.generation == token else { return }
                    if initial {
                        self.unavailable(message)
                    } else {
                        self.loadingNext = false; self.reachedEnd = true;
                        self.onMessage?(
                            message + " Playback will stop at the current audio boundary.")
                        if self.waitingBoundary { self.finish() }
                    }
                }
            }
        }
    }
    private func scheduleNext() {
        guard state == .playing, let current, let next else { return }
        let remaining = max(0, current.duration - current.currentTime)
        if remaining > 0.02 { _ = next.play(atTime: current.deviceCurrentTime + remaining) }
    }
    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }
    private func tick() {
        guard let chunk, let current else { return }
        if !store.audioAvailable(chunk) || !(nextChunk.map { store.audioAvailable($0) } ?? true) {
            unavailable("Audio expired or was removed during playback. Transcript remains."); return
        }
        if state == .playing { position = chunk.offset + current.currentTime; onChange?() }
    }
    public nonisolated func audioPlayerDidFinishPlaying(
        _ player: AVAudioPlayer, successfully flag: Bool
    ) {
        Task { @MainActor [weak self, weak player] in
            guard let self, let player, self.current === player else { return }
            if !flag {
                self.unavailable("Audio playback was interrupted")
            } else if self.next != nil {
                self.advance()
            } else if self.reachedEnd {
                self.finish()
            } else {
                self.waitingBoundary = true; self.state = .preparing; self.onChange?()
            }
        }
    }
    private func advance() {
        guard let next, let nextChunk else { return }
        remove(currentURL)
        current = next; chunk = nextChunk; currentURL = nextURL
        self.next = nil; self.nextChunk = nil; nextURL = nil; waitingBoundary = false
        current?.delegate = self
        if state != .paused {
            if !next.isPlaying {
                guard next.play() else { unavailable("Cannot advance playback"); return }
            }
            state = .playing
        }
        position = nextChunk.offset + next.currentTime
        prepare(at: nextChunk.offset + nextChunk.duration, initial: false)
        onChange?()
    }
    private func finish() {
        let ending = chunk.map { $0.offset + (current?.duration ?? $0.duration) } ?? position
        stop(); position = ending; state = .ended; onChange?()
    }
    private func unavailable(_ message: String) {
        stop(); state = .unavailable; onMessage?(message); onChange?()
    }
}
