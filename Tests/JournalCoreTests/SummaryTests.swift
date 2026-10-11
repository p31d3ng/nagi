import Darwin
import Foundation
import XCTest
@testable import JournalCore

final class SummaryTests: XCTestCase {
    var root: URL!
    var store: Store!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "summary-test-" + UUID().uuidString)
        store = try Store(root: root)
    }
    override func tearDownWithError() throws {
        store = nil; try? FileManager.default.removeItem(at: root)
    }
    func fixture(count: Int = 2, text: String = "Synthetic", speaker: String = "Unknown") throws
        -> String
    {
        let id = try store.createSession(title: "Synthetic", device: "fixture", model: "unified")
        let chunk = try store.registerChunk(
            session: id, path: "", captured: Date().timeIntervalSince1970, offset: 0,
            model: "unified")
        for i in 0..<count {
            try store.insertSegment(
                session: id, offset: Double(i), end: Double(i + 1), raw: text, corrected: text,
                speaker: speaker, language: "ja", chunk: chunk)
        }
        try store.exec("UPDATE chunks SET status='done' WHERE id=?", [chunk])
        try store.finish(id)
        return id
    }
    func testEndpointValidationAndExactCredentialBindingIdentity() throws {
        for invalid in [
            "http://example.test/api", "https://u:p@example.test/api",
            "https://example.test/api?token=x", "https://example.test/api#x", "https:///api",
        ] {
            XCTAssertThrowsError(try SummaryEndpoint.validate(invalid))
        }
        XCTAssertEqual(
            try SummaryEndpoint.validate("https://EXAMPLE.test:443/api").absoluteString,
            "https://example.test/api")
        XCTAssertNotEqual(
            try SummaryEndpoint.validate("https://example.test/api"),
            try SummaryEndpoint.validate("https://other.test/api"))
    }
    func testFinalizationNeverUsesPreviewAndWaitsForSpeakers() throws {
        let id = try fixture()
        try store.exec("UPDATE sessions SET status='recording' WHERE id=?", [id])
        XCTAssertThrowsError(try SummaryStorage.snapshot(store, session: id))
        try store.finish(id)
        try store.exec("UPDATE chunks SET status='needs_speakers' WHERE session=?", [id])
        XCTAssertThrowsError(try SummaryStorage.snapshot(store, session: id))
        try store.exec("UPDATE chunks SET status='done' WHERE session=?", [id])
        let snap = try SummaryStorage.snapshot(store, session: id)
        XCTAssertEqual(snap.input.segments.count, 1)
        XCTAssertEqual(snap.input.segments[0].text, "Synthetic Synthetic")
        XCTAssertTrue(snap.input.segments[0].uncertain)
        XCTAssertEqual(snap.input.segments[0].attribution, "unknown")
        XCTAssertTrue(snap.input.final)
        try store.exec("UPDATE chunks SET status='expired' WHERE session=?", [id])
        XCTAssertNoThrow(try SummaryStorage.snapshot(store, session: id))
    }
    func testExportDoesNotUseTimelineLimitOrSilentlyTruncate() throws {
        let id = try fixture(count: 2001, text: "x")
        XCTAssertEqual(try store.segments(session: id).count, 2000)
        let snap = try SummaryStorage.snapshot(store, session: id)
        XCTAssertEqual(
            snap.input.segments.map(\.text).joined(separator: " ").split(separator: " ").count, 2001
        )
        let large = try fixture(count: 20, text: String(repeating: "x", count: 1000))
        XCTAssertThrowsError(try SummaryStorage.snapshot(store, session: large))
    }
    func testMoreThan64TurnsAndMetadataSizeRejected() throws {
        let id = try fixture(count: 65)
        try store.exec("UPDATE segments SET speaker='Speaker '||id WHERE session=?", [id])
        XCTAssertThrowsError(try SummaryStorage.snapshot(store, session: id))
    }
    func testRevisionChangesOnCorrectionAndSummaryCascadesWithDeletion() throws {
        let id = try fixture()
        let first = try SummaryStorage.snapshot(store, session: id)
        let segment = try store.segments(session: id)[0]
        try store.edit(segment.id, text: "Corrected", speaker: "Me")
        let next = try SummaryStorage.snapshot(store, session: id)
        XCTAssertGreaterThan(next.input.version, first.input.version)
        XCTAssertEqual(next.input.segments[0].attribution, "manual")
        XCTAssertFalse(next.input.segments[0].uncertain)
        try store.exec(
            "INSERT INTO summaries VALUES('test',?,?,?,'done','','{}',0,0)",
            [id, next.input.version, "https://example.test/api"])
        try store.deleteSession(id)
        XCTAssertTrue(try store.exec("SELECT * FROM summaries").isEmpty)
    }
    func testEvidenceValidationRehydratesMetadataAndRequiresReview() throws {
        let id = try fixture()
        let input = try SummaryStorage.snapshot(store, session: id).input
        let t = input.segments[0]
        let source = SummarySource(
            segmentId: t.id, start: 999, end: 999, speakerId: "invented", speakerLabel: "invented",
            uncertain: false, overlap: false)
        let item = SummaryItem(text: "Synthetic", quote: nil, sources: [source])
        let summary = GeneratedSummary(
            overview: "Synthetic", highlights: [item], decisions: [], actionItems: [],
            reviewRequired: false)
        let response = SummaryEnvelope(
            id: id, version: input.version, model: "fixture", summary: summary)
        let checked = try response.checked(against: input)
        XCTAssertEqual(checked.summary.highlights[0].sources[0].start, t.start)
        XCTAssertEqual(checked.summary.highlights[0].sources[0].speakerLabel, "Unknown")
        XCTAssertTrue(checked.summary.reviewRequired)
        var invalid = response; invalid.version += 1
        XCTAssertThrowsError(try invalid.checked(against: input))
        invalid = response; invalid.summary.highlights[0].sources[0].segmentId = "missing"
        XCTAssertThrowsError(try invalid.checked(against: input))
    }
    func testExportStressResourceProxyAndSummaryCapacity() throws {
        let id = try fixture(count: 12, text: "Synthetic budget discussion")
        var before = rusage(); getrusage(RUSAGE_SELF, &before)
        let started = ProcessInfo.processInfo.systemUptime
        var peak = 0
        for _ in 0..<1000 {
            peak = max(peak, try SummaryStorage.snapshot(store, session: id).body.count)
        }
        let wall = ProcessInfo.processInfo.systemUptime - started
        var after = rusage(); getrusage(RUSAGE_SELF, &after)
        func cpu(_ r: rusage) -> Double {
            Double(r.ru_utime.tv_sec + r.ru_stime.tv_sec) + Double(
                r.ru_utime.tv_usec + r.ru_stime.tv_usec) / 1_000_000
        }
        print(
            "SUMMARY_EXPORT_PROFILE operations=1000 wall_s=\(wall) cpu_s=\(cpu(after)-cpu(before)) max_body_bytes=\(peak) process_max_rss_bytes=\(after.ru_maxrss)"
        )
        XCTAssertLessThanOrEqual(peak, 16384)
        try store.exec(
            "INSERT INTO summaries VALUES('capacity',?,1,?,'done','',?,0,0)",
            [id, SummaryEndpoint.suggested, String(repeating: "x", count: 2000)])
        _ = try store.cleanup(cap: 1000)
        XCTAssertTrue(try store.exec("SELECT id FROM sessions WHERE id=?", [id]).isEmpty)
    }

    func testQuotedCategoriesRejectSmuggledTextAndEmptyEvidence() throws {
        let id = try fixture()
        let input = try SummaryStorage.snapshot(store, session: id).input
        let t = input.segments[0]
        let source = SummarySource(
            segmentId: t.id, start: t.start, end: t.end, speakerId: t.speakerId,
            speakerLabel: t.speakerLabel, uncertain: t.uncertain, overlap: t.overlap)
        for quote in ["", "   "] {
            let item = SummaryItem(text: nil, quote: quote, sources: [source])
            let summary = GeneratedSummary(
                overview: "Synthetic", highlights: [], decisions: [item], actionItems: [],
                reviewRequired: true)
            XCTAssertThrowsError(
                try SummaryEnvelope(
                    id: id, version: input.version, model: "fixture", summary: summary
                )
                .checked(against: input))
        }
        let malicious = SummaryItem(
            text: "Fabricated assignment", quote: "Synthetic", sources: [source])
        let summary = GeneratedSummary(
            overview: "Synthetic", highlights: [], decisions: [], actionItems: [malicious],
            reviewRequired: true)
        XCTAssertThrowsError(
            try SummaryEnvelope(id: id, version: input.version, model: "fixture", summary: summary)
                .checked(against: input))
    }
    func testCompletedChunkReceiptSurvivesExpiryBeforeConversationFinalization() throws {
        let id = try store.createSession(
            title: "Synthetic expiry race", device: "fixture", model: "unified")
        let first = try store.registerChunk(
            session: id, path: "", captured: 1, offset: 0, model: "unified")
        let second = try store.registerChunk(
            session: id, path: "", captured: Date().timeIntervalSince1970, offset: 2,
            model: "unified")
        try store.insertSegment(
            session: id, offset: 0, end: 1, raw: "First", corrected: "First", speaker: "Unknown",
            language: "en", chunk: first)
        try store.insertSegment(
            session: id, offset: 2, end: 3, raw: "Second", corrected: "Second", speaker: "Unknown",
            language: "en", chunk: second)
        try store.exec("UPDATE chunks SET status='done' WHERE id=?", [first])
        try store.exec("UPDATE chunks SET status='processing' WHERE id=?", [second]);
        try store.finish(id)
        XCTAssertFalse(try SummaryStorage.ready(store, session: id))
        _ = try store.cleanup(cap: 0)
        XCTAssertEqual(try store.chunk(first)?.status, "expired")
        XCTAssertFalse(try SummaryStorage.ready(store, session: id))
        // This completion occurs after the earlier expiry pass's readiness check.
        try store.exec("UPDATE chunks SET status='done' WHERE id=?", [second])
        _ = try store.cleanup(now: Date().timeIntervalSince1970 + 172801, cap: 0)
        XCTAssertEqual(try store.chunk(second)?.status, "expired")
        let snapshot = try SummaryStorage.snapshot(store, session: id)
        XCTAssertTrue(snapshot.input.segments.map(\.text).joined(separator: " ").contains("Second"))
        // Reprocessing invalidates old completion proof; expiry cannot bless failed work.
        try store.exec("UPDATE chunks SET status='failed' WHERE id=?", [second])
        try store.exec("UPDATE chunks SET status='expired' WHERE id=?", [second])
        XCTAssertThrowsError(try SummaryStorage.snapshot(store, session: id))
    }

}
