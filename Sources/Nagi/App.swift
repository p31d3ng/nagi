import AVFoundation
import AppKit
import IOKit.pwr_mgt
import JournalCore
import SwiftUI

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    static var stop: (() -> Void)?
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Self.stop?()
        return .terminateNow
    }
}
@MainActor final class PlaybackMeter: ObservableObject {
    @Published var position = 0.0
    @Published var session: String?
}
@MainActor final class CaptureMeter: ObservableObject {
    @Published var level = 0.0
    @Published var elapsed = 0
}
@MainActor final class Journal: ObservableObject {
    let meter = CaptureMeter()
    var level: Double {
        get { meter.level }
        set { meter.level = newValue }
    }
    var elapsed: Int {
        get { meter.elapsed }
        set { meter.elapsed = newValue }
    }
    @Published var speakerChoices: [String] = []
    @Published var recordingDetails = ""
    @Published var audioExpiry: Double?
    @Published var processingFailures: [String] = []
    @Published var sessions: [Session] = []
    @Published var selected: String?
    @Published var activeLiveSession: String?
    @Published var liveStatus = "Start recording explicitly to see a live conversation."
    @Published var liveMode = "balanced"
    @Published var liveRevision = 0
    @Published var savingMode = AudioSavingMode.speechOnly.rawValue
    @Published var savingSpeech = false
    @Published var playbackNotice = ""
    @Published var savingSummary = ""
    @Published var liveEngineActive = false
    @Published var liveCommitted = ""
    @Published var liveTentative = ""
    @Published var livePreviewOffset = -1.0
    var liveRequested = false
    private let liveFeed = LiveFeed()
    private var liveTranscriber: LiveTranscriber?

    @Published var segments: [Segment] = []
    @Published var devices: [InputDevice] = []
    @Published var inputUID = ""
    @Published var model = "unified"
    @Published var status = "Ready · choose an input"
    @Published var processing = "Idle · audio stays on this Mac"
    @Published var recording = false
    @Published var error: String?
    @Published var connectionPrompt = false
    @Published var query = ""
    @Published var speakerFilter = ""
    @Published var languageFilter = ""
    @Published var rulesText = ""
    @Published var preferredWords = ""
    @Published var keepAwake = false
    @Published var capEnabled = true
    @Published var capMegabytes = "500"
    @Published var profileReady = false
    @Published var enrollmentResult = ""
    @Published var enrollment = false
    @Published var playing = false
    let project: URL
    let store: Store
    let processor: Processor
    let summaries: SummaryController
    let syntheticMonitor =
        ProcessInfo.processInfo.environment["NAGI_SYNTHETIC_MONITOR"] == "1"
        || Bundle.main.object(forInfoDictionaryKey: "NagiSyntheticTest") as? Bool == true
    private var meterTimer: Timer?
    private let capture = Capture()
    private var writer: ChunkWriter?
    private var timer: Timer?
    private var sessionID: String?
    private var started = Date()
    private var assertion: IOPMAssertionID = 0
    private var previousDevices = Set<String>()
    private var lastMaintenance = Date()
    private var conversationPlayer: ConversationPlayback!
    @Published var playbackState: ConversationPlayback.State = .idle
    let playbackMeter = PlaybackMeter()
    @Published var playbackSession: String?
    init() {
        if let override = ProcessInfo.processInfo.environment["NAGI_PROJECT"] {
            project = URL(fileURLWithPath: override)
        } else if let resources = Bundle.main.resourceURL,
            FileManager.default.fileExists(
                atPath: resources.appendingPathComponent("Runtime/bin/ASRWorker").path)
        {
            project = resources.appendingPathComponent("Runtime")
        } else {
            project = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        }
        let defaultData = FileManager.default
            .urls(
                for: .applicationSupportDirectory, in: .userDomainMask
            )
            .first!
            .appendingPathComponent("Nagi")
        let bundledTestData =
            Bundle.main.object(forInfoDictionaryKey: "NagiSyntheticData") as? String
        let data = URL(
            fileURLWithPath: ProcessInfo.processInfo.environment["NAGI_DATA"]
                ?? (syntheticMonitor
                    ? bundledTestData
                        ?? FileManager.default.temporaryDirectory
                        .appendingPathComponent(
                            "NagiSynthetic-" + UUID().uuidString
                        )
                        .path : defaultData.path))
        do {
            store = try Store(root: data)
            if !syntheticMonitor {
                try Archive.recover(store)
                try store.cleanup(
                    cap: Int(store.setting("cap", fallback: "500000000")) ?? 500_000_000)
            }
            processor = try Processor(store: store, project: project)
        } catch {
            fatalError(
                "Local store cannot open: \(error). Choose a writable NAGI_DATA folder.")
        }
        summaries = SummaryController(store: store, networkAllowed: !syntheticMonitor)
        conversationPlayer = ConversationPlayback(store: store)
        if syntheticMonitor { conversationPlayer.volume = 0 }
        conversationPlayer.onChange = { [weak self] in
            guard let self else { return }
            let state = self.conversationPlayer.state
            if self.playbackState != state { self.playbackState = state }
            let position = self.conversationPlayer.position
            if self.playbackMeter.position != position { self.playbackMeter.position = position }
            let session = self.conversationPlayer.session
            if self.playbackSession != session {
                self.playbackSession = session; self.playbackMeter.session = session
            }
            let active = [.playing, .preparing, .paused].contains(state)
            if self.playing != active { self.playing = active }
        }
        conversationPlayer.onMessage = { [weak self] message in self?.error = message }
        conversationPlayer.onSkippedSilence = { [weak self] message in
            self?.playbackNotice = message
        }
        savingMode = store.setting("saving-mode", fallback: AudioSavingMode.speechOnly.rawValue)
        liveMode = store.setting("live-mode", fallback: "balanced")
        inputUID = store.setting("inputUID")
        model = store.setting("model", fallback: "unified")
        preferredWords = store.setting("preferredWords")
        keepAwake = store.setting("keepAwake") == "true"
        capEnabled = store.setting("cap", fallback: "500000000") != "0"
        let storedCap = Int(store.setting("cap", fallback: "500000000")) ?? 500_000_000
        capMegabytes = store.setting(
            "cap-limit-mb", fallback: storedCap > 0 ? String(max(1, storedCap / 1_000_000)) : "500")
        if let data = store.setting("rules").data(using: .utf8),
            let rules = try? JSONDecoder().decode([Replacement].self, from: data)
        {
            rulesText = rules.map { $0.from + " => " + $0.to }.joined(separator: "\n")
        }
        devices = Devices.inputs()
        previousDevices = Set(devices.map(\.id))
        refresh()
        processor.onStatus = { [weak self] status in
            DispatchQueue.main.async {
                guard let self else { return }
                self.processing = status
                if status.hasPrefix("Idle"), !self.recording, !self.playing,
                    self.status.hasPrefix("Imported")
                {
                    let failures =
                        ((try? self.store.chunks(status: "failed", limit: 1).isEmpty) == false)
                        || ((try? self.store.chunks(status: "needs_speakers", limit: 1).isEmpty)
                            == false)
                    self.status =
                        failures
                        ? "Ready · processing needs review" : "Ready · local processing complete"
                }
            }
        }
        processor.onChange = { [weak self] in
            DispatchQueue.main.async {
                self?.refresh()
                self?.liveRevision += 1
            }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.stop(note: "System sleep gap. Resume explicitly after wake.")
            }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.stopPlayback()
                self?.processor.maintenance()
                self?.status = "Awake · recording needs an explicit start"
            }
        }
        NotificationCenter.default.addObserver(
            forName: Notification.Name("NagiQuit"), object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.stop(note: "App quit") } }
        AppDelegate.stop = { [weak self] in self?.stop(note: "App quit") }
        if syntheticMonitor {
            status = "Synthetic test monitor · no microphone"
            meterTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) {
                [weak self] _ in
                Task { @MainActor in
                    guard let self, self.recording else { return }
                    self.level = 0.2 + 0.05 * sin(Date().timeIntervalSince1970)
                }
            }
        } else {
            processor.schedule()
        }
    }
    func refresh() {
        do {
            let nextSessions = try store.sessions()
            let nextSegments = try store.segments(
                session: query.isEmpty ? selected : nil, query: query, speaker: speakerFilter,
                language: languageFilter)
            if sessions != nextSessions { sessions = nextSessions }
            if segments != nextSegments { segments = nextSegments }
            let ready =
                !(try store.exec(
                    "SELECT id FROM profiles WHERE id='Me' AND model=?", [Enrollment.model]))
                .isEmpty
            if profileReady != ready { profileReady = ready }
            let result = store.setting("enrollment-result")
            if enrollmentResult != result { enrollmentResult = result }
            let choices = Array(Set((try store.segments(session: selected)).map(\.speaker)))
                .sorted()
            if speakerChoices != choices { speakerChoices = choices }
            if let selected {
                let omitted =
                    Double(
                        try store
                            .exec(
                                "SELECT COALESCE(SUM(end-start),0) AS duration FROM audio_gaps WHERE session=? AND reason='omitted_nonspeech'",
                                [selected]
                            )
                            .first?["duration"] ?? "0") ?? 0
                savingSummary =
                    store.setting("saving-" + selected) == "speechOnly"
                    ? "Speech-only audio · \(Int(omitted)) seconds of non-speech omitted · original elapsed timestamps"
                    : "Continuous audio"
                recordingDetails =
                    store.setting("metadata-" + selected) + "\n"
                    + store.setting("format-" + selected) + "\n" + store.setting("live-" + selected)
                audioExpiry = try store
                    .exec(
                        "SELECT MIN(captured) AS first FROM chunks WHERE session=? AND path!='' AND captured>?",
                        [selected, Date().timeIntervalSince1970 - 172800]
                    )
                    .first?["first"]
                    .flatMap(Double.init).map { $0 + 172800 }
                processingFailures =
                    try store.exec(
                        "SELECT error FROM chunks WHERE session=? AND status IN ('failed','needs_speakers') ORDER BY offset LIMIT 20",
                        [selected]
                    )
                    .compactMap { $0["error"] }
            } else {
                recordingDetails = ""
                audioExpiry = nil
                processingFailures = []
            }
            summaries.observe(selected: selected)
        } catch { self.error = error.localizedDescription }
    }
    func tick() {
        if syntheticMonitor {
            let active =
                try? store.exec(
                    "SELECT id,started,status FROM sessions ORDER BY started DESC LIMIT 1"
                )
                .first
            if let active {
                if selected != active["id"] { selected = active["id"] }
                let activeRecording = active["status"] == "recording"
                if recording != activeRecording { recording = activeRecording }
                elapsed = Int(
                    Date().timeIntervalSince1970 - (Double(active["started"] ?? "0") ?? 0))
            }
            refresh()
            processing =
                "Synthetic pipeline · \((try? store.exec("SELECT COUNT(*) AS n FROM chunks WHERE status='queued'").first?["n"]) ?? "0") queued"
            return
        }
        if Date().timeIntervalSince(lastMaintenance) >= 60 {
            lastMaintenance = Date()
            processor.maintenance()
        }
        if liveTranscriber != nil, let id = sessionID {
            let queued =
                (try? store
                    .exec(
                        "SELECT COUNT(*) AS n FROM chunks WHERE session=? AND status='queued'", [id]
                    )
                    .first?["n"]) ?? "0"
            processing = "Live preview · \(queued) chunks await final alignment and speakers"
        }
        if !recording, liveTranscriber == nil, let id = activeLiveSession {
            let pending =
                (try? store
                    .exec(
                        "SELECT COUNT(*) AS n FROM chunks WHERE session=? AND status IN ('queued','processing','needs_speakers','failed')",
                        [id]
                    )
                    .first?["n"]) ?? "0"
            liveStatus =
                pending == "0"
                ? "Saved transcript · final processing complete"
                : "Recording saved · \(pending) chunks need final processing; see Timeline for failures"
        }
        let current = Devices.inputs()
        let ids = Set(current.map(\.id))
        if devices != current { devices = current }
        if recording && !ids.contains(inputUID) {
            stop(note: "Selected receiver disappeared. No fallback microphone was used.")
            error =
                "Selected input disconnected. Your recorded chunks are saved. Reconnect it and start a new session."
        }
        if !recording, !inputUID.isEmpty, ids.contains(inputUID),
            !previousDevices.contains(inputUID)
        {
            connectionPrompt = true
            status = "Selected input connected · ready to start"
        }
        previousDevices = ids
        if recording {
            elapsed = Int(Date().timeIntervalSince(started))
            if elapsed >= 5, let writer, writer.writtenDuration == 0 {
                let message =
                    "The selected input delivered no audio frames. Check receiver connection and input levels, then start again."
                stop(note: message)
                error = message
            } else if enrollment && elapsed >= 20 {
                stop(note: "Voice enrollment sample")
            }
        }

    }
    func saveSettings() {
        guard !syntheticMonitor else {
            error =
                "Settings are read-only in the isolated synthetic test. Open normal Nagi to configure your journal."
            return
        }
        do {
            guard !recording else {
                throw JournalError("Stop recording before changing input or model settings.")
            }
            let cap = capEnabled ? try TranscriptCapacity.bytes(megabytes: capMegabytes) : 0
            try store.set(
                "cap-limit-mb",
                (try? TranscriptCapacity.bytes(megabytes: capMegabytes)) != nil
                    ? capMegabytes : store.setting("cap-limit-mb", fallback: "500"))
            try store.set("inputUID", inputUID)
            try store.set("model", model)
            try store.set("keepAwake", String(keepAwake))
            try store.set("preferredWords", preferredWords)
            try store.set("cap", String(cap))
            let rules = rulesText.split(separator: "\n")
                .compactMap { line -> Replacement? in
                    let parts = line.components(separatedBy: " => ")
                    guard parts.count == 2, !parts[0].isEmpty else { return nil }
                    return Replacement(from: parts[0], to: parts[1])
                }
            try store.set("rules", String(data: try JSONEncoder().encode(rules), encoding: .utf8)!)
            status = "Settings saved locally"
            processor.maintenance()
        } catch { self.error = error.localizedDescription }
    }
    func saveLiveMode() {
        guard !recording, LiveResponsiveness(rawValue: liveMode) != nil else { return }
        do { try store.set("live-mode", liveMode) } catch {
            self.error = error.localizedDescription
        }
    }
    func saveSavingMode() {
        guard !recording, AudioSavingMode(rawValue: savingMode) != nil else { return }
        do { try store.set("saving-mode", savingMode) } catch {
            self.error = error.localizedDescription
        }
    }
    func chooseLive() {
        liveRequested = true
        ensureLive()
    }
    private func ensureLive() {
        guard recording, !enrollment, let id = sessionID, liveTranscriber == nil else { return }
        guard model == "unified" else {
            liveStatus =
                "Multilingual model · completed chunk updates; incremental preview is English only."
            return
        }
        startLive(for: id)
    }
    private func startLive(for id: String) {
        let live = LiveTranscriber(
            store: store, session: id, project: project,
            responsiveness: LiveResponsiveness(rawValue: liveMode) ?? .balanced)
        try? store.set(
            "live-" + id,
            "preview=Unified English;responsiveness=\(liveMode);engine=5d66f602;Metal;threads=2;window=30s;commit=AUTO;bounded-feed=64;final=archival pipeline after preview exits"
        )
        liveTranscriber = live
        liveEngineActive = true
        liveFeed.set(live)
        liveStatus = "Waiting for current processing job · audio continues saving"
        live.onStatus = { [weak self, weak live] message in
            DispatchQueue.main.async {
                guard let self, self.liveTranscriber === live else { return }
                self.liveStatus = message
            }
        }
        live.onUpdate = { [weak self, weak live] snapshot in
            guard let offset = snapshot.offset else { return }
            DispatchQueue.main.async {
                guard let self, self.liveTranscriber === live else { return }
                self.livePreviewOffset = offset
                self.liveCommitted =
                    snapshot.final == true ? snapshot.full ?? "" : snapshot.committed ?? ""
                self.liveTentative = snapshot.final == true ? "" : snapshot.tentative ?? ""
                self.liveRevision += 1
            }
        }
        live.onFinished = { [weak self, weak live] in
            DispatchQueue.main.async {
                guard let self, self.liveTranscriber === live else { return }
                self.liveFeed.set(nil)
                self.liveTranscriber = nil
                self.liveEngineActive = false
                self.livePreviewOffset = -1
                self.liveCommitted = ""
                self.liveTentative = ""
                self.processor.resumeBatch()
                self.refresh()
                self.liveRevision += 1
            }
        }
        processor.prepareLive { live.start() }
    }
    func start(enroll: Bool = false) {
        guard recording || liveTranscriber == nil else {
            error =
                "Finishing the previous live preview. Please wait a moment before starting again."
            return
        }
        guard !syntheticMonitor else {
            error =
                "This is the synthetic soak test window. Recording controls are disabled, and no microphone is opened. Launch normal Nagi with scripts/run-normal.sh to record explicitly in your regular journal. The test will keep running separately."
            return
        }
        guard !recording else { return }
        guard let device = devices.first(where: { $0.id == inputUID }) else {
            error =
                "Choose a connected input device in Devices. Recording never falls back to another microphone."
            return
        }
        enrollment = enroll
        let begin = { [weak self] in
            Task { @MainActor in self?.begin(device: device, enroll: enroll) }
        }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: begin()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] allowed in
                if allowed {
                    begin()
                } else {
                    DispatchQueue.main.async {
                        self?.error =
                            "Microphone permission was declined. Enable Nagi in System Settings → Privacy & Security → Microphone, then try again."
                    }
                }
            }
        default:
            error =
                "Microphone access is unavailable. Enable Nagi in System Settings → Privacy & Security → Microphone."
        }
    }
    private func begin(device: InputDevice, enroll: Bool) {
        stopPlayback()
        do {
            let speechOnly = !enroll && savingMode == AudioSavingMode.speechOnly.rawValue
            let detector = speechOnly ? try SpeechVAD(project: project) : nil
            started = Date()
            let id = try store.createSession(
                title: enroll
                    ? "Voice profile enrollment"
                    : "Conversation · " + Date().formatted(date: .abbreviated, time: .shortened),
                device: device.name + " | " + device.id, model: model)
            try store.set(
                "metadata-" + id,
                "engine=5d66f602;model=\(Models.all.first{$0.id==model}!.revision);threads=2;backend=metal;capture=original-rate CAF + gzip;vad=RMS 0.0001;language=script estimate;preferred=\(preferredWords);rules=\(store.setting("rules"));diarization=Community1/fc8c3e4 nonexclusive + precluster overlap; unified=streaming canonical / approximate offline times / 0.75s context / midpoint ownership; chunk=10s exact"
            )
            try store.set("rules-" + id, store.setting("rules", fallback: "[]"))
            if enroll {
                try store.set("enrollment-session", id)
                try store.set(
                    "enrollment-result", "Recording enrollment audio · profile is not saved yet")
            }
            let writer = ChunkWriter(store: store, session: id, model: model)
            if let detector { try writer.enableSpeechOnly(vad: detector) }
            try store.set("saving-" + id, speechOnly ? "speechOnly" : "continuous")
            try store.set(
                "metadata-" + id,
                store.setting("metadata-" + id)
                    + ";saving=\(speechOnly ? "speechOnly" : "continuous");capture-gate=\(speechOnly ? "Silero6.2CPU1thread threshold0.35/0.20 preroll1s postroll1s; offsets=elapsed" : "none")"
            )
            writer.onActivity = { [weak self] active in
                DispatchQueue.main.async {
                    guard let self, self.sessionID == id, self.recording else { return }
                    self.savingSpeech = active
                    self.status =
                        active
                        ? "Saving speech + short buffers · " + device.name
                        : "Listening · non-speech stays in memory only · " + device.name
                }
            }
            writer.onLevel = { [weak self] level in
                DispatchQueue.main.async { self?.level = min(1, level * 8) }
            }
            writer.onError = { [weak self] error in
                DispatchQueue.main.async {
                    self?.stop(note: "Capture gap: " + error)
                    self?.error = error
                }
            }
            writer.onChunk = { [weak self] in self?.processor.schedule() }
            let feed = liveFeed
            writer.onWritten = { buffer, offset in feed.offer(buffer, offset: offset) }
            writer.onSpanEnded = { _ in feed.endSpan() }
            self.writer = writer
            sessionID = id
            if liveRequested, !enroll, model == "unified" { startLive(for: id) }
            do { try capture.start(device: device, writer: writer) } catch {
                try store.finish(id, note: "Could not start: \(error.localizedDescription)")
                throw error
            }
            if !enroll { summaries.arm(session: id) }
            selected = id
            recording = true
            activeLiveSession = id
            enrollment = enroll
            if liveRequested { ensureLive() }
            elapsed = 0
            savingSpeech = !speechOnly
            status =
                speechOnly
                ? "Listening · speech-only saving · " + device.name
                : "Recording continuously · " + device.name
            if keepAwake {
                IOPMAssertionCreateWithName(
                    kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                    IOPMAssertionLevel(kIOPMAssertionLevelOn), "Nagi recording" as CFString,
                    &assertion)
            }
            refresh()
        } catch {
            try? capture.stop()
            liveFeed.set(nil)
            liveTranscriber?.stop()
            writer = nil
            sessionID = nil
            recording = false
            self.error = error.localizedDescription
            enrollment = false
        }
    }
    func stop(note: String = "") {
        guard !syntheticMonitor else { return }
        guard recording else { return }
        let wasEnrollment = enrollment
        var noSpeech = false
        recording = false
        enrollment = false
        do {
            try capture.stop()
            if let id = sessionID {
                let savedChunks = try store.chunks(session: id)
                noSpeech = store.setting("saving-" + id) == "speechOnly" && savedChunks.isEmpty
                try store.finish(
                    id,
                    note: note.isEmpty && noSpeech
                        ? "No speech detected; non-speech was omitted and no audio files were saved."
                        : note)
                if wasEnrollment {
                    try store.set(
                        "enrollment-result",
                        "Checking saved enrollment sample · wait for confirmation")
                    try Enrollment.finalize(store)
                    let captured = try store.chunks(session: id).reduce(0) { $0 + $1.duration }
                    if captured < 8 { self.error = store.setting("enrollment-result") }
                }
            }
        } catch {
            self.error = error.localizedDescription
            if let id = sessionID {
                try? store.finish(
                    id, note: "Capture finalization gap: " + error.localizedDescription)
            }
        }
        liveFeed.set(nil)
        liveTranscriber?.stop()
        liveStatus = "Recording saved · final alignment and speaker labels are processing"
        writer = nil
        sessionID = nil
        level = 0
        status =
            note.isEmpty
            ? (noSpeech
                ? "No speech detected · no audio files saved"
                : "Saved · ready for another conversation") : note
        if assertion != 0 {
            IOPMAssertionRelease(assertion)
            assertion = 0
        }
        processor.schedule()
        refresh()
    }
    func importAudio() {
        guard !syntheticMonitor else {
            error = "The synthetic test uses its generated fixture. Import files in normal Nagi."
            return
        }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard !recording else {
            error = "Finish recording before importing."
            return
        }
        status = "Importing audio locally…"
        let store = store
        let model = model
        DispatchQueue.global(qos: .utility)
            .async { [weak self] in
                do {
                    let id = try store.createSession(
                        title: url.deletingPathExtension().lastPathComponent,
                        device: "Imported local file",
                        model: model)
                    try store.set("rules-" + id, store.setting("rules", fallback: "[]"))
                    try store.set(
                        "metadata-" + id,
                        "Imported timestamp unknown; expiry starts at import. engine=5d66f602; model=\(model); threads=2; backend=Metal; sequential Community1 nonexclusive + precluster overlap; unified=streaming canonical / approximate offline times / 0.75s context; chunk=10s exact; rules=\(store.setting("rules"))"
                    )
                    let writer = ChunkWriter(store: store, session: id, model: model)
                    try writer.importFile(url)
                    try store.finish(id)
                    DispatchQueue.main.async {
                        self?.selected = id
                        self?.status = "Imported · queued for local processing"
                        self?.refresh()
                        self?.processor.schedule()
                    }
                } catch { DispatchQueue.main.async { self?.error = error.localizedDescription } }
            }
    }
    func play(_ segment: Segment) { playConversation(session: segment.session, at: segment.offset) }
    func playConversation(session: String, at offset: Double = 0) {
        guard !recording else { error = "Stop recording before playing saved audio."; return }
        playbackNotice = ""; conversationPlayer.start(session: session, at: offset)
    }
    func pausePlayback() { conversationPlayer.pause() }
    func resumePlayback() { conversationPlayer.resume() }
    func stopPlayback() { conversationPlayer?.stop(); playbackNotice = "" }
    func delete(_ session: Session) {
        guard !syntheticMonitor else { return }
        guard !recording else {
            error = "Finish recording before deleting a session."
            return
        }
        summaries.cancel(session: session.id)
        stopPlayback()
        status = "Deleting conversation…"
        let processor = processor
        let store = store
        DispatchQueue.global(qos: .utility)
            .async { [weak self] in
                processor.waitUntilIdle()
                do {
                    try store.deleteSession(session.id)
                    DispatchQueue.main.async {
                        if self?.selected == session.id { self?.selected = nil }
                        self?.status = "Conversation deleted"
                        self?.refresh()
                    }
                } catch { DispatchQueue.main.async { self?.error = error.localizedDescription } }
            }
    }
    func edit(_ segment: Segment, text: String, speaker: String) {
        guard !syntheticMonitor else { return }
        do {
            try store.edit(segment.id, text: text, speaker: speaker)
            refresh()
        } catch { self.error = error.localizedDescription }
    }
    func undo(_ segment: Segment) {
        guard !syntheticMonitor else { return }
        do {
            try store.undo(segment.id)
            refresh()
        } catch { self.error = error.localizedDescription }
    }
    func forgetProfile() {
        guard !syntheticMonitor else { return }
        do {
            try store.set("enrollment-finalized-session", store.setting("enrollment-session"))
            try store.set("enrollment-result", "Local voice profile deleted")
            try store.exec("DELETE FROM profiles")
            profileReady = false
        } catch { self.error = error.localizedDescription }
    }
}

@main struct NagiApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var journal = Journal()
    var body: some Scene {
        WindowGroup(journal.syntheticMonitor ? "Nagi · Synthetic soak test" : "Nagi", id: "journal")
        {
            ContentView().environmentObject(journal).frame(minWidth: 1000, minHeight: 690)
        }
        MenuBarExtra(
            "Nagi", systemImage: journal.recording ? "record.circle.fill" : "waveform.circle"
        ) { MenuView().environmentObject(journal) }
        Settings {
            PreferencesView().environmentObject(journal).frame(width: 660, height: 630).padding(24)
        }
    }
}
struct MenuView: View {
    @EnvironmentObject var journal: Journal
    @Environment(\.openWindow) var openWindow
    var body: some View {
        Text(journal.status)
        Text(journal.processing)
        Divider()
        Button("Open journal") {
            openWindow(id: "journal")
            NSApp.activate(ignoringOtherApps: true)
        }
        Button(journal.recording ? "Stop and save" : "Start recording") {
            journal.recording ? journal.stop() : journal.start()
        }
        .disabled(journal.syntheticMonitor)
        Divider()
        Button("Quit Nagi") {
            journal.stop(note: "App quit")
            NSApp.terminate(nil)
        }
    }
}
