import JournalCore
import SwiftUI

struct SummarySettingsView: View {
    @ObservedObject var controller: SummaryController
    @State private var bearer = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Summarization", systemImage: "sparkles").font(.title2.weight(.semibold))
            Text(
                "Optional transcript sharing. Manual submission or enabling automatic submission sends finalized text, speaker labels and elapsed timestamps to this HTTPS service. Audio and your voice profile stay on this Mac."
            )
            .foregroundStyle(.secondary)
            TextField("HTTPS summarize endpoint", text: $controller.endpointText)
                .textFieldStyle(.roundedBorder).autocorrectionDisabled()
                .onChange(of: controller.endpointText) { _, _ in controller.endpointDraftChanged() }
            Button("Save endpoint") { controller.saveEndpoint() }
            Text(
                "Credentials are bound to the exact saved URL. A changed URL requires its own credential; redirects are blocked."
            )
            .font(.caption).foregroundStyle(.secondary)
            SecureField("Original app bearer · not deploy token or SHA-256 digest", text: $bearer)
                .textFieldStyle(.roundedBorder)
            ViewThatFits(in: .horizontal) {
                HStack {
                    saveBearerButton; removeBearerButton
                }
                .fixedSize(horizontal: true, vertical: false)
                VStack(alignment: .leading, spacing: 8) {
                    saveBearerButton; removeBearerButton
                }
            }
            Label(
                controller.credentialAvailable
                    ? "Credential saved for the saved URL" : "No saved app credential",
                systemImage: controller.credentialAvailable ? "key.fill" : "key"
            )
            .foregroundStyle(controller.credentialAvailable ? Color.secondary : Color.orange)
            Toggle(
                "Automatically summarize new recordings after final processing",
                isOn: Binding(
                    get: { controller.automatic }, set: { controller.setAutomatic($0) })
            )
            .disabled(
                !controller.credentialAvailable
                    || controller.savedEndpoint
                        != (try? SummaryEndpoint.validate(controller.endpointText))
            )
            Text(
                "Off by default. Applies only to recordings started while enabled, after Stop and final ASR/speaker processing. Current and historical recordings are not enrolled when you turn it on. Turning it off cancels pending automatic submissions. No automatic retries after a possibly processed request."
            )
            .font(.caption).foregroundStyle(.secondary)
            if !controller.configurationMessage.isEmpty {
                Text(controller.configurationMessage).font(.callout)
            }
            Text(
                "The current service accepts at most 16 KiB and 64 speaker turns. Large conversations are rejected, never shortened silently. Generated summaries may invent agreements or misclassify suggestions: review decisions and actions against the transcript."
            )
            .font(.callout).foregroundStyle(.secondary)
        }
        .padding(20).background(.background, in: RoundedRectangle(cornerRadius: 14))
    }
    private var saveBearerButton: some View {
        Button("Save bearer in Keychain") {
            let value = bearer; bearer = ""; controller.saveBearer(value)
        }
        .disabled(bearer.isEmpty)
    }
    private var removeBearerButton: some View {
        Button("Remove saved bearer", role: .destructive) {
            bearer = ""; controller.forgetBearer()
        }
        .disabled(!controller.credentialAvailable)
    }

}
struct ConversationSummaryView: View {
    @ObservedObject var controller: SummaryController
    let session: String
    var evidence: (SummarySource) -> Void
    @State private var retryConfirmation = false
    private var current: Bool {
        controller.latest?["session"] == session
            && Int(controller.latest?["version"] ?? "0") == controller.selectedRevision
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Summary", systemImage: "sparkles").font(.headline)
                Spacer()
                if controller.busySession == session {
                    ProgressView().controlSize(.small)
                    Button("Cancel") { controller.cancel() }
                } else {
                    let completed = current && controller.latest?["status"] == "done"
                    Button(
                        completed
                            ? "Summarize again…"
                            : current && controller.latest != nil ? "Retry summary…" : "Summarize"
                    ) {
                        if current && controller.latest != nil {
                            retryConfirmation = true
                        } else {
                            controller.submit(session: session)
                        }
                    }
                    .disabled(
                        controller.busySession != nil || !controller.credentialAvailable
                            || !controller.selectedReady)
                }
            }
            Text(
                "Sends this finalized transcript to your configured service. No audio. Configure the endpoint and app bearer in Settings."
            )
            .font(.caption).foregroundStyle(.secondary)
            if !controller.selectedReady {
                Text(
                    "Available after recording stops and final transcription/speaker processing completes."
                )
                .font(.caption).foregroundStyle(.secondary)
            }
            if controller.messageSession == session && !controller.lastMessage.isEmpty {
                Text(controller.lastMessage).font(.callout).foregroundStyle(.orange)
            }
            if controller.latest?["session"] == session {
                if let error = controller.latest?["error"], !error.isEmpty {
                    Text(error).font(.callout).foregroundStyle(.orange)
                }
                if controller.latest?["status"] == "sending" {
                    Text("Sending finalized transcript · waiting for service response…")
                        .font(.caption)
                }
                if let envelope = controller.envelope {
                    Label("Generated · needs review", systemImage: "exclamationmark.bubble")
                        .foregroundStyle(.orange)
                    if !current || controller.latest?["status"] == "stale" {
                        Text(
                            "Transcript changed. This summary belongs to an older revision; summarize again to update it."
                        )
                        .foregroundStyle(.orange).font(.caption)
                    }
                    Text(envelope.summary.overview).textSelection(.enabled)
                    items("Highlights", envelope.summary.highlights)
                    items(
                        "Decisions · verify against the source", envelope.summary.decisions,
                        quoted: true)
                    items(
                        "Actions · verify commitments", envelope.summary.actionItems, quoted: true)
                    Text(
                        "\(envelope.model) · transcript revision \(envelope.version) · stored locally"
                    )
                    .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(18).background(.background, in: RoundedRectangle(cornerRadius: 14))
        .confirmationDialog(
            "Retry may run inference again. The previous request may already have been processed.",
            isPresented: $retryConfirmation
        ) {
            Button("Send again") { controller.submit(session: session) }
            Button("Cancel", role: .cancel) {}
        }
    }
    @ViewBuilder private func items(_ title: String, _ rows: [SummaryItem], quoted: Bool = false)
        -> some View
    {
        if !rows.isEmpty {
            Text(title).font(.subheadline.weight(.semibold))
            ForEach(Array(rows.enumerated()), id: \.offset) { _, item in
                VStack(alignment: .leading, spacing: 6) {
                    Text(quoted ? (item.quote ?? "") : (item.text ?? "")).textSelection(.enabled)
                    ForEach(Array(item.sources.enumerated()), id: \.offset) { _, source in
                        HStack {
                            Button(
                                "\(source.speakerLabel) · \(Int(source.start)/60):\(String(format: "%02d", Int(source.start)%60))",
                                systemImage: "play.circle"
                            ) { evidence(source) }
                            .buttonStyle(.plain)
                            if source.uncertain {
                                Text("Uncertain speaker").foregroundStyle(.secondary)
                            }
                            if source.overlap {
                                Text("Possible overlap").foregroundStyle(.secondary)
                            }
                        }
                        .font(.caption)
                    }
                }
            }
        }
    }
}
