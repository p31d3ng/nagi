import AVFoundation
import AppKit
import SwiftUI

/// Only explicit user actions call request. Reading or refreshing never opens the microphone.
@MainActor final class MicrophonePermission: ObservableObject {
    @Published private(set) var state: AVAuthorizationStatus
    @Published private(set) var requesting = false
    private let read: () -> AVAuthorizationStatus
    private let ask: (@escaping (Bool) -> Void) -> Void
    init(
        read: @escaping () -> AVAuthorizationStatus = {
            AVCaptureDevice.authorizationStatus(for: .audio)
        },
        ask: @escaping (@escaping (Bool) -> Void) -> Void = {
            AVCaptureDevice.requestAccess(for: .audio, completionHandler: $0)
        }
    ) {
        self.read = read; self.ask = ask; state = read()
    }
    func refresh() { state = read() }
    func request(completion: @escaping (Bool) -> Void = { _ in }) {
        refresh()
        guard !requesting else { return }
        guard state == .notDetermined else {
            completion(state == .authorized); return
        }
        requesting = true
        ask { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.refresh(); self.requesting = false
                completion(self.state == .authorized)
            }
        }
    }
    var title: String {
        switch state {
        case .notDetermined: return "Microphone · Not requested"
        case .authorized: return "Microphone · Allowed"
        case .denied: return "Microphone · Denied"
        case .restricted: return "Microphone · Restricted"
        @unknown default: return "Microphone · Status unavailable"
        }
    }
    var explanation: String {
        switch state {
        case .notDetermined:
            return
                "Request access here, or when you explicitly start recording or enrollment. Granting access here does not start recording."
        case .authorized:
            return
                "macOS allows this app to use the microphone. Recording starts only with Start or Enroll; a connected selected input is also required."
        case .denied:
            return
                "Enable Nagi in System Settings → Privacy & Security → Microphone, then return here. macOS may ask you to quit and reopen Nagi."
        case .restricted:
            return
                "macOS restricts microphone access. A device policy or administrator may need to allow it; Nagi cannot override this restriction."
        @unknown default:
            return "Check System Settings → Privacy & Security → Microphone."
        }
    }
    func openSettings() {
        // Apple's support page provides a supported Settings link; avoid undocumented pane URLs.
        if let url = URL(
            string:
                "https://support.apple.com/guide/mac-help/control-access-to-the-microphone-on-mac-mchla1b1e1fe/mac"
        ) {
            NSWorkspace.shared.open(url)
        }
    }
}
struct PermissionsView: View {
    @ObservedObject var permission: MicrophonePermission
    let inputConnected: Bool
    let hasInputs: Bool
    let requestsDisabled: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Permissions", systemImage: "lock.shield").font(.title2.weight(.semibold))
            Label(
                permission.title,
                systemImage: permission.state == .authorized
                    ? "checkmark.circle" : "mic.badge.xmark")
            Text(permission.explanation).foregroundStyle(.secondary)
            HStack {
                if permission.state == .notDetermined {
                    Button(
                        permission.requesting ? "Waiting for macOS…" : "Request microphone access"
                    ) {
                        permission.request()
                    }
                    .disabled(permission.requesting || requestsDisabled)
                }
                Button("Check permission again") { permission.refresh() }
                Button("Microphone settings help…") { permission.openSettings() }
            }
            Text("System Settings → Privacy & Security → Microphone → Nagi")
                .font(.caption).foregroundStyle(.secondary)
            Label(
                inputConnected
                    ? "Selected input is connected"
                    : hasInputs
                        ? "No connected input selected · choose one in Settings → Devices"
                        : "No audio input devices detected · connect your receiver and check Settings → Devices",
                systemImage: inputConnected ? "mic" : "cable.connector"
            )
            .font(.callout)
            Text(
                "Permission and device availability are separate checks. This status does not guarantee macOS will retain permission across development rebuilds."
            )
            .font(.caption).foregroundStyle(.secondary)
        }
        .padding(20).background(.background, in: RoundedRectangle(cornerRadius: 14))
        .onAppear { permission.refresh() }
    }
}
