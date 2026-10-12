import Darwin
import Foundation

public enum WorkerRole: String, Sendable { case transcription, speakers }
public final class WorkerRegistry: @unchecked Sendable {
    public static let shared = WorkerRegistry()
    public struct Entry: Sendable {
        public let id: UUID; public let pid: Int32; public let role: WorkerRole
    }
    public init() {}
    private let lock = NSLock()
    private var entries: [UUID: Entry] = [:]
    public func start(pid: Int32, role: WorkerRole) -> UUID {
        lock.lock(); defer { lock.unlock() }; let id = UUID();
        entries[id] = Entry(id: id, pid: pid, role: role); return id
    }
    public func end(_ id: UUID?) {
        guard let id else { return }; lock.lock(); entries[id] = nil; lock.unlock()
    }
    public func current() -> [Entry] {
        lock.lock(); defer { lock.unlock() }; return Array(entries.values)
    }
}
public struct ProcessCounter: Sendable {
    public let identity: UInt64
    public let cpuSeconds: Double
    public let residentBytes: UInt64
    public init(identity: UInt64, cpuSeconds: Double, residentBytes: UInt64) {
        self.identity = identity; self.cpuSeconds = cpuSeconds; self.residentBytes = residentBytes
    }
    private static let tickSeconds: Double = {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        return Double(timebase.numer) / Double(timebase.denom) / 1e9
    }()
    public static func read(pid: Int32) -> ProcessCounter? {
        var info = rusage_info_v4()
        let code = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
            }
        }
        guard code == 0 else { return nil }
        return ProcessCounter(
            identity: info.ri_proc_start_abstime,
            cpuSeconds: (Double(info.ri_user_time) + Double(info.ri_system_time)) * tickSeconds,
            residentBytes: info.ri_resident_size)
    }
}
public struct CPUDelta {
    private var previous: (ProcessCounter, Double)?
    public init() {}
    public mutating func sample(_ value: ProcessCounter?, at time: Double) -> Double? {
        guard let value else { previous = nil; return nil }
        defer { previous = (value, time) }
        guard let (old, when) = previous, old.identity == value.identity, time > when,
            value.cpuSeconds >= old.cpuSeconds
        else { return nil }
        return (value.cpuSeconds - old.cpuSeconds) / (time - when) * 100
    }
}
