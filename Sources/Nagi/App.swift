import AVFoundation
import AppKit
import IOKit.pwr_mgt
import JournalCore
import SwiftUI

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    static var stop: ((@escaping () -> Void) -> Void)?
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let stop = Self.stop else { return .terminateNow }
        stop { sender.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
}
@MainActor final class PlaybackMeter: ObservableObject {
    @Published var position = 0.0
    @Published var session: String?
}
@MainActor final class CaptureMeter: ObservableObject {
    @Published var level = 0.0
    @Published var elapsed = 0
    @Published var systemLevel = 0.0
}
@MainActor final class Journal: ObservableObject {
    let meter = CaptureMeter()
    let microphonePermission = MicrophonePermission()
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
    @Published var captureBusy = false
    @Published var captureStarting = false
    @Published var includeSystemAudio = false
    @Published var systemAudioPermitted = false
    var systemLevel: Double {
        get { meter.systemLevel }
        set { meter.systemLevel = newValue }
    }
    @Published var playbackOrigin: AudioOrigin = .legacy
    @Published var playbackSources: [AudioOrigin] = [.legacy]
    @Published var sourceNotices: [String] = []
    private var startTask: Task<Void, Never>?
    private let captureRun = CaptureRunState()
    private var systemCapture: SystemAudioCapture?
    private var systemWriter: ChunkWriter?
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
        includeSystemAudio = store.setting("system-audio") == "1"
        systemAudioPermitted = SystemAudioCapture.permitted()
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
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.microphonePermission.refresh(); self?.checkSystemAudioPermission()
            }
        }
        NotificationCenter.default.addObserver(
            forName: Notification.Name("NagiQuit"), object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.stop(note: "App quit") } }
        AppDelegate.stop = { [weak self] completion in
            self?.stop(note: "App quit")
            Task { @MainActor in
                let deadline = Date().addingTimeInterval(10)
                while self?.captureBusy == true && Date() < deadline {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
                completion()
            }
        }
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
                let sources =
                    try store.exec(
                        "SELECT DISTINCT COALESCE(s.origin,'legacy') AS origin FROM chunks c LEFT JOIN chunk_sources s ON s.chunk=c.id WHERE c.session=? ORDER BY origin",
                        [selected]
                    )
                    .compactMap { AudioOrigin(rawValue: $0["origin"] ?? "legacy") }
                if playbackSources != sources { playbackSources = sources }
                if !sources.contains(playbackOrigin) { playbackOrigin = sources.first ?? .legacy }
                let sourceRows = try store.exec(
                    "SELECT origin,status,detail FROM source_status WHERE session=? ORDER BY origin",
                    [selected])
                let gaps = try store.exec(
                    "SELECT origin,start,end,reason FROM source_gaps WHERE session=? ORDER BY start DESC LIMIT 5",
                    [selected])
                let notices =
                    sourceRows.map {
                        (AudioOrigin(rawValue: $0["origin"] ?? "legacy") ?? .legacy).title + " · "
                            + ($0["status"] ?? "unknown")
                            + ($0["detail"].flatMap { $0.isEmpty ? nil : " · " + $0 } ?? "")
                    }
                    + gaps.map {
                        (AudioOrigin(rawValue: $0["origin"] ?? "legacy") ?? .legacy).title
                            + " · gap "
                            + String(
                                format: "%.2f–%.2f s", Double($0["start"] ?? "0") ?? 0,
                                Double($0["end"] ?? "0") ?? 0) + " · " + ($0["reason"] ?? "unknown")
                    }
                if sourceNotices != notices { sourceNotices = notices }
                let omitted =
                    Double(
                        try store
                            .exec(
                                "SELECT COALESCE(SUM(end-start),0) AS duration FROM audio_gaps WHERE session=? AND reason='omitted_nonspeech'",
                                [selected]
                            )
                            .first?["duration"] ?? "0") ?? 0
                let nextSavingSummary =
                    store.setting("saving-" + selected) == "speechOnly"
                    ? "Speech-only audio · \(Int(omitted)) seconds of non-speech omitted · original elapsed timestamps"
                    : "Continuous audio"
                if savingSummary != nextSavingSummary { savingSummary = nextSavingSummary }
                let nextRecordingDetails =
                    store.setting("metadata-" + selected) + "\n"
                    + store.setting("format-" + selected) + "\n"
                    + store.setting("format-" + selected + "-system") + "\n"
                    + store.setting("live-" + selected)
                if recordingDetails != nextRecordingDetails {
                    recordingDetails = nextRecordingDetails
                }
                let nextExpiry = try store
                    .exec(
                        "SELECT MIN(captured) AS first FROM chunks WHERE session=? AND path!='' AND captured>?",
                        [selected, Date().timeIntervalSince1970 - 172800]
                    )
                    .first?["first"]
                    .flatMap(Double.init).map { $0 + 172800 }
                if audioExpiry != nextExpiry { audioExpiry = nextExpiry }
                let nextFailures =
                    try store.exec(
                        "SELECT error FROM chunks WHERE session=? AND status IN ('failed','needs_speakers') ORDER BY offset LIMIT 20",
                        [selected]
                    )
                    .compactMap { $0["error"] }
                if processingFailures != nextFailures { processingFailures = nextFailures }
            } else {
                if !recordingDetails.isEmpty { recordingDetails = "" }
                if audioExpiry != nil { audioExpiry = nil }
                if !processingFailures.isEmpty { processingFailures = [] }
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
                if activeRecording {
                    elapsed = Int(
                        Date().timeIntervalSince1970 - (Double(active["started"] ?? "0") ?? 0))
                }
            }
            refresh()
            let nextProcessing =
                "Synthetic pipeline · \((try? store.exec("SELECT COUNT(*) AS n FROM chunks WHERE status='queued'").first?["n"]) ?? "0") queued"
            if processing != nextProcessing { processing = nextProcessing }
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
    func selectInput(_ uid: String) {
        guard !captureBusy else {
            error = "Wait for capture startup/finalization before changing input."; return
        }
        guard !syntheticMonitor else { return }
        do {
            try InputSelection.persist(
                uid: uid, devices: devices, recording: recording, store: store)
            inputUID = uid
        } catch { self.error = error.localizedDescription }
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
        guard systemCapture == nil else { return }
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
    func saveSystemAudio() {
        guard !recording, !captureBusy else { return }
        do { try store.set("system-audio", includeSystemAudio ? "1" : "0") } catch {
            self.error = error.localizedDescription
        }
    }
    func checkSystemAudioPermission() { systemAudioPermitted = SystemAudioCapture.permitted() }
    func requestSystemAudioPermission() {
        guard !syntheticMonitor, !recording, !captureBusy else { return }
        systemAudioPermitted = SystemAudioCapture.requestPermission()
    }
    func start(enroll: Bool = false) {
        guard !captureBusy else {
            error = "Capture is starting or finalizing. Please wait, or cancel startup."; return
        }
        if includeSystemAudio && !enroll {
            checkSystemAudioPermission()
            guard systemAudioPermitted else {
                error =
                    "Request system audio access explicitly in Settings → Devices. Both sources remain stopped until permission is available.";
                return
            }
        }

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
                "Choose a connected input device in Settings → Devices. Recording never falls back to another microphone."
            return
        }
        microphonePermission.refresh()
        guard !microphonePermission.requesting else {
            error =
                "Waiting for the macOS microphone permission decision. Recording has not started."
            return
        }
        microphonePermission.request { [weak self] allowed in
            guard let self else { return }
            guard allowed else {
                self.error = self.microphonePermission.explanation
                return
            }
            // Device selection may change while the system permission dialog is open.
            guard !self.recording, self.inputUID == device.id,
                Devices.inputs().contains(where: { $0.id == device.id })
            else {
                self.error =
                    "Selected input changed or disconnected. Select it in Settings → Devices and start again."
                return
            }
            self.startTask = Task { await self.begin(device: device, enroll: enroll) }
        }
    }

    private func begin(device: InputDevice, enroll: Bool) async {
        guard !captureBusy, !recording else { return }
        captureBusy = true; captureStarting = true
        let run = captureRun.begin()
        defer { captureBusy = false; captureStarting = false; startTask = nil }
        stopPlayback()
        let dual = includeSystemAudio && !enroll
        let stream = dual ? SystemAudioCapture() : nil
        status = dual ? "Preparing microphone + system audio…" : "Preparing microphone…"
        do {
            if let stream { try await stream.prepare() }
            try Task.checkCancellation()
            guard inputUID == device.id, Devices.inputs().contains(where: { $0.id == device.id })
            else {
                throw JournalError(
                    "Selected microphone changed or disappeared during startup. Nothing will fall back."
                )
            }
            let speechOnly = !dual && !enroll && savingMode == AudioSavingMode.speechOnly.rawValue
            let detector = speechOnly ? try SpeechVAD(project: project) : nil
            let anchor = dual ? AVAudioTime.seconds(forHostTime: mach_absolute_time()) : nil
            started = Date()
            let id = try store.createSession(
                title: enroll
                    ? "Voice profile enrollment"
                    : "Conversation · " + Date().formatted(date: .abbreviated, time: .shortened),
                device: device.name + " | " + device.id, model: model,
                at: started.timeIntervalSince1970)
            sessionID = id
            captureRun.bind(run, session: id, source: stream)
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
            let writer = ChunkWriter(
                store: store, session: id, model: model, started: started.timeIntervalSince1970,
                origin: .microphone, hostAnchor: anchor)
            try AudioSources.status(store, session: id, origin: .microphone, status: "preparing")
            if let stream {
                let system = ChunkWriter(
                    store: store, session: id, model: model, started: started.timeIntervalSince1970,
                    origin: .system, hostAnchor: anchor)
                system.onChunk = { [weak self] in self?.processor.schedule() }
                system.onLevel = { [weak self] level in
                    DispatchQueue.main.async {
                        if let self, self.sessionID == id { self.systemLevel = min(1, level * 8) }
                    }
                }
                system.onError = { [weak self, weak stream] message in
                    DispatchQueue.main.async {
                        guard let self, let stream, self.sessionID == id,
                            self.systemCapture === stream,
                            self.captureRun.fail(run, session: id, source: stream, message: message)
                        else { return }
                        self.error = message
                        self.stop(note: "System source gap: " + message)
                    }
                }
                stream.onError = system.onError
                systemWriter = system; systemCapture = stream
                try AudioSources.status(
                    store, session: id, origin: .system, status: "preparing",
                    detail: "SCK 48 kHz stereo; own process excluded; no screen pixels; continuous")
                try store.set(
                    "metadata-" + id,
                    store.setting("metadata-" + id)
                        + ";sources=microphone+system;clock=host/arrival-fallback;echo=evidence-only;continuous-override=true"
                )
            }
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
                    guard let self, self.sessionID == id,
                        self.captureRun.fail(run, session: id, message: error)
                    else { return }
                    self.stop(note: "Capture gap: " + error)
                    self.error = error
                }
            }
            writer.onChunk = { [weak self] in self?.processor.schedule() }
            let feed = liveFeed
            writer.onWritten = { buffer, offset in feed.offer(buffer, offset: offset) }
            writer.onSpanEnded = { _ in feed.endSpan() }
            self.writer = writer
            sessionID = id
            if liveRequested, !enroll, !dual, model == "unified" { startLive(for: id) }
            do {
                if let stream, let systemWriter { try await stream.start(writer: systemWriter) }
                try Task.checkCancellation()
                guard inputUID == device.id else {
                    throw JournalError("Selected microphone changed during startup")
                }
                try capture.start(device: device, writer: writer)
                try AudioSources.status(
                    store, session: id, origin: .microphone, status: "recording")
                if dual {
                    try AudioSources.status(
                        store, session: id, origin: .system, status: "recording")
                }
            } catch {
                try store.finish(id, note: "Could not start: \(error.localizedDescription)")
                throw error
            }
            if !enroll { summaries.arm(session: id) }
            selected = id
            recording = true
            activeLiveSession = id
            enrollment = enroll
            if liveRequested && !dual { ensureLive() }
            elapsed = 0
            savingSpeech = !speechOnly
            status =
                dual
                ? "Recording continuously · microphone + system audio"
                : speechOnly
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
            var outcome = captureRun.outcome(run, error: error)
            captureRun.end(run)
            stream?.close()
            do { try capture.stop() } catch { outcome = outcome.preservingFailure(error) }
            do { try writer?.finish() } catch { outcome = outcome.preservingFailure(error) }
            do { try systemWriter?.finish() } catch { outcome = outcome.preservingFailure(error) }
            let sourceStatus = outcome == .cancelled ? "cancelled" : "failed"
            if let id = sessionID {
                try? store.finish(
                    id, note: outcome.message)
                try? AudioSources.status(
                    store, session: id, origin: .microphone, status: sourceStatus,
                    detail: outcome.message)
                if dual {
                    try? AudioSources.status(
                        store, session: id, origin: .system, status: sourceStatus,
                        detail: outcome.message)
                }
            }
            await stream?.stop()
            systemCapture = nil; systemWriter = nil; systemLevel = 0
            processor.schedule()
            liveFeed.set(nil)
            liveTranscriber?.stop()
            writer = nil
            sessionID = nil
            recording = false
            switch outcome {
            case .cancelled:
                self.error = nil
                status = outcome.message
            case .failed(let message):
                self.error = message
                status = "Capture startup failed · " + message
            }
            enrollment = false
        }
    }
    func stop(note: String = "") {
        guard !syntheticMonitor else { return }
        guard recording else {
            if captureBusy {
                startTask?.cancel()
                systemCapture?.close()
                status =
                    captureRun.hasFailure
                    ? "Capture startup failed · finalizing accepted audio…"
                    : "Cancelling capture startup…"
            }
            return
        }
        captureRun.end()
        let stream = systemCapture
        stream?.close()
        let system = systemWriter
        systemCapture = nil; systemWriter = nil; systemLevel = 0
        if let stream {
            captureBusy = true
            Task {
                await stream.stop(); self.captureBusy = false
            }
        }
        let wasEnrollment = enrollment
        var noSpeech = false
        recording = false
        enrollment = false
        do {
            var captureError: Error?
            do { try capture.stop() } catch { captureError = error }
            do { try system?.finish() } catch { if captureError == nil { captureError = error } }
            if let captureError { throw captureError }
            if let id = sessionID {
                try AudioSources.status(
                    store, session: id, origin: .microphone, status: "finished", detail: note)
                if let system {
                    try AudioSources.status(
                        store, session: id, origin: .system, status: "finished", detail: note)
                    let end = Date().timeIntervalSince(started)
                    if let writer, end - writer.writtenDuration > 0.02 {
                        try AudioSources.gap(
                            store, session: id, origin: .microphone, start: writer.writtenDuration,
                            end: end, reason: note.isEmpty ? "no_samples_before_stop" : note)
                    }
                    if end - system.writtenDuration > 0.02 {
                        try AudioSources.gap(
                            store, session: id, origin: .system, start: system.writtenDuration,
                            end: end, reason: "no_samples_before_stop")
                    }
                }
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
                try? AudioSources.status(
                    store, session: id, origin: .microphone, status: "failed",
                    detail: error.localizedDescription)
                if system != nil {
                    try? AudioSources.status(
                        store, session: id, origin: .system, status: "failed",
                        detail: error.localizedDescription)
                }
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
                    let writer = ChunkWriter(store: store, session: id, model: model, origin: .file)
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
    func play(_ segment: Segment) {
        playConversation(session: segment.session, at: segment.offset, origin: segment.origin)
    }
    func playConversation(session: String, at offset: Double = 0, origin: AudioOrigin? = nil) {
        guard !recording, !captureBusy else {
            error = "Stop recording before playing saved audio."; return
        }
        let source = origin ?? playbackOrigin
        playbackOrigin = source
        let firstOffset =
            (try? AudioSources.firstOffset(store, session: session, origin: source)) ?? 0
        let begin = offset == 0 ? firstOffset : offset
        playbackNotice =
            source.title
            + (begin > offset
                ? " · starts at first saved span (\(String(format: "%.2f", begin)) s); initial capture gap"
                : "")
        conversationPlayer.start(session: session, at: begin, origin: source)
    }
    func playSummarySource(session: String, source: SummarySource) {
        // The wire ID stays unchanged. Local source ownership is resolved from that segment.
        let segmentID = Int(source.segmentId.dropFirst()) ?? -1
        let chunk =
            (try? store
                .exec("SELECT chunk FROM segments WHERE id=? AND session=?", [segmentID, session])
                .first?["chunk"]) ?? ""
        playConversation(
            session: session, at: source.start, origin: AudioSources.origin(store, chunk: chunk))
    }
    func dismissEcho(_ segment: Segment, dismissed: Bool) {
        do {
            try AudioSources.dismissEcho(store, chunk: segment.chunk, dismissed: dismissed);
            refresh()
        } catch { self.error = error.localizedDescription }
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
            PreferencesView().environmentObject(journal)
                .background(SettingsWindowSizing().frame(width: 0, height: 0))
                .frame(minWidth: 660, idealWidth: 900, minHeight: 630, idealHeight: 700)
        }
        .windowResizability(.contentMinSize)
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
        Button(
            journal.recording
                ? "Stop and save"
                : journal.captureBusy
                    ? (journal.captureStarting ? "Cancel startup" : "Finalizing…")
                    : "Start recording"
        ) {
            (journal.recording || journal.captureBusy) ? journal.stop() : journal.start()
        }
        .disabled(journal.syntheticMonitor || (journal.captureBusy && !journal.captureStarting))
        Divider()
        Button("Quit Nagi") {
            journal.stop(note: "App quit")
            NSApp.terminate(nil)
        }
    }
}

// Settings scenes can retain a non-resizable AppKit style despite flexible SwiftUI bounds.
// Limit this adjustment to the view's own Settings window, never another app/window.
private struct SettingsWindowSizing: NSViewRepresentable {
    final class Host: NSView {
        private var fixtureApplied = false
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            configureWindow()
        }
        func configureWindow() {
            DispatchQueue.main.async { [weak self] in
                guard let self, let window = self.window else { return }
                if !window.styleMask.contains(.resizable) { window.styleMask.insert(.resizable) }
                let minimum = NSSize(width: 660, height: 630)
                if window.contentMinSize != minimum { window.contentMinSize = minimum }
                if window.contentMaxSize.width < 100_000 || window.contentMaxSize.height < 100_000 {
                    window.contentMaxSize = NSSize(width: 100_000, height: 100_000)
                }
                if window.toolbarStyle != .unifiedCompact { window.toolbarStyle = .unifiedCompact }
                if let toolbar = window.toolbar, toolbar.centeredItemIdentifiers != [] {
                    toolbar.centeredItemIdentifiers = []
                }
                // Deterministic geometry fixtures only in recording/network-disabled test mode.
                let env = ProcessInfo.processInfo.environment
                if !self.fixtureApplied, env["NAGI_SYNTHETIC_MONITOR"] == "1",
                    let value = env["NAGI_SETTINGS_TEST_WIDTH"], let width = Double(value),
                    (660...2000).contains(width)
                {
                    self.fixtureApplied = true
                    window.setContentSize(NSSize(width: width, height: 700))
                }
            }
        }
    }
    func makeNSView(context: Context) -> NSView { Host() }
    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? Host)?.configureWindow()
    }
}
