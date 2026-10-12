import Foundation
import XCTest
@testable import JournalCore
@testable import Nagi

private final class MemoryVault: SummaryCredentialVault {
    var values: [String: String] = [:]
    func contains(endpoint: URL) -> Bool { values[endpoint.absoluteString] != nil }
    func read(endpoint: URL) throws -> String {
        guard let value = values[endpoint.absoluteString] else {
            throw JournalError("Missing test credential")
        }; return value
    }
    func save(_ bearer: String, endpoint: URL) throws { values[endpoint.absoluteString] = bearer }
    func delete(endpoint: URL) throws { values.removeValue(forKey: endpoint.absoluteString) }
}
private actor FakeSummaryTransport: SummaryTransport {
    var calls = 0
    var status: Int
    var delay: UInt64
    var echo: Bool
    init(status: Int = 200, delay: UInt64 = 0, echo: Bool = false) {
        self.status = status; self.delay = delay; self.echo = echo
    }
    func count() -> Int { calls }
    func send(endpoint: URL, body: Data, bearer: String) async throws -> SummaryHTTPResult {
        calls += 1
        if delay > 0 { try await Task.sleep(nanoseconds: delay) }
        let input = try JSONDecoder().decode(SummaryInput.self, from: body)
        let payload: [String: Any] = [
            "id": input.id, "version": input.version, "model": "synthetic",
            "summary": [
                "overview": echo ? bearer : "Synthetic summary", "highlights": [], "decisions": [],
                "actionItems": [], "reviewRequired": true,
            ],
        ]
        return SummaryHTTPResult(
            status: status, body: try JSONSerialization.data(withJSONObject: payload))
    }
}
@MainActor final class SummaryControllerTests: XCTestCase {
    var root: URL!
    var store: Store!
    private var vault: MemoryVault!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "summary-controller-" + UUID().uuidString)
        store = try Store(root: root); vault = MemoryVault()
        try vault.save(
            "SYNTHETIC_ONLY_NOT_A_REAL_CREDENTIAL_1234",
            endpoint: SummaryEndpoint.validate(SummaryEndpoint.suggested))
    }
    override func tearDownWithError() throws {
        store = nil; try? FileManager.default.removeItem(at: root)
    }
    func fixture() throws -> String {
        let id = try store.createSession(title: "Synthetic", device: "fixture", model: "unified")
        let chunk = try store.registerChunk(
            session: id, path: "", captured: Date().timeIntervalSince1970, offset: 0,
            model: "unified")
        try store.insertSegment(
            session: id, offset: 0, end: 1, raw: "Synthetic", corrected: "Synthetic", speaker: "Me",
            language: "en", chunk: chunk)
        try store.exec("UPDATE chunks SET status='done' WHERE id=?", [chunk]); try store.finish(id);
        return id
    }
    func settle(_ controller: SummaryController) async throws {
        for _ in 0..<200 {
            if controller.busySession == nil { return };
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("Summary did not settle")
    }
    func testAutomaticIsOptInOnlyNewArmedSessionsAndNoRestartDuplicates() async throws {
        let old = try fixture(); let transport = FakeSummaryTransport()
        let c = SummaryController(
            store: store, networkAllowed: true, vault: vault, transport: transport)
        XCTAssertFalse(c.automatic); c.setAutomatic(true); c.observe(selected: old)
        var count = await transport.count(); XCTAssertEqual(count, 0)
        let next = try fixture(); c.arm(session: next)
        try store.exec("UPDATE sessions SET status='recording' WHERE id=?", [next]);
        c.observe(selected: next)
        count = await transport.count(); XCTAssertEqual(count, 0)
        try store.finish(next); c.observe(selected: next); try await settle(c)
        count = await transport.count(); XCTAssertEqual(count, 1)
        for _ in 0..<10 { c.observe(selected: next) }
        let restarted = SummaryController(
            store: store, networkAllowed: true, vault: vault, transport: transport)
        restarted.observe(selected: next)
        count = await transport.count(); XCTAssertEqual(count, 1)
        XCTAssertEqual(c.latest?["status"], "done")
    }
    func testDisableRevokesPendingAndEndpointChangeDoesNotCopyCredentials() async throws {
        let id = try fixture(); let t = FakeSummaryTransport()
        let c = SummaryController(store: store, networkAllowed: true, vault: vault, transport: t)
        c.setAutomatic(true); c.arm(session: id); c.setAutomatic(false); c.setAutomatic(true);
        c.observe(selected: id)
        let count = await t.count(); XCTAssertEqual(count, 0)
        c.endpointText = "https://another.example/api"; c.saveEndpoint()
        XCTAssertFalse(c.credentialAvailable); XCTAssertFalse(c.automatic)
    }
    func testInterruptedClaimIsUncertainAndNeverAutoRetried() async throws {
        let id = try fixture(); try store.set("summary-automatic", "true")
        try store.exec(
            "INSERT INTO summary_auto VALUES(?,?,'attempted')", [id, SummaryEndpoint.suggested])
        try store.exec(
            "INSERT INTO summaries VALUES('lost',?,1,?,'sending','','',0,1)",
            [id, SummaryEndpoint.suggested])
        let t = FakeSummaryTransport();
        let c = SummaryController(store: store, networkAllowed: true, vault: vault, transport: t)
        c.observe(selected: id)
        XCTAssertEqual(c.latest?["status"], "uncertain")
        let count = await t.count(); XCTAssertEqual(count, 0)
    }
    func testRepeatedManualClicksAreSingleFlightAndEditedResponseIsStale() async throws {
        let id = try fixture(); let t = FakeSummaryTransport(delay: 80_000_000)
        let c = SummaryController(store: store, networkAllowed: true, vault: vault, transport: t)
        c.observe(selected: id); c.submit(session: id); c.submit(session: id)
        try await Task.sleep(nanoseconds: 30_000_000)
        let segment = try store.segments(session: id)[0];
        try store.edit(segment.id, text: "Updated", speaker: "Me")
        try await settle(c)
        let count = await t.count(); XCTAssertEqual(count, 1);
        XCTAssertEqual(c.latest?["status"], "stale")
    }
    func testCancellationAndAuthenticationFailuresNeverAutoRetry() async throws {
        let id = try fixture(); let t = FakeSummaryTransport(status: 401)
        let c = SummaryController(store: store, networkAllowed: true, vault: vault, transport: t)
        c.setAutomatic(true); c.arm(session: id); c.observe(selected: id); try await settle(c)
        XCTAssertFalse(c.automatic)
        for _ in 0..<5 { c.observe(selected: id) }
        let count = await t.count(); XCTAssertEqual(count, 1)
        let slow = FakeSummaryTransport(delay: 300_000_000)
        let other = SummaryController(
            store: store, networkAllowed: true, vault: vault, transport: slow)
        other.observe(selected: id); other.submit(session: id)
        try await Task.sleep(nanoseconds: 30_000_000); other.cancel(); try await settle(other)
        XCTAssertEqual(other.latest?["status"], "uncertain")
    }
    func testEchoedCredentialNeverPersistsAndSyntheticMonitorCannotSend() async throws {
        let id = try fixture(); let t = FakeSummaryTransport(echo: true)
        let c = SummaryController(store: store, networkAllowed: true, vault: vault, transport: t)
        c.observe(selected: id); c.submit(session: id); try await settle(c)
        XCTAssertEqual(c.latest?["response"], "")
        let metadata = try store.exec("SELECT value FROM settings")
        XCTAssertFalse(
            metadata.contains {
                $0["value"]?.contains("SYNTHETIC_ONLY_NOT_A_REAL_CREDENTIAL") == true
            })
        let monitor = SummaryController(
            store: store, networkAllowed: false, vault: vault, transport: t)
        monitor.submit(session: id); let count = await t.count(); XCTAssertEqual(count, 1)
    }
    func testNoSpeechAutomaticSessionDoesNotBlockLaterSessions() async throws {
        let empty = try store.createSession(
            title: "Synthetic silence", device: "fixture", model: "unified")
        try store.finish(empty)
        let t = FakeSummaryTransport()
        let c = SummaryController(store: store, networkAllowed: true, vault: vault, transport: t)
        c.setAutomatic(true); c.arm(session: empty); c.observe(selected: empty); try await settle(c)
        var count = await t.count(); XCTAssertEqual(count, 0); XCTAssertTrue(c.automatic)
        let next = try fixture(); c.arm(session: next); c.observe(selected: next);
        try await settle(c)
        count = await t.count(); XCTAssertEqual(count, 1)
    }

    func testManualSubmissionConsumesWaitingAutomaticConsent() async throws {
        let id = try fixture(); let t = FakeSummaryTransport()
        let c = SummaryController(store: store, networkAllowed: true, vault: vault, transport: t)
        c.setAutomatic(true); c.arm(session: id); c.submit(session: id)
        try await settle(c); c.observe(selected: id)
        let count = await t.count(); XCTAssertEqual(count, 1)
        XCTAssertEqual(
            try store.exec("SELECT state FROM summary_auto WHERE session=?", [id]).first?["state"],
            "attempted")
    }

    func testFailedProcessingBacklogCannotStarveFinalizedAutomaticSession() async throws {
        let t = FakeSummaryTransport()
        let c = SummaryController(store: store, networkAllowed: true, vault: vault, transport: t)
        c.setAutomatic(true)
        for _ in 0..<33 {
            let failed = try fixture(); c.arm(session: failed)
            try store.exec("UPDATE chunks SET status='failed' WHERE session=?", [failed])
        }
        let ready = try fixture(); c.arm(session: ready); c.observe(selected: ready)
        try await settle(c)
        let count = await t.count(); XCTAssertEqual(count, 1)
        XCTAssertEqual(c.latest?["session"], ready)
    }

    func testUnsavedDestinationCannotSendCredentialToPriorTarget() async throws {
        let id = try fixture(); let t = FakeSummaryTransport()
        let c = SummaryController(store: store, networkAllowed: true, vault: vault, transport: t)
        c.setAutomatic(true); c.arm(session: id)
        c.endpointText = "https://different.invalid/api"; c.endpointDraftChanged()
        XCTAssertFalse(c.automatic)
        c.submit(session: id); c.observe(selected: id)
        let count = await t.count(); XCTAssertEqual(count, 0)
        XCTAssertTrue(c.lastMessage.contains("Nothing was sent"))
    }

    func testDualSourcesDoNotArmOrSendWhenAutomaticIsOff() async throws {
        let id = try fixture()
        let first = try XCTUnwrap(try store.chunks(session: id).first)
        try store.exec("UPDATE chunk_sources SET origin='microphone' WHERE chunk=?", [first.id])
        let sys = try store.registerChunk(
            session: id, path: "", captured: Date().timeIntervalSince1970, offset: 0,
            model: "unified", origin: .system)
        try store.exec("UPDATE chunks SET status='done' WHERE id=?", [sys])
        try store.insertSegment(
            session: id, offset: 0, end: 1, raw: "Synthetic remote voice",
            corrected: "Synthetic remote voice", speaker: "Speaker 2", language: "en", chunk: sys)
        let transport = FakeSummaryTransport()
        let controller = SummaryController(
            store: store, networkAllowed: true, vault: vault, transport: transport)
        XCTAssertFalse(controller.automatic)
        controller.arm(session: id)
        controller.observe(selected: id)
        try await Task.sleep(nanoseconds: 50_000_000)
        let calls = await transport.count()
        XCTAssertEqual(calls, 0)
        XCTAssertTrue(try store.exec("SELECT * FROM summary_auto WHERE session=?", [id]).isEmpty)
        XCTAssertTrue(try store.exec("SELECT * FROM summaries WHERE session=?", [id]).isEmpty)
    }

}
