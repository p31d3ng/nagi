import XCTest
@testable import JournalCore
final class EnrollmentTests: XCTestCase {
    var root: URL!
    var store: Store!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "nagi-enroll-test-\(UUID())")
        store = try Store(root: root)
    }
    override func tearDownWithError() throws {
        store = nil; try? FileManager.default.removeItem(at: root)
    }
    func testEmptyEnrollmentCannotReportSavedAndPreservesPriorProfile() throws {
        let prior = String(
            data: try JSONEncoder().encode(Array(repeating: Float(0.1), count: 256)),
            encoding: .utf8)!
        try store.exec("INSERT INTO profiles VALUES('Me',?,?,0)", [prior, Enrollment.model])
        let id = try store.createSession(title: "Enrollment", device: "fixture", model: "unified")
        try store.set("enrollment-session", id); try store.finish(id)
        try Enrollment.finalize(store)
        XCTAssertTrue(store.setting("enrollment-result").contains("No usable"))
        XCTAssertEqual(try store.exec("SELECT embedding FROM profiles").first?["embedding"], prior)
    }
    func testProfileCommitsOnlyAfterWholeSampleAndDoesNotCommitTwice() throws {
        let vector = Array(repeating: Float(0.1), count: 256)
        let encoded = String(data: try JSONEncoder().encode(vector), encoding: .utf8)!
        let id = try store.createSession(title: "Enrollment", device: "fixture", model: "unified")
        try store.set("enrollment-session", id)
        let chunk = try store.registerChunk(
            session: id, path: "audio/a.caf", captured: Date().timeIntervalSince1970, offset: 0,
            model: "unified")
        try store.seal(chunk, duration: 10);
        try store.exec("UPDATE chunks SET status='done' WHERE id=?", [chunk])
        try store.exec("INSERT INTO enrollment_vectors VALUES(?,?,?)", [id, chunk, encoded])
        try Enrollment.finalize(store);
        XCTAssertTrue(try store.exec("SELECT * FROM profiles").isEmpty)
        try store.finish(id); try Enrollment.finalize(store)
        XCTAssertEqual(
            try store.exec("SELECT model FROM profiles").first?["model"], Enrollment.model)
        try store.exec("DELETE FROM profiles"); try Enrollment.finalize(store)
        XCTAssertTrue(try store.exec("SELECT * FROM profiles").isEmpty)
    }
    func testInconsistentOrInvalidEnrollmentRejected() throws {
        var a = Array(repeating: Float(0), count: 256); a[0] = 1
        var b = Array(repeating: Float(0), count: 256); b[1] = 1
        XCTAssertThrowsError(try Enrollment.centroid([a, b]))
        var ambiguous = Array(repeating: Float(0), count: 256)
        ambiguous[0] = 0.75; ambiguous[1] = sqrt(1 - 0.75 * 0.75)
        XCTAssertThrowsError(try Enrollment.centroid([a, ambiguous]))
        XCTAssertThrowsError(try Enrollment.centroid([Array(repeating: 0, count: 256)]))
        XCTAssertThrowsError(try Enrollment.centroid([[1, 2, 3]]))
        let c = try Enrollment.centroid([a, a])
        XCTAssertEqual(VoiceMatch.label(score: VoiceMatch.cosine(a, c), runnerUp: 0), "Me")
    }
}
