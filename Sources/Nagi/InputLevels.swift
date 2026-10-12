import AppKit
import Combine
import Foundation
import SwiftUI

struct InputLevelSnapshot: Equatable {
    enum State: String { case stopped, waiting, receiving, quiet, noFrames }
    let state: State
    let db: Double
    var fraction: Double {
        state == .stopped || state == .waiting || state == .noFrames
            ? 0 : max(0, min(1, (db + 60) / 60))
    }
    var description: String {
        switch state {
        case .stopped: return "Stopped"
        case .waiting: return "Waiting for audio frames"
        case .receiving: return "Audio received"
        case .quiet: return "Audio received · quiet"
        case .noFrames: return "No recent audio frames"
        }
    }
    static let stopped = InputLevelSnapshot(state: .stopped, db: -60)
}
/// One bounded slot per source, never one MainActor task per audio callback.
final class InputLevelMailbox: @unchecked Sendable {
    struct Sample { var rms = 0.0; var last: Double?; var seen = false }
    private let lock = NSLock()
    private var session: String?
    private var systemEnabled = false
    private var mic = Sample(), system = Sample()
    func configure(session: String?, systemEnabled: Bool) {
        lock.lock(); defer { lock.unlock() }
        self.session = session; self.systemEnabled = systemEnabled; mic = Sample();
        system = Sample()
    }
    func offer(
        _ rms: Double, system: Bool, session: String,
        at now: Double = ProcessInfo.processInfo.systemUptime
    ) {
        guard rms.isFinite, rms >= 0 else { return }
        lock.lock(); defer { lock.unlock() }
        guard self.session == session, !system || systemEnabled else { return }
        if system {
            self.system.rms = self.system.seen ? max(self.system.rms, rms) : rms;
            self.system.last = now;
            self.system.seen = true
        } else {
            mic.rms = mic.seen ? max(mic.rms, rms) : rms; mic.last = now; mic.seen = true
        }
    }
    func take() -> (Sample, Sample) {
        lock.lock(); defer { lock.unlock() }
        let value = (mic, system); mic.seen = false;
        system.seen = false
        return value
    }
}
@MainActor final class CaptureClock: ObservableObject {
    @Published var elapsed = 0
    @Published var processingElapsed = 0
}
@MainActor final class CaptureMeter: ObservableObject {
    let clock = CaptureClock()
    @Published var level = 0.0
    var elapsed: Int {
        get { clock.elapsed }
        set { if clock.elapsed != newValue { clock.elapsed = newValue } }
    }
    var processingElapsed: Int {
        get { clock.processingElapsed }
        set { if clock.processingElapsed != newValue { clock.processingElapsed = newValue } }
    }
    @Published var systemLevel = 0.0
    @Published private(set) var microphone = InputLevelSnapshot.stopped
    @Published private(set) var system = InputLevelSnapshot.stopped
    let mailbox = InputLevelMailbox()
    private var timer: Timer?
    private var started: Double?
    private var systemEnabled = false
    func begin(
        session: String, systemEnabled: Bool, now: Double = ProcessInfo.processInfo.systemUptime,
        automatic: Bool = true
    ) {
        stop(); self.started = now; self.systemEnabled = systemEnabled
        mailbox.configure(session: session, systemEnabled: systemEnabled)
        microphone = InputLevelSnapshot(state: .waiting, db: -60)
        system = systemEnabled ? microphone : .stopped
        if automatic {
            timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.poll() }
            }
            timer?.tolerance = 0.025
        }
    }
    static func snapshot(_ sample: InputLevelMailbox.Sample, started: Double, now: Double)
        -> InputLevelSnapshot
    {
        guard let last = sample.last else {
            return InputLevelSnapshot(state: now - started < 1.5 ? .waiting : .noFrames, db: -60)
        }
        guard now - last < 1.5 else { return InputLevelSnapshot(state: .noFrames, db: -60) }
        let db = sample.rms > 0 ? max(-60, min(0, 20 * log10(sample.rms))) : -60
        return InputLevelSnapshot(state: sample.rms <= 0.001 ? .quiet : .receiving, db: db)
    }
    func poll(now: Double = ProcessInfo.processInfo.systemUptime) {
        guard let started else { return }
        let (mic, sys) = mailbox.take()
        let next = Self.snapshot(mic, started: started, now: now)
        if microphone != next { microphone = next; level = next.fraction }
        let other = systemEnabled ? Self.snapshot(sys, started: started, now: now) : .stopped
        if system != other { system = other; systemLevel = other.fraction }
    }
    func stop() {
        timer?.invalidate(); timer = nil; started = nil; systemEnabled = false
        mailbox.configure(session: nil, systemEnabled: false)
        if microphone != .stopped { microphone = .stopped }
        if system != .stopped { system = .stopped }
        level = 0; systemLevel = 0
    }
}
struct InputLevelBar: NSViewRepresentable {
    let title: String
    let meter: CaptureMeter
    var system = false
    func makeNSView(context: Context) -> LevelView {
        let view = LevelView(); view.title = title
        let publisher = system ? meter.$system : meter.$microphone
        view.subscription = publisher.sink { [weak view] value in
            view?.value = value
            view?.needsDisplay = true
            view?.setAccessibilityValue(value.description + String(format: ", %.0f dBFS", value.db))
        }
        view.setAccessibilityElement(true)
        view.setAccessibilityLabel(title + " input level")
        return view
    }
    func updateNSView(_ view: LevelView, context: Context) {}
    final class LevelView: NSView {
        var title = ""
        var value = InputLevelSnapshot.stopped
        var subscription: AnyCancellable?
        override var isFlipped: Bool { true }
        override func draw(_ dirtyRect: NSRect) {
            let detail =
                value.state == .receiving
                ? String(format: "%.0f dBFS", value.db) : value.description
            (title + " · " + detail as NSString)
                .draw(
                    at: NSPoint(x: 0, y: 0),
                    withAttributes: [
                        .font: NSFont.systemFont(ofSize: 11),
                        .foregroundColor: NSColor.secondaryLabelColor,
                    ])
            for index in 0..<12 {
                let color: NSColor =
                    Double(index) < value.fraction * 12
                    ? (index >= 10 ? .systemOrange : .systemTeal)
                    : NSColor.secondaryLabelColor.withAlphaComponent(0.15)
                color.setFill()
                NSBezierPath(
                    roundedRect: NSRect(x: index * 9, y: 18, width: 7, height: 10),
                    xRadius: 2, yRadius: 2
                )
                .fill()
            }
        }
    }
}
