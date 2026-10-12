import AVFoundation
import XCTest
@testable import Nagi

@MainActor final class PermissionsTests: XCTestCase {
    func testRefreshDoesNotRequestAndReflectsSettingsTransitions() {
        var status: AVAuthorizationStatus = .notDetermined
        var requests = 0
        let permission = MicrophonePermission(read: { status }, ask: { _ in requests += 1 })
        XCTAssertEqual(permission.state, .notDetermined)
        for value: AVAuthorizationStatus in [.authorized, .denied, .restricted, .notDetermined] {
            status = value; permission.refresh()
            XCTAssertEqual(permission.state, value)
            XCTAssertFalse(permission.explanation.isEmpty)
        }
        XCTAssertEqual(requests, 0)
    }
    func testKnownStatesNeverRequestAgain() {
        for status: AVAuthorizationStatus in [.authorized, .denied, .restricted] {
            var requests = 0
            var allowed: Bool?
            let permission = MicrophonePermission(read: { status }, ask: { _ in requests += 1 })
            permission.request { allowed = $0 }
            XCTAssertEqual(requests, 0)
            XCTAssertEqual(allowed, status == .authorized)
            XCTAssertFalse(permission.requesting)
        }
    }
    func testPendingRequestIsSingleFlightAndReadsActualResult() async {
        var status: AVAuthorizationStatus = .notDetermined
        var callback: ((Bool) -> Void)?
        var requests = 0
        var results: [Bool] = []
        let permission = MicrophonePermission(
            read: { status },
            ask: {
                requests += 1; callback = $0
            })
        permission.request { results.append($0) }
        permission.request { results.append($0) }
        XCTAssertEqual(requests, 1)
        XCTAssertTrue(permission.requesting)
        status = .authorized
        callback?(true)
        await Task.yield()
        XCTAssertEqual(permission.state, .authorized)
        XCTAssertFalse(permission.requesting)
        XCTAssertEqual(results, [true])
        permission.request { results.append($0) }
        XCTAssertEqual(requests, 1)
        XCTAssertEqual(results, [true, true])
    }
    func testDenialDoesNotRetryAndRevocationRefreshes() async {
        var status: AVAuthorizationStatus = .notDetermined
        var callback: ((Bool) -> Void)?
        var requests = 0
        var allowed: Bool?
        let permission = MicrophonePermission(
            read: { status },
            ask: {
                requests += 1; callback = $0
            })
        permission.request { allowed = $0 }
        status = .denied; callback?(false)
        await Task.yield()
        XCTAssertEqual(allowed, false)
        permission.request()
        XCTAssertEqual(requests, 1)
        status = .authorized; permission.refresh()
        status = .restricted; permission.refresh()
        XCTAssertEqual(permission.state, .restricted)
        XCTAssertEqual(requests, 1)
    }
}
