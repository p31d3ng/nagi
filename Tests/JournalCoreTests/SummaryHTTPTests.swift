import Foundation
import XCTest
@testable import JournalCore

private final class SummaryStubProtocol: URLProtocol, @unchecked Sendable {
    static var status = 200
    static var bytes = Data("{}".utf8)
    static var hosts: [String] = []
    static var contentLength: Int?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.hosts.append(request.url!.host!)
        var headers = ["Content-Type": "application/json"]
        if Self.status == 302 { headers["Location"] = "https://credential-sink.invalid/" }
        if let size = Self.contentLength { headers["Content-Length"] = String(size) }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: Self.status, httpVersion: "HTTP/1.1",
            headerFields: headers)!
        if Self.status == 302 {
            var redirected = URLRequest(url: URL(string: "https://credential-sink.invalid/")!)
            redirected.setValue(
                request.value(forHTTPHeaderField: "Authorization"),
                forHTTPHeaderField: "Authorization")
            client?.urlProtocol(self, wasRedirectedTo: redirected, redirectResponse: response)
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.bytes)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
final class SummaryHTTPTests: XCTestCase {
    override func setUp() {
        SummaryStubProtocol.status = 200; SummaryStubProtocol.bytes = Data("{}".utf8)
        SummaryStubProtocol.hosts = []; SummaryStubProtocol.contentLength = nil
    }
    func testRedirectIsNotFollowedAndCredentialNeverReachesOtherHost() async throws {
        SummaryStubProtocol.status = 302
        let transport = SummaryHTTPTransport(protocolClasses: [SummaryStubProtocol.self])
        let response = try await transport.send(
            endpoint: URL(string: "https://synthetic.invalid/api")!, body: Data("{}".utf8),
            bearer: "SYNTHETIC_ONLY_NOT_A_REAL_CREDENTIAL_1234")
        XCTAssertEqual(response.status, 302)
        XCTAssertEqual(SummaryStubProtocol.hosts, ["synthetic.invalid"])
    }
    func testResponseSizeIsBoundedForDeclaredAndStreamedBodies() async throws {
        for declared in [true, false] {
            SummaryStubProtocol.bytes = Data(repeating: 65, count: 131073)
            SummaryStubProtocol.contentLength = declared ? 131073 : nil
            do {
                _ = try await SummaryHTTPTransport(protocolClasses: [SummaryStubProtocol.self])
                    .send(
                        endpoint: URL(string: "https://synthetic.invalid/api")!,
                        body: Data("{}".utf8), bearer: "SYNTHETIC_ONLY_NOT_A_REAL_CREDENTIAL_1234")
                XCTFail("Oversized response accepted")
            } catch { XCTAssertTrue(error.localizedDescription.contains("128 KiB")) }
        }
    }
    func testBoundedResponseStatusAndBytesReturned() async throws {
        SummaryStubProtocol.status = 429
        let response = try await SummaryHTTPTransport(protocolClasses: [SummaryStubProtocol.self])
            .send(
                endpoint: URL(string: "https://synthetic.invalid/api")!, body: Data("{}".utf8),
                bearer: "SYNTHETIC_ONLY_NOT_A_REAL_CREDENTIAL_1234")
        XCTAssertEqual(response.status, 429); XCTAssertEqual(response.body, Data("{}".utf8))
    }
}
