import Foundation

public struct SummaryHTTPResult: Sendable {
    public var status: Int
    public var body: Data
    public init(status: Int, body: Data) { self.status = status; self.body = body }
}
public protocol SummaryTransport: Sendable {
    func send(endpoint: URL, body: Data, bearer: String) async throws -> SummaryHTTPResult
}
public struct SummaryHTTPTransport: SummaryTransport {
    private let protocolClasses: [AnyClass]?
    public init(protocolClasses: [AnyClass]? = nil) { self.protocolClasses = protocolClasses }
    public func send(endpoint: URL, body: Data, bearer: String) async throws -> SummaryHTTPResult {
        _ = try SummaryEndpoint.validate(endpoint.absoluteString)
        let request = BoundedSummaryRequest()
        return try await withTaskCancellationHandler {
            try await request.run(
                endpoint: endpoint, body: body, bearer: bearer, protocolClasses: protocolClasses)
        } onCancel: {
            request.cancel()
        }
    }
}
/// A serial URLSession delegate bounds response memory and rejects every redirect.
private final class BoundedSummaryRequest: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionDataTask?
    private var session: URLSession?
    private var cancelled = false
    private var response: HTTPURLResponse?
    private var bytes = Data()
    private var oversized = false
    private var continuation: CheckedContinuation<SummaryHTTPResult, Error>?
    func run(endpoint: URL, body: Data, bearer: String, protocolClasses: [AnyClass]?) async throws
        -> SummaryHTTPResult
    {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock(); defer { lock.unlock() }
            if cancelled { continuation.resume(throwing: CancellationError()); return }
            self.continuation = continuation
            let config = URLSessionConfiguration.ephemeral
            if let protocolClasses { config.protocolClasses = protocolClasses }
            config.urlCache = nil; config.httpCookieStorage = nil; config.urlCredentialStorage = nil
            config.httpShouldSetCookies = false; config.timeoutIntervalForRequest = 65
            config.timeoutIntervalForResource = 65
            let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1
            queue.qualityOfService = .utility
            let session = URLSession(configuration: config, delegate: self, delegateQueue: queue)
            self.session = session
            var request = URLRequest(url: endpoint)
            request.httpMethod = "POST"; request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer " + bearer, forHTTPHeaderField: "Authorization")
            request.setValue("Nagi/0.4.0", forHTTPHeaderField: "User-Agent")
            let task = session.dataTask(with: request); self.task = task; task.resume()
        }
    }
    func cancel() { lock.lock(); cancelled = true; task?.cancel(); lock.unlock() }
    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) { self.response = response; completionHandler(nil) }
    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        self.response = response as? HTTPURLResponse
        if response.expectedContentLength > 131072 {
            oversized = true; completionHandler(.cancel)
        } else {
            completionHandler(.allow)
        }
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        if bytes.count + data.count > 131072 {
            oversized = true; dataTask.cancel()
        } else {
            bytes.append(data)
        }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?)
    {
        lock.lock()
        let c = continuation; continuation = nil
        let wasCancelled = cancelled
        self.task = nil; self.session = nil
        lock.unlock()
        defer { session.finishTasksAndInvalidate() }
        guard let c else { return }
        if oversized {
            c.resume(
                throwing: JournalError(
                    "Service response exceeded 128 KiB. It may have processed the request; retry manually."
                ))
        } else if wasCancelled {
            c.resume(throwing: CancellationError())
        } else if error != nil {
            c.resume(
                throwing: JournalError(
                    "Network request failed or timed out. The service may have processed it. No automatic retry will occur."
                ))
        } else if let response {
            c.resume(returning: SummaryHTTPResult(status: response.statusCode, body: bytes))
        } else {
            c.resume(
                throwing: JournalError(
                    "No response. The service may have processed the request; retry manually."))
        }
    }
}
