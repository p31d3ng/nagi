import AppKit
import JournalCore
import SwiftUI

struct LiveView: View {
    @EnvironmentObject var j: Journal
    @State private var paragraphs: [LiveParagraph] = []
    @State private var following = true
    @State private var before = Double.greatestFiniteMagnitude
    @State private var visibleSession = ""
    @State private var message = ""
    private var session: String { j.activeLiveSession ?? j.selected ?? "" }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Live transcript").font(.largeTitle.weight(.semibold))
                Spacer()
                Button("Copy shown text") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(
                        paragraphs.map(\.text).joined(separator: "\n\n"), forType: .string)
                }
                .disabled(paragraphs.isEmpty)
            }
            Text(j.liveStatus).foregroundStyle(.secondary)
            HStack {
                Picker("Preview responsiveness", selection: $j.liveMode) {
                    Text("Balanced · quicker").tag("balanced")
                    Text("Accuracy · more context").tag("accuracy")
                }
                .frame(maxWidth: 380).disabled(j.recording || j.model != "unified")
                Text("Preview only; final saved decoding stays unchanged.").font(.caption)
                    .foregroundStyle(.secondary)
            }
            .onChange(of: j.liveMode) { _, _ in j.saveLiveMode() }
            Text(
                "Audio saves continuously. English preview words can change; final text and speaker labels follow. Other models show completed chunks. Switching tabs keeps recording and any active preview running."
            )
            .font(.caption).foregroundStyle(.secondary)
            HStack {
                Label(
                    j.recording ? "Recording · original audio saving" : "Not recording",
                    systemImage: j.recording ? "record.circle" : "pause.circle")
                Text("· " + (j.devices.first { $0.id == j.inputUID }?.name ?? "Selected input"))
                Text("· " + (Models.all.first { $0.id == j.model }?.name ?? j.model))
                Spacer()
                if j.recording, j.model == "unified", !j.liveEngineActive {
                    Button("Resume live preview") { j.chooseLive() }
                }
                if !following {
                    Button("Jump to live") {
                        following = true; before = .greatestFiniteMagnitude; reload()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .font(.callout)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        if let first = paragraphs.first {
                            Button("Earlier text") {
                                following = false; before = first.offset; reload()
                            }
                        }
                        ForEach(paragraphs) { row in
                            VStack(alignment: .leading, spacing: 5) {
                                Text(time(row.offset) + " · " + row.detail).font(.caption)
                                    .foregroundStyle(.secondary)
                                previewText(row).font(.title3).textSelection(.enabled)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        Color.clear.frame(height: 1).id("live-bottom")
                    }
                    .padding(22)
                }
                .onScrollPhaseChange { _, phase in
                    if phase == .interacting { following = false }
                }
                .onChange(of: paragraphs) { _, _ in
                    if following { proxy.scrollTo("live-bottom", anchor: .bottom) }
                }
                .onChange(of: following) { _, value in
                    if value { proxy.scrollTo("live-bottom", anchor: .bottom) }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.background, in: RoundedRectangle(cornerRadius: 16))
                .overlay {
                    if paragraphs.isEmpty {
                        ContentUnavailableView(
                            j.recording ? "Listening for speech" : "Your conversation appears here",
                            systemImage: "text.bubble",
                            description: Text(
                                j.recording
                                    ? "Audio is saving while the local model prepares text."
                                    : "Choose an input, then press Start recording. Opening this tab never starts the microphone."
                            )
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(.quaternary))
            }
            Text(
                message.isEmpty
                    ? "Showing up to 200 paragraphs. Earlier text stays in the journal; use Earlier text or Timeline search."
                    : message
            )
            .font(.caption).foregroundStyle(.secondary)
        }
        .padding(24)
        .onAppear {
            j.chooseLive(); reload()
        }
        .onChange(of: j.liveRevision) { _, _ in if following { reload() } }
        .onChange(of: session) { _, _ in
            following = true; before = .greatestFiniteMagnitude; reload()
        }
    }
    private func previewText(_ row: LiveParagraph) -> Text {
        guard row.offset == j.livePreviewOffset,
            row.text == j.liveCommitted + j.liveTentative
        else {
            return Text(row.text.isEmpty ? "Listening…" : row.text)
        }
        return Text(j.liveCommitted) + Text(j.liveTentative).foregroundColor(.secondary)
    }
    private func reload() {
        guard !session.isEmpty else { paragraphs = []; return }
        if visibleSession != session { visibleSession = session; before = .greatestFiniteMagnitude }
        do {
            let next = try LiveDocument.page(j.store, session: session, before: before)
            if paragraphs != next { paragraphs = next }
            message = ""
        } catch {
            message = "Saved audio is safe. Could not refresh text: \(error.localizedDescription)"
        }
    }
    private func time(_ seconds: Double) -> String {
        String(format: "%02d:%02d", Int(seconds) / 60, Int(seconds) % 60)
    }
}
