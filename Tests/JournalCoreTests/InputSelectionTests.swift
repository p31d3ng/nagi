import XCTest
@testable import JournalCore

final class InputSelectionTests: XCTestCase {
    func testDisconnectReconnectKeepsUIDAndNeverChoosesFallback() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try Store(root: root)
        let receiver = InputDevice(id: "receiver-stable", name: "Test receiver", audioID: 42)
        let other = InputDevice(id: "other", name: "Other input", audioID: 43)
        try InputSelection.persist(
            uid: receiver.id, devices: [receiver, other], recording: false, store: store)
        XCTAssertEqual(store.setting("inputUID"), receiver.id)
        XCTAssertEqual(
            InputSelection.message(uid: receiver.id, devices: [other]),
            "Selected input disconnected")
        XCTAssertEqual(store.setting("inputUID"), receiver.id)
        XCTAssertEqual(
            InputSelection.message(uid: receiver.id, devices: [receiver, other]), receiver.name)
        XCTAssertEqual(store.setting("inputUID"), receiver.id)
    }
    func testRecordingOrStaleMenuCannotChangeSavedSelection() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try Store(root: root)
        try store.set("inputUID", "old")
        try store.set("model", "unified")
        let other = InputDevice(id: "other", name: "Other input", audioID: 43)
        XCTAssertThrowsError(
            try InputSelection.persist(
                uid: other.id, devices: [other], recording: true, store: store))
        XCTAssertThrowsError(
            try InputSelection.persist(
                uid: "gone", devices: [other], recording: false, store: store))
        XCTAssertEqual(store.setting("inputUID"), "old")
        try InputSelection.persist(uid: other.id, devices: [other], recording: false, store: store)
        XCTAssertEqual(store.setting("inputUID"), other.id)
        XCTAssertEqual(store.setting("model"), "unified")
    }
    func testNoDevicesAndNoSelectionAreDistinct() {
        let device = InputDevice(id: "other", name: "Other input", audioID: 43)
        XCTAssertEqual(InputSelection.message(uid: "", devices: []), "No input devices available")
        XCTAssertEqual(InputSelection.message(uid: "", devices: [device]), "Choose an input")
        XCTAssertEqual(
            InputSelection.message(uid: "gone", devices: []), "Selected input disconnected")
    }
}
