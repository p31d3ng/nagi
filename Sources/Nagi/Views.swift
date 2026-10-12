import JournalCore
import SwiftUI

struct ContentView: View {
    @EnvironmentObject var j: Journal
    @State private var section = "Timeline"
    @State private var sidebarVisibility: NavigationSplitViewVisibility = .all
    @State private var settingsPage = "Permissions"
    private let settingsPages = [
        "Permissions", "Summarization", "Devices", "Models", "Storage", "Voice profile",
        "Dictionary",
    ]
    @State private var editing: Segment?
    @State private var deleteCandidate: Session?
    let accent = Color(red: 0.17, green: 0.42, blue: 0.43)
    init(initialSection: String = "Timeline") {
        let main =
            ["Timeline", "Live", "Settings"].contains(initialSection) ? initialSection : "Settings"
        _section = State(initialValue: main)
        _settingsPage = State(initialValue: main == initialSection ? "Permissions" : initialSection)
    }
    var body: some View {
        NavigationSplitView(columnVisibility: $sidebarVisibility) {
            VStack(alignment: .leading, spacing: 24) {
                HStack {
                    Image(systemName: "waveform.circle.fill").font(.largeTitle)
                        .foregroundStyle(accent)
                    Text("Nagi").font(.title2.weight(.semibold))
                }
                .padding(.top, 18)
                Text("YOUR LOCAL VOICE JOURNAL").font(.caption2.weight(.semibold))
                    .foregroundStyle(
                        .secondary)
                ForEach(
                    ["Timeline", "Live", "Settings"],
                    id: \.self
                ) { name in
                    Button {
                        section = name
                    } label: {
                        Label(name, systemImage: icon(name))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                            .contentShape(Rectangle())
                            .background(
                                section == name ? accent.opacity(0.13) : .clear,
                                in: RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                    .allowsWindowActivationEvents(true)
                    .accessibilityAddTraits(section == name ? .isSelected : [])
                }
                Spacer()
                Text(AppVersion.current.sidebar).font(.caption).foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Label("Audio stays on this Mac", systemImage: "lock.shield").font(.callout)
                    .foregroundStyle(accent)
                Text(
                    "Audio: 48 hours\nTranscripts: until you delete them or reach your chosen cap."
                )
                .font(
                    .caption
                )
                .foregroundStyle(.secondary)
            }
            .padding(20).navigationSplitViewColumnWidth(220)
            .toolbar(removing: .sidebarToggle)
            .toolbar {
                if sidebarVisibility != .detailOnly {
                    ToolbarItem(placement: .navigation) { sidebarButton }
                }
            }
        } detail: {
            VStack(spacing: 0) {
                if j.syntheticMonitor {
                    Label(
                        "SYNTHETIC SOAK TEST · no microphone · isolated test data",
                        systemImage: "testtube.2"
                    )
                    .font(.headline).foregroundStyle(.orange).frame(maxWidth: .infinity).padding(12)
                    .background(.orange.opacity(0.1))
                }
                statusBar.padding(24).background(.background)
                Divider()
                if section == "Timeline" {
                    timeline
                } else if section == "Live" {
                    LiveView()
                } else {
                    ScrollView {
                        settingsSection.padding(32)
                            .frame(
                                maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
            .background(Color(nsColor: .windowBackgroundColor))
            .toolbar(removing: .sidebarToggle)
        }
        .toolbar(removing: .sidebarToggle)
        .toolbar {
            if sidebarVisibility == .detailOnly {
                ToolbarItem(placement: .navigation) { sidebarButton }
            }
        }
        .tint(accent)
        .onChange(of: section) { _, value in
            j.liveRequested = value == "Live"
            if value == "Live" { j.chooseLive() }
        }
        .alert(
            j.syntheticMonitor ? "Synthetic test mode" : "Needs attention",
            isPresented: Binding(get: { j.error != nil }, set: { if !$0 { j.error = nil } })
        ) {
            Button("OK") { j.error = nil }
        } message: {
            Text(j.error ?? "")
        }
        .alert("Your selected input is connected", isPresented: $j.connectionPrompt) {
            Button("Start recording") { j.start() }
            Button("Later", role: .cancel) {}
        } message: {
            Text(
                "Start a new conversation with this input? Recording begins only after you choose Start."
            )
        }
        .confirmationDialog(
            "Delete this conversation and its saved audio?",
            isPresented: Binding(
                get: { deleteCandidate != nil }, set: { if !$0 { deleteCandidate = nil } })
        ) {
            Button("Delete conversation", role: .destructive) {
                if let s = deleteCandidate { j.delete(s) }
                deleteCandidate = nil
            }
        } message: {
            Text("This also deletes its original and corrected transcript versions.")
        }
        .sheet(item: $editing) { segment in EditTranscript(segment: segment).environmentObject(j) }
    }
    private var sidebarButton: some View {
        Button {
            sidebarVisibility = sidebarVisibility == .detailOnly ? .all : .detailOnly
        } label: {
            Image(systemName: "sidebar.left")
        }
        .help(sidebarVisibility == .detailOnly ? "Show sidebar" : "Hide sidebar")
        .accessibilityLabel(sidebarVisibility == .detailOnly ? "Show sidebar" : "Hide sidebar")
    }
    func icon(_ name: String) -> String {
        switch name {
        case "Live": return "text.bubble"
        case "Devices": return "mic"
        case "Models": return "cpu"
        case "Voice profile": return "person.crop.circle"
        case "Dictionary": return "text.book.closed"
        case "Storage": return "internaldrive"
        case "Settings": return "gearshape"
        case "Permissions": return "lock.shield"
        case "Summarization": return "sparkles"
        default: return "clock"
        }
    }
    var statusBar: some View { CaptureStatusBar(j: j, meter: j.meter, accent: accent) }
    var timeline: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Your conversations").font(.largeTitle.weight(.semibold))
                    Text("Meetings, plans, and passing thoughts — easy to find again.")
                        .foregroundStyle(
                            .secondary)
                }
                Spacer()
                Button("Import audio", systemImage: "square.and.arrow.down") { j.importAudio() }
                    .disabled(
                        j.recording)
            }
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search transcript words across your timeline", text: $j.query)
                    .textFieldStyle(
                        .plain
                    )
                    .onChange(of: j.query) { _, _ in j.refresh() }
                Picker("Speaker", selection: $j.speakerFilter) {
                    Text("All speakers").tag("")
                    ForEach(j.speakerChoices, id: \.self) { Text($0).tag($0) }
                }
                .frame(width: 140).onChange(of: j.speakerFilter) { _, _ in j.refresh() }
                Picker("Language", selection: $j.languageFilter) {
                    Text("All languages").tag("")
                    ForEach(
                        [
                            "en · model assumption", "ja · script estimate", "zh / ja uncertain",
                            "mixed / uncertain", "uncertain",
                        ], id: \.self
                    ) { Text($0).tag($0) }
                }
                .frame(width: 150).onChange(of: j.languageFilter) { _, _ in j.refresh() }
                Button("Clear") {
                    j.query = ""
                    j.speakerFilter = ""
                    j.languageFilter = ""
                    j.refresh()
                }
            }
            .padding(13).background(.background, in: RoundedRectangle(cornerRadius: 12))
            HStack(alignment: .top, spacing: 20) {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(j.sessions) { session in
                            Button {
                                j.stopPlayback()
                                j.selected = session.id
                                j.refresh()
                            } label: {
                                VStack(alignment: .leading, spacing: 9) {
                                    HStack {
                                        Image(systemName: "bubble.left.and.bubble.right")
                                            .foregroundStyle(accent)
                                        Text(
                                            Date(timeIntervalSince1970: session.started)
                                                .formatted(
                                                    date: .abbreviated, time: .shortened)
                                        )
                                        .font(.caption)
                                        Spacer()
                                    }
                                    Text(session.title).font(.headline).lineLimit(2)
                                    HStack {
                                        Text(session.status.capitalized).font(.caption)
                                            .foregroundStyle(.secondary)
                                        Spacer()
                                        Text(session.model == "unified" ? "EN" : "MULTI")
                                            .font(.caption2.weight(.bold))
                                            .foregroundStyle(accent)
                                    }
                                }
                                .padding(16).frame(maxWidth: .infinity, alignment: .leading)
                                .background(
                                    j.selected == session.id
                                        ? accent.opacity(0.13)
                                        : Color(nsColor: .controlBackgroundColor),
                                    in: RoundedRectangle(cornerRadius: 14))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(width: 260)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        if let session = j.sessions.first(where: { $0.id == j.selected }) {
                            HStack {
                                Text(session.title).font(.title2.weight(.semibold))
                                Spacer()
                                Button(role: .destructive) {
                                    deleteCandidate = session
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .disabled(j.recording || j.captureBusy)
                            }
                            Text(session.device).font(.caption).foregroundStyle(.secondary)
                                .textSelection(
                                    .enabled)
                            ConversationSummaryView(controller: j.summaries, session: session.id) {
                                source in
                                j.playSummarySource(session: session.id, source: source)
                            }
                            Text(j.savingSummary).font(.caption).foregroundStyle(.secondary)
                            DisclosureGroup("Recording details") {
                                Text(
                                    j.recordingDetails
                                        + "\nSpeaker labels, including Me, are estimates. Overlapping and distant voices may be missed."
                                )
                                .font(.caption.monospaced()).textSelection(.enabled)
                            }
                            if !session.note.isEmpty {
                                Label(session.note, systemImage: "info.circle").font(.callout)
                                    .foregroundStyle(
                                        .secondary
                                    )
                                    .lineLimit(2)
                            }
                            ForEach(j.sourceNotices, id: \.self) { notice in
                                Text(notice).font(.caption).foregroundStyle(.secondary)
                            }
                            Text(speakerSummary).font(.caption).foregroundStyle(accent)
                            if j.playbackSources.count > 1 {
                                Picker("Audio source for playback", selection: $j.playbackOrigin) {
                                    ForEach(j.playbackSources, id: \.rawValue) {
                                        Text($0.title).tag($0)
                                    }
                                }
                                .onChange(of: j.playbackOrigin) { _, _ in j.stopPlayback() }
                                Text(
                                    "Sources stay separate. Playback never mixes them or crosses from one into another."
                                )
                                .font(.caption).foregroundStyle(.secondary)
                            }
                            HStack {
                                Button("Play conversation", systemImage: "play.circle.fill") {
                                    j.playConversation(session: session.id)
                                }
                                .disabled(j.recording || j.audioExpiry == nil)
                                if j.playbackSession == session.id {
                                    Button(j.playbackState == .paused ? "Resume" : "Pause") {
                                        j.playbackState == .paused
                                            ? j.resumePlayback() : j.pausePlayback()
                                    }
                                    Button("Stop", systemImage: "stop.circle") { j.stopPlayback() }
                                    PlaybackClock(meter: j.playbackMeter)
                                }
                            }
                            Text(
                                "Playback continues across saved spans and skips documented non-speech. Timestamps keep original elapsed time; sentence times are estimates."
                            )
                            .font(.caption).foregroundStyle(.secondary)
                            if !j.playbackNotice.isEmpty {
                                Text(j.playbackNotice).font(.caption).foregroundStyle(accent)
                            }
                            if let expiry = j.audioExpiry {
                                Text(
                                    "Audio expires \(Date(timeIntervalSince1970:expiry).formatted()) · transcript retained."
                                )
                                .font(.caption).foregroundStyle(.secondary)
                            }
                            if !j.processingFailures.isEmpty {
                                Button("Retry failed processing", systemImage: "arrow.clockwise") {
                                    do { try j.processor.retry() } catch {
                                        j.error = error.localizedDescription
                                    }
                                }
                                ForEach(Array(j.processingFailures.enumerated()), id: \.offset) {
                                    failure in
                                    Text(failure.element).font(.caption).foregroundStyle(.orange)
                                }
                            }
                        }
                        if j.segments.isEmpty {
                            ContentUnavailableView(
                                !j.query.isEmpty
                                    ? "No matching words"
                                    : j.sessions.isEmpty
                                        ? "A quiet place for your conversations"
                                        : j.selected == nil
                                            ? "Choose a conversation" : "No transcript yet",
                                systemImage: "waveform",
                                description: Text(
                                    !j.query.isEmpty
                                        ? "Try another word or clear the speaker and language filters."
                                        : j.sessions.isEmpty
                                            ? "Choose your receiver in Settings → Devices, then start recording. You can also import a local audio file."
                                            : j.selected == nil
                                                ? "Select a recent conversation to review its transcript and playback."
                                                : "Audio chunks are durable. Processing status and recovery options appear above; silence has no transcript."
                                ))
                        }
                        ForEach(j.segments) { segment in
                            VStack(alignment: .leading, spacing: 10) {
                                HStack {
                                    Text(segment.speaker).font(.subheadline.weight(.semibold))
                                        .foregroundStyle(accent)
                                    Text(segment.origin.title).font(.caption)
                                        .foregroundStyle(.secondary)
                                    Text(segment.language).font(.caption)
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    Button {
                                        j.play(segment)
                                    } label: {
                                        Label(time(segment.offset), systemImage: "play.circle")
                                    }
                                    .buttonStyle(.plain)
                                    Button {
                                        editing = segment
                                    } label: {
                                        Image(systemName: "pencil")
                                    }
                                    .buttonStyle(.plain)
                                }
                                if segment.possibleEcho {
                                    HStack {
                                        Label(
                                            "Possible speaker-output echo · audio/text preserved",
                                            systemImage: "waveform.path"
                                        )
                                        .font(.caption)
                                        Button("Dismiss") {
                                            j.dismissEcho(segment, dismissed: true)
                                        }
                                        .font(.caption)
                                    }
                                } else if segment.echoDismissed {
                                    Button("Restore echo hint if dismissed") {
                                        j.dismissEcho(segment, dismissed: false)
                                    }
                                    .font(.caption)
                                }
                                Text(segment.corrected).font(.system(size: 16)).lineSpacing(5)
                                    .textSelection(
                                        .enabled)
                                if segment.raw != segment.corrected {
                                    DisclosureGroup("Original transcript") {
                                        Text(segment.raw).font(.callout).textSelection(.enabled)
                                    }
                                    .font(.caption)
                                    Button("Undo correction") { j.undo(segment) }.font(.caption)
                                }
                            }
                            .padding(18).frame(maxWidth: .infinity, alignment: .leading)
                            .modifier(
                                PlaybackHighlight(
                                    meter: j.playbackMeter, session: segment.session,
                                    start: segment.offset, end: segment.end, color: accent))
                        }
                        if j.playing {
                            Button("Stop playback", systemImage: "stop.circle") { j.stopPlayback() }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(28)
    }
    var speakerSummary: String {
        let speakers = Set(j.segments.map(\.speaker).filter { !$0.hasPrefix("Unknown") })
        if speakers.isEmpty { return "Speaker count uncertain" }
        return j.segments.contains(where: { $0.speaker.hasPrefix("Unknown") })
            ? "\(speakers.count) speaker label(s) · count uncertain"
            : "Estimated \(speakers.count) speaker(s) · labels editable"
    }
    func time(_ offset: Double) -> String {
        String(format: "%02d:%02d", Int(offset) / 60, Int(offset) % 60)
    }
    @ViewBuilder var settingsSection: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("Settings").font(.largeTitle.weight(.semibold))
            Text("Nagi · " + AppVersion.current.details).font(.callout).foregroundStyle(.secondary)
                .textSelection(.enabled)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 8)], spacing: 8) {
                ForEach(settingsPages, id: \.self) { name in
                    Button {
                        settingsPage = name
                    } label: {
                        Label(name, systemImage: icon(name))
                            .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                            .contentShape(Rectangle())
                            .background(
                                settingsPage == name ? accent.opacity(0.13) : .clear,
                                in: RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                    .allowsWindowActivationEvents(true)
                    .accessibilityAddTraits(settingsPage == name ? .isSelected : [])
                }
            }
            Divider()
            settingsPageContent.disabled(j.syntheticMonitor)
        }
    }
    @ViewBuilder var settingsPageContent: some View {
        VStack(alignment: .leading, spacing: 22) {
            if !["Permissions", "Summarization"].contains(settingsPage) {
                Label(settingsPage, systemImage: icon(settingsPage)).font(.title2.weight(.semibold))
            }
            switch settingsPage {
            case "Permissions":
                PermissionsView(
                    permission: j.microphonePermission,
                    inputConnected: j.devices.contains { $0.id == j.inputUID },
                    hasInputs: !j.devices.isEmpty, requestsDisabled: j.syntheticMonitor)
            case "Summarization":
                SummarySettingsView(controller: j.summaries)
            case "Devices":
                Text(
                    "Select the receiver you want to record. We remember its stable UID and never fall back to another input."
                )
                .foregroundStyle(.secondary)
                Picker("Input", selection: Binding(get: { j.inputUID }, set: { j.selectInput($0) }))
                {
                    Text("Choose an input").tag("")
                    ForEach(j.devices) { Text($0.name).tag($0.id) }
                    if !j.inputUID.isEmpty, !j.devices.contains(where: { $0.id == j.inputUID }) {
                        Text("Selected input disconnected").tag(j.inputUID)
                    }
                }
                .disabled(j.recording || j.captureBusy)
                Text(j.inputUID.isEmpty ? "No input selected" : j.inputUID)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                Label(
                    "Receiver unplug stops and saves. Wireless transmitter loss may look like silence; silence is not proof of disconnection.",
                    systemImage: "antenna.radiowaves.left.and.right"
                )
                .foregroundStyle(.secondary)
                Divider()
                Toggle("Include system audio for new conversations", isOn: $j.includeSystemAudio)
                    .disabled(j.recording || j.captureBusy)
                    .onChange(of: j.includeSystemAudio) { _, _ in j.saveSystemAudio() }
                Text(
                    "Off by default. Records computer playback alongside your selected microphone in separate continuous tracks. Voice enrollment uses the microphone only. Both sources must start successfully; no silent fallback."
                )
                .font(.callout).foregroundStyle(.secondary)
                Label(
                    j.systemAudioPermitted
                        ? "System audio permission available"
                        : "System audio permission unavailable", systemImage: "speaker.wave.2")
                HStack {
                    Button("Request system audio access…") { j.requestSystemAudioPermission() }
                        .disabled(j.syntheticMonitor || j.recording || j.captureBusy)
                    Button("Check system audio permission") { j.checkSystemAudioPermission() }
                }
                Text(
                    "macOS may name this Screen & System Audio Recording in Privacy & Security and may require restarting Nagi after approval. This button requests access without starting capture. No screen images are stored."
                )
                .font(.caption).foregroundStyle(.secondary)
                Text(
                    "Use headphones to reduce acoustic duplication. Nagi excludes its own digital playback; possible echo hints are reversible evidence, not echo cancellation. Both tracks and all transcript text remain intact. Dual-source sessions use chunk processing instead of the streaming microphone preview to keep ML sequential."
                )
                .font(.caption).foregroundStyle(.secondary)
                Toggle("Prevent idle system sleep while recording", isOn: $j.keepAwake)
                    .disabled(
                        j.recording)
                Text(
                    "Closing the window or locking the screen keeps the menu-bar app running. System sleep stops recording and marks a gap; start again after wake."
                )
                .font(.callout).foregroundStyle(.secondary)
            case "Models":
                Text(
                    "Choose manually before each session. Models and audio remain on this Mac. ASR and speaker analysis run sequentially."
                )
                .foregroundStyle(.secondary)
                Picker("Speech-to-text model", selection: $j.model) {
                    ForEach(Models.all) { Text($0.name).tag($0.id) }
                }
                .disabled(j.recording || j.captureBusy)
                ForEach(Models.all) { model in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(model.name).font(.headline)
                        Text(model.languages)
                        Text(model.revision).font(.caption.monospaced()).textSelection(.enabled)
                        Label(
                            FileManager.default.fileExists(
                                atPath: j.project.appendingPathComponent("Models/" + model.filename)
                                    .path)
                                ? "Installed locally" : "Missing — see setup instructions",
                            systemImage: "internaldrive"
                        )
                        .font(.caption)
                    }
                    .padding(18).frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        .background, in: RoundedRectangle(cornerRadius: 14))
                }
                Text(
                    "English uses the exact Handy Unified model, not TDT v3. Language tags are conservative script estimates or model assumptions. Preferred words are review hints; no guaranteed decode-time bias."
                )
                .font(.callout).foregroundStyle(.secondary)
            case "Voice profile":
                if !j.enrollmentResult.isEmpty {
                    Text(j.enrollmentResult)
                        .foregroundStyle(j.profileReady ? Color.secondary : Color.orange)
                }
                Label(
                    j.profileReady ? "Local voice profile enrolled" : "No voice profile yet",
                    systemImage: "person.crop.circle.badge.checkmark"
                )
                .font(.title2)
                Text(
                    "Sit alone in a quiet room. Use your selected receiver. Read the passage below naturally for 20 seconds. Recording starts only when you press Enroll; you can stop at any time."
                )
                .foregroundStyle(.secondary)
                Text(
                    "“Today I am planning my next meeting. I want to remember the ideas we share, the decisions we make, and the questions I still have. This is my journal, and I can review or change every speaker label.”"
                )
                .font(.title3).padding(20)
                .background(.background, in: RoundedRectangle(cornerRadius: 14))
                Button(j.enrollment ? "Stop enrollment" : "Enroll my voice (20 seconds)") {
                    j.enrollment ? j.stop(note: "Enrollment stopped early") : j.start(enroll: true)
                }
                .buttonStyle(.borderedProminent).disabled(j.recording && !j.enrollment)
                Button("Delete local voice profile", role: .destructive) { j.forgetProfile() }
                    .disabled(
                        !j.profileReady)
                Text(
                    "Only Community-1 embeddings are matched. Conservative similarity and margin thresholds may leave Unknown labels. Synthetic voice tests cannot establish accuracy on real people. One wearable mic may miss distant speech and overlap."
                )
                .font(.callout).foregroundStyle(.secondary)
            case "Dictionary":
                Text("Preferred words (review hints)").font(.headline)
                TextField("DJI, Nagi, Kyoto…", text: $j.preferredWords)
                    .textFieldStyle(.roundedBorder)
                Text("Exact replacements — one ‘from => to’ rule per line").font(.headline)
                TextEditor(text: $j.rulesText).font(.system(.body, design: .monospaced))
                    .frame(height: 200)
                    .padding(8).background(.background, in: RoundedRectangle(cornerRadius: 10))
                Text(
                    "Rules apply after ASR to future jobs. They are case-sensitive and may replace substrings. Raw text and previous corrections are retained; use Undo or edit in the timeline."
                )
                .font(.callout).foregroundStyle(.secondary)
            case "Storage":
                Picker("Saving for new recordings", selection: $j.savingMode) {
                    Text("Speech only · default").tag(AudioSavingMode.speechOnly.rawValue)
                    Text("Continuous audio").tag(AudioSavingMode.continuous.rawValue)
                }
                .disabled(j.recording || j.captureBusy)
                .onChange(of: j.savingMode) { _, _ in j.saveSavingMode() }
                Text(
                    "Speech only uses a local speech detector with one second before/after speech. Long non-speech intervals are omitted; original elapsed timestamps remain. Noise can occasionally trigger saving, and faint/distant speech may be missed. Choose Continuous to preserve every sound. Existing audio is unchanged; guided enrollment and imports use continuous audio."
                )
                .font(.callout).foregroundStyle(.secondary)
                Text(
                    "Audio and every derived audio copy expire 48 hours from capture. Original sample rate and channels are retained in losslessly gzip-compressed CAF chunks. The local data directory is excluded from backups where macOS supports it."
                )
                .foregroundStyle(.secondary)
                Toggle("Cap transcript text and correction history", isOn: $j.capEnabled)
                HStack {
                    TextField("Capacity in MB", text: $j.capMegabytes).frame(width: 110)
                        .textFieldStyle(
                            .roundedBorder)
                    Text("MB · 1–10,000; default 500")
                }
                .disabled(!j.capEnabled)
                Text(
                    "At the cap, the oldest whole conversations and their audio are evicted. This counts UTF-8 raw and displayed text, original decoder outputs, correction history and saved summaries, not SQLite index/file overhead. Turn the cap off to keep transcripts until you delete them."
                )
                .font(.callout).foregroundStyle(.secondary)
                Text(j.store.root.path).font(.caption.monospaced()).textSelection(.enabled)
                Button("Run expiry cleanup now") {
                    j.stopPlayback()
                    j.processor.maintenance()
                }
                Text(
                    "While the app or Mac is off, deletion cannot run. On startup and wake expired files are removed; playback is disabled once expiry passes. Audio stays local; optional transcript summaries are configured in Settings → Summarization."
                )
                .font(.callout).foregroundStyle(.secondary)
            default:
                EmptyView()
            }
            if !["Voice profile", "Permissions", "Summarization"].contains(settingsPage) {
                Button("Save settings") { j.saveSettings() }.buttonStyle(.borderedProminent)
                    .disabled(
                        j.recording)
            }
        }
    }
}
struct PreferencesView: View { var body: some View { ContentView(initialSection: "Settings") } }
struct EditTranscript: View {
    @EnvironmentObject var j: Journal
    @Environment(\.dismiss) var dismiss
    let segment: Segment
    @State private var text = ""
    @State private var speaker = "Unknown"
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Review transcript").font(.title2.weight(.semibold))
            TextEditor(text: $text).frame(height: 180)
            TextField("Speaker label (Me / Speaker 2 / Unknown)", text: $speaker)
                .textFieldStyle(
                    .roundedBorder)
            DisclosureGroup("Raw ASR text") { Text(segment.raw).textSelection(.enabled) }
            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button("Save correction") {
                    j.edit(segment, text: text, speaker: speaker)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(28).frame(width: 600)
        .onAppear {
            text = segment.corrected
            speaker = segment.speaker
        }
    }

}

struct CaptureStatusBar: View {
    @ObservedObject var j: Journal
    @ObservedObject var meter: CaptureMeter
    let accent: Color
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) {
                statusInfo
                Spacer(minLength: 8)
                captureControls
            }
            VStack(alignment: .leading, spacing: 12) {
                statusInfo
                captureControls
            }
        }
    }
    private var statusInfo: some View {
        HStack(spacing: 16) {
            if j.recording && j.includeSystemAudio && !j.enrollment {
                ProgressView(value: j.systemLevel).frame(width: 60)
                    .accessibilityLabel("System audio level")
            }
            Circle().fill(j.recording ? .red : j.captureStarting ? .orange : accent)
                .frame(width: 12, height: 12)
            VStack(alignment: .leading, spacing: 5) {
                Text(j.status).font(.headline)
                Text(j.processing).font(.caption).foregroundStyle(.secondary)
            }
            if j.recording && meter.level < 0.0008 && meter.elapsed > 8 {
                Text("Input is quiet · check TX / receiver").font(.caption).foregroundStyle(.orange)
            }
            if j.recording {
                Text(String(format: "%02d:%02d", meter.elapsed / 60, meter.elapsed % 60))
                    .monospacedDigit()
                ProgressView(value: meter.level).frame(width: 90)
                    .accessibilityLabel("Microphone input level")
            }
        }
    }
    private var captureControls: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 12) {
                inputPicker; recordingButton
            }
            VStack(alignment: .leading, spacing: 10) {
                inputPicker; recordingButton
            }
        }
    }
    private var inputPicker: some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker("Input", selection: Binding(get: { j.inputUID }, set: { j.selectInput($0) })) {
                Text(j.devices.isEmpty ? "No inputs available" : "Choose an input").tag("")
                ForEach(j.devices) { Text($0.name).tag($0.id) }
                if !j.inputUID.isEmpty, !j.devices.contains(where: { $0.id == j.inputUID }) {
                    Text("Selected input disconnected").tag(j.inputUID)
                }
            }
            .frame(width: 220).disabled(j.recording || j.captureBusy || j.syntheticMonitor)
            .accessibilityLabel("Recording input")
            Text(
                j.recording
                    ? "Stop recording to change input"
                    : InputSelection.message(uid: j.inputUID, devices: j.devices)
            )
            .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            .frame(width: 220, alignment: .leading)
        }
    }
    private var recordingButton: some View {
        Button(
            j.syntheticMonitor
                ? "Test controls disabled"
                : j.recording
                    ? "Stop & save"
                    : j.captureBusy
                        ? (j.captureStarting ? "Cancel startup" : "Finalizing…")
                        : "Start recording",
            systemImage: j.recording ? "stop.fill" : "record.circle"
        ) { (j.recording || j.captureBusy) ? j.stop() : j.start() }
        .disabled(j.captureBusy && !j.captureStarting)
        .buttonStyle(.borderedProminent).controlSize(.large).disabled(j.syntheticMonitor)
    }
}

private struct PlaybackClock: View {
    @ObservedObject var meter: PlaybackMeter
    var body: some View {
        Text(String(format: "%02d:%02d", Int(meter.position) / 60, Int(meter.position) % 60))
            .monospacedDigit()
    }
}
private struct PlaybackHighlight: ViewModifier {
    @ObservedObject var meter: PlaybackMeter
    let session: String
    let start: Double
    let end: Double
    let color: Color
    func body(content: Content) -> some View {
        content.background(
            meter.session == session && meter.position >= start && meter.position < end
                ? color.opacity(0.13) : Color(nsColor: .textBackgroundColor),
            in: RoundedRectangle(cornerRadius: 14))
    }
}
