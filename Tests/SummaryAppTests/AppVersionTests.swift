import XCTest
@testable import Nagi

final class AppVersionTests: XCTestCase {
    func testDisplaysBundleVersionAndBuild() {
        let value = AppVersion(info: [
            "CFBundleShortVersionString": "1.2.3", "CFBundleVersion": "42",
        ])
        XCTAssertEqual(value.sidebar, "Version 1.2.3")
        XCTAssertEqual(value.details, "Version 1.2.3 · Build 42")
    }
    func testMissingDebugMetadataDoesNotInventAReleaseVersion() {
        let value = AppVersion(info: [:])
        XCTAssertEqual(value.sidebar, "Development build · version unavailable")
        XCTAssertTrue(value.details.contains("build number unavailable"))
    }
    func testIncompleteOrMalformedMetadataIsHonest() {
        let value = AppVersion(info: ["CFBundleShortVersionString": " \n", "CFBundleVersion": 9])
        XCTAssertNil(value.version)
        XCTAssertNil(value.build)
        let partial = AppVersion(info: ["CFBundleShortVersionString": "0.4.2"])
        XCTAssertEqual(partial.details, "Version 0.4.2 · build number unavailable")
    }
}
