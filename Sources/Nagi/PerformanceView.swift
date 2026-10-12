import AppKit
import Darwin
import JournalCore
import SwiftUI

@MainActor final class PerformanceSampler: ObservableObject {
    @Published private(set) var appCPU: Double?
    @Published private(set) var appMemory: UInt64?
    @Published private(set) var asrText = "Inactive"
    @Published private(set) var speakerText = "Inactive"
    private var appDelta = CPUDelta(), helperDeltas: [UUID: CPUDelta] = [:]
    private var timer: Timer?
    private(set) var sampleCount = 0
    var updated: (() -> Void)?
    private let read: (Int32) -> ProcessCounter?
    private let workers: () -> [WorkerRegistry.Entry]
    init(
        read: @escaping (Int32) -> ProcessCounter? = ProcessCounter.read,
        workers: @escaping () -> [WorkerRegistry.Entry] = { WorkerRegistry.shared.current() }
    ) { self.read = read; self.workers = workers }
    func start() {
        guard timer == nil else { return }
        appDelta = CPUDelta(); helperDeltas = [:]; sample()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }; timer?.tolerance = 0.1
    }
    private func tick() {
        guard timer != nil else { return }
        sample()
    }
    func stop() { timer?.invalidate(); timer = nil; helperDeltas = [:]; appDelta = CPUDelta() }
    func sample(now: Double = ProcessInfo.processInfo.systemUptime) {
        sampleCount += 1
        let value = read(getpid()); appCPU = appDelta.sample(value, at: now);
        appMemory = value?.residentBytes
        let entries = workers(); let live = Set(entries.map(\.id));
        helperDeltas = helperDeltas.filter { live.contains($0.key) }
        var values: [WorkerRole: [Double?]] = [:]
        for entry in entries {
            var delta = helperDeltas[entry.id] ?? CPUDelta();
            let cpu = delta.sample(read(entry.pid), at: now); helperDeltas[entry.id] = delta
            values[entry.role, default: []].append(cpu)
        }
        func display(_ role: WorkerRole) -> String {
            guard let rows = values[role], !rows.isEmpty else { return "Inactive" }
            guard rows.allSatisfy({ $0 != nil }) else { return "Collecting / unavailable" }
            return String(format: "%.1f%%", rows.compactMap { $0 }.reduce(0, +))
                + " · \(rows.count) helper(s)"
        }
        asrText = display(.transcription); speakerText = display(.speakers)
        updated?()
    }
}
struct PerformanceView: View {
    @ObservedObject var j: Journal
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(
                "100% CPU means one core. App CPU includes UI, audio, storage and background work; it is not an exact UI-only measurement. Helpers are separate processes. GPU usage is not measured here."
            )
            .foregroundStyle(.secondary)
            PerformanceMetrics().frame(height: 110)
            Text(j.processing).font(.headline)
            Text(j.queueSummary).font(.callout)
            Text(
                "Samples once per second while this panel is visible. No audio access is opened. No active helper is shown as Inactive; missing counters are Unavailable, not zero."
            )
            .font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct PerformanceMetrics: NSViewRepresentable {
    func makeNSView(context: Context) -> VisibilityView {
        return VisibilityView()
    }
    func updateNSView(_ view: VisibilityView, context: Context) {
        view.refresh()
    }
    static func dismantleNSView(_ view: VisibilityView, coordinator: ()) {
        view.stopSampling()
    }
    final class VisibilityView: NSView {
        private let sampler = PerformanceSampler()
        private var labels: [NSTextField] = []
        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            postsFrameChangedNotifications = true
            for index in 0..<4 {
                let label = NSTextField(labelWithString: "")
                label.font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)
                label.frame = NSRect(
                    x: 0, y: CGFloat(84 - index * 26), width: frameRect.width, height: 22)
                label.autoresizingMask = [.width]
                addSubview(label); labels.append(label)
            }
            sampler.updated = { [weak self] in self?.render() }
            render()
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
        func stopSampling() { sampler.stop() }
        private func render() {
            let cpu =
                sampler.appCPU.map { String(format: "%.1f%%", $0) } ?? "Collecting / unavailable"
            let memory =
                sampler.appMemory.map { String(format: "%.1f MiB", Double($0) / 1048576) }
                ?? "Unavailable"
            let values = [
                "App CPU: " + cpu, "App memory (RSS): " + memory,
                "Transcription helpers: " + sampler.asrText,
                "Speaker-analysis helpers: " + sampler.speakerText,
            ]
            for (label, value) in zip(labels, values) where label.stringValue != value {
                label.stringValue = value
            }
        }
        private var observers: [NSObjectProtocol] = []
        private var last: Bool?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            for observer in observers { NotificationCenter.default.removeObserver(observer) };
            observers = []
            observers.append(
                NotificationCenter.default.addObserver(
                    forName: NSView.frameDidChangeNotification, object: self, queue: .main
                ) { [weak self] _ in self?.refresh() })
            if let window {
                for name in [
                    NSWindow.didChangeOcclusionStateNotification,
                    NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification,
                    NSWindow.willCloseNotification,
                ] {
                    observers.append(
                        NotificationCenter.default.addObserver(
                            forName: name, object: window, queue: .main
                        ) { [weak self] _ in self?.refresh() })
                }
                for name in [
                    NSApplication.didHideNotification, NSApplication.didUnhideNotification,
                ] {
                    observers.append(
                        NotificationCenter.default.addObserver(
                            forName: name, object: nil, queue: .main
                        ) { [weak self] _ in self?.refresh() })
                }
            }
            if let clip = enclosingScrollView?.contentView {
                clip.postsBoundsChangedNotifications = true
                observers.append(
                    NotificationCenter.default.addObserver(
                        forName: NSView.boundsDidChangeNotification, object: clip, queue: .main
                    ) { [weak self] _ in self?.refresh() })
            }
            refresh()
        }
        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview(); refresh()
        }
        override func layout() { super.layout(); refresh() }
        func refresh() {
            let visible =
                !isHiddenOrHasHiddenAncestor && !bounds.intersection(visibleRect).isEmpty
                && window?.isVisible == true && window?.isMiniaturized == false
                && window?.occlusionState.contains(.visible) == true && !NSApp.isHidden
            if last != visible {
                last = visible
                visible ? sampler.start() : sampler.stop()
            }
        }
        deinit {
            for observer in observers { NotificationCenter.default.removeObserver(observer) }
        }
    }
}
