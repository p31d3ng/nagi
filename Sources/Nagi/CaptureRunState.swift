import Foundation

/// Owns error provenance across asynchronous capture callbacks and cancellation cleanup.
@MainActor final class CaptureRunState {
    enum Outcome: Equatable {
        case cancelled
        case failed(String)
        var message: String {
            switch self {
            case .cancelled: return "Startup cancelled · any accepted audio was saved"
            case .failed(let message): return message
            }
        }
        func preservingFailure(_ cleanupError: Error) -> Outcome {
            if case .failed = self { return self }
            return .failed(cleanupError.localizedDescription)
        }
    }
    private var token: UUID?
    private var session: String?
    private var source: ObjectIdentifier?
    private var failure: String?
    var hasFailure: Bool { failure != nil }

    func begin() -> UUID {
        let next = UUID()
        token = next
        session = nil
        source = nil
        failure = nil
        return next
    }
    func bind(_ run: UUID, session: String, source: AnyObject?) {
        guard token == run else { return }
        self.session = session
        self.source = source.map(ObjectIdentifier.init)
    }
    @discardableResult func fail(
        _ run: UUID, session: String, source: AnyObject? = nil, message: String
    ) -> Bool {
        guard token == run, self.session == session else { return false }
        if let source, self.source != ObjectIdentifier(source) { return false }
        if failure == nil { failure = message }
        return true
    }
    func outcome(_ run: UUID, error: Error) -> Outcome {
        if token == run, let failure { return .failed(failure) }
        return error is CancellationError ? .cancelled : .failed(error.localizedDescription)
    }
    func end(_ run: UUID? = nil) {
        guard run == nil || token == run else { return }
        token = nil
        session = nil
        source = nil
        failure = nil
    }
}
