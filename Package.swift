// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Nagi", platforms: [.macOS(.v15)],
    products: [
        .executable(name: "Nagi", targets: ["Nagi"]),
        .executable(name: "SpeakerWorker", targets: ["SpeakerWorker"]),
        .executable(name: "JournalHarness", targets: ["JournalHarness"]),
    ], dependencies: [.package(path: "../Dependencies/FluidAudio", traits: [])],
    targets: [
        .systemLibrary(name: "CSQLite", pkgConfig: "sqlite3"),
        .target(name: "JournalCore", dependencies: ["CSQLite"]),
        .executableTarget(name: "Nagi", dependencies: ["JournalCore"]),
        .executableTarget(
            name: "SpeakerWorker",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio")]),
        .executableTarget(name: "JournalHarness", dependencies: ["JournalCore"]),
        .testTarget(name: "JournalCoreTests", dependencies: ["JournalCore"]),
        .testTarget(name: "SummaryAppTests", dependencies: ["Nagi", "JournalCore"]),
    ], swiftLanguageModes: [.v5])
