import Foundation
import Combine
import XCTest
@testable import JournalCore
@testable import Nagi

private final class ReadCount: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    func increment() { lock.lock(); defer { lock.unlock() }; calls += 1 }
    var value: Int { lock.lock(); defer { lock.unlock() }; return calls }
}
@MainActor final class LivePageLoaderTests: XCTestCase {
    func testSlowDatabaseReadDoesNotBlockMainActorAndCoalescesRevisions() async throws {
        let calls = ReadCount()
        let loader = LivePageLoader(read: { session, _ in
            calls.increment()
            Thread.sleep(forTimeInterval: 0.08)  // Simulated SQLite contention, not a UI delay.
            return [LiveParagraph(id: session, offset: 0, text: "Synthetic", detail: "Unknown")]
        })
        let completed = expectation(description: "Latest rows published")
        let subscription = loader.$rows.sink { rows in
            if rows.first?.id == "latest-99" { completed.fulfill() }
        }
        defer { subscription.cancel() }
        let start = Date()
        loader.load(session: "first", before: .greatestFiniteMagnitude)
        for i in 0..<100 { loader.load(session: "latest-\(i)", before: .greatestFiniteMagnitude) }
        let scheduling = Date().timeIntervalSince(start)
        XCTAssertLessThan(scheduling, 0.02)
        // If the read ran on MainActor, this yield could not resume while it slept.
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertTrue(loader.rows.isEmpty)
        await fulfillment(of: [completed], timeout: 3)
        XCTAssertEqual(loader.rows.first?.id, "latest-99")
        let count = calls.value
        XCTAssertLessThanOrEqual(count, 2)
        print(
            "NAV_MAIN_ACTOR_PROFILE requests=101 scheduling_s=\(scheduling) simulated_read_s=0.08 read_calls=\(count)"
        )
    }
    func testCancelledReadCannotPublishStaleRows() async throws {
        let loader = LivePageLoader(read: { session, _ in
            Thread.sleep(forTimeInterval: 0.03)
            return [LiveParagraph(id: session, offset: 0, text: "Synthetic", detail: "Unknown")]
        })
        loader.load(session: "old", before: .greatestFiniteMagnitude)
        loader.clear()
        try await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertTrue(loader.rows.isEmpty)
        let completed = expectation(description: "New rows published")
        let subscription = loader.$rows.sink { rows in
            if rows.first?.id == "new" { completed.fulfill() }
        }
        defer { subscription.cancel() }
        loader.load(session: "new", before: .greatestFiniteMagnitude)
        await fulfillment(of: [completed], timeout: 3)
        XCTAssertEqual(loader.rows.first?.id, "new")
    }
    func testLargeSyntheticDocumentPageProfile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try Store(root: root)
        let id = try store.createSession(
            title: "Synthetic navigation benchmark", device: "synthetic", model: "unified")
        try store.transaction {
            for i in 0..<5000 {
                try store.insertSegment(
                    session: id, offset: Double(i), end: Double(i + 1),
                    raw: "Synthetic navigation text", corrected: "Synthetic navigation text",
                    speaker: "Unknown", language: "en", chunk: "synthetic")
            }
        }
        let start = Date()
        for _ in 0..<50 { XCTAssertEqual(try LiveDocument.page(store, session: id).count, 200) }
        let wall = Date().timeIntervalSince(start)
        print("NAV_SQL_PROFILE segments=5000 pages=50 wall_s=\(wall) mean_page_ms=\(wall*20)")
    }
}
