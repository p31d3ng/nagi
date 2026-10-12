import Foundation
import JournalCore
import SwiftUI

/// One DB read at a time; rapid revisions coalesce to the latest request.
@MainActor final class LivePageLoader: ObservableObject {
    @Published private(set) var rows: [LiveParagraph] = []
    @Published private(set) var message = ""
    private let lane = DispatchQueue(label: "nagi.live.page", qos: .utility)
    private var generation = 0
    private var running = false
    private var pending: (Int, String, Double)?
    private var visibleSession = ""
    private var visibleBefore = Double.greatestFiniteMagnitude
    private let read: @Sendable (String, Double) throws -> [LiveParagraph]
    init(read: @escaping @Sendable (String, Double) throws -> [LiveParagraph]) { self.read = read }
    func load(session: String, before: Double) {
        // Refreshes within the same page must not invalidate an active read: otherwise
        // sustained revisions can starve publication forever. Only context changes cancel it.
        if visibleSession != session || visibleBefore != before {
            generation += 1
            if visibleSession != session { rows = [] }
            visibleSession = session; visibleBefore = before
        }
        pending = (generation, session, before)
        runNext()
    }
    func clear() { cancel(); rows = []; visibleSession = ""; message = "" }
    func cancel() { generation += 1; pending = nil }
    private func runNext() {
        guard !running, let request = pending else { return }
        pending = nil; running = true
        let read = read
        lane.async {
            let result = Result { try read(request.1, request.2) }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if request.0 == self.generation {
                    switch result {
                    case .success(let rows):
                        if self.rows != rows { self.rows = rows }; self.message = ""
                    case .failure:
                        self.message =
                            "Saved audio is safe. Could not refresh text; try reopening Live."
                    }
                }
                self.running = false
                self.runNext()
            }
        }
    }
}
