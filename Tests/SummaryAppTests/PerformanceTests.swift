import Darwin
import JournalCore
import XCTest
@testable import Nagi

@MainActor final class PerformanceTests: XCTestCase {
    func testCPUUsesMonotonicDeltasAndResetsForUnavailableOrReusedPID() {
        var delta = CPUDelta()
        func counter(_ id: UInt64, _ cpu: Double) -> ProcessCounter {
            ProcessCounter(identity: id, cpuSeconds: cpu, residentBytes: 1)
        }
        XCTAssertNil(delta.sample(counter(1, 2), at: 10))
        XCTAssertEqual(delta.sample(counter(1, 3), at: 12), 50)
        XCTAssertEqual(delta.sample(counter(1, 3), at: 13), 0)
        XCTAssertNil(delta.sample(counter(2, 8), at: 14))
        XCTAssertNil(delta.sample(nil, at: 15))
        XCTAssertNil(delta.sample(counter(2, 9), at: 16))
        XCTAssertNil(delta.sample(counter(2, 8), at: 17))
    }
    func testHelpersAreSeparateAndTerminationRemovesThem() {
        let registry = WorkerRegistry()
        let id = registry.start(pid: 42, role: .transcription)
        var cpu: Double = 0
        let sampler = PerformanceSampler(
            read: { pid in
                ProcessCounter(identity: UInt64(pid), cpuSeconds: cpu, residentBytes: 1024)
            }, workers: { registry.current() })
        var renders = 0
        sampler.updated = { renders += 1 }
        sampler.sample(now: 1)
        XCTAssertEqual(sampler.asrText, "Collecting / unavailable")
        cpu = 0.25; sampler.sample(now: 2)
        XCTAssertEqual(sampler.appCPU, 25)
        XCTAssertEqual(sampler.asrText, "25.0% · 1 helper(s)")
        XCTAssertEqual(sampler.speakerText, "Inactive")
        registry.end(id); registry.end(id); sampler.sample(now: 3)
        XCTAssertEqual(sampler.asrText, "Inactive")
        XCTAssertTrue(registry.current().isEmpty)
        XCTAssertEqual(renders, 3)
    }
    func testStoppingPanelStopsSampling() async throws {
        var reads = 0
        let sampler = PerformanceSampler(
            read: { _ in
                reads += 1; return nil
            }, workers: { [] })
        XCTAssertEqual(reads, 0)
        sampler.start(); sampler.start()
        XCTAssertEqual(reads, 1)
        sampler.stop()
        try await Task.sleep(nanoseconds: 1_200_000_000)
        XCTAssertEqual(reads, 1)
        XCTAssertEqual(sampler.sampleCount, 1)
    }
    func testNativeCountersAndSamplingCost() {
        let first = ProcessCounter.read(pid: getpid())
        XCTAssertNotNil(first); XCTAssertGreaterThan(first?.residentBytes ?? 0, 0)
        let began = ProcessInfo.processInfo.systemUptime
        for _ in 0..<1000 { XCTAssertNotNil(ProcessCounter.read(pid: getpid())) }
        let wall = ProcessInfo.processInfo.systemUptime - began
        let last = ProcessCounter.read(pid: getpid())!
        XCTAssertEqual(first?.identity, last.identity)
        XCTAssertGreaterThanOrEqual(last.cpuSeconds, first!.cpuSeconds)
        print("PERFORMANCE_NATIVE_1000_READS wall=\(wall) cpu=\(last.cpuSeconds-first!.cpuSeconds)")
    }
    func testNativeCPUUnitsAgainstGetrusage() {
        func cpu() -> Double {
            var usage = rusage()
            XCTAssertEqual(getrusage(RUSAGE_SELF, &usage), 0)
            return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
                + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6
        }
        let before = ProcessCounter.read(pid: getpid())!
        let reference = cpu()
        let deadline = ProcessInfo.processInfo.systemUptime + 0.2
        var checksum = 0.0
        while ProcessInfo.processInfo.systemUptime < deadline {
            checksum += sqrt(checksum.truncatingRemainder(dividingBy: 1000) + 2)
        }
        let referenceDelta = cpu() - reference
        let actualDelta = ProcessCounter.read(pid: getpid())!.cpuSeconds - before.cpuSeconds
        XCTAssertGreaterThan(actualDelta, 0.03)
        XCTAssertEqual(actualDelta, referenceDelta, accuracy: 0.03)
        print(
            "NATIVE_CPU_CALIBRATION native=\(actualDelta) getrusage=\(referenceDelta) checksum=\(checksum)"
        )
    }
}
