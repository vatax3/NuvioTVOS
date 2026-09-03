import Foundation
import Observation
import os

/// Reads the live playback numbers the stats overlay draws.
///
/// This is the half of the overlay that cannot be unit-tested: it asks the running task and the
/// mpv handle for values that exist only while something is playing. Every rule about what those
/// numbers *mean* lives in `PlaybackStats`, which is tested.
///
/// Upstream reads `/proc/self/stat` for CPU and a Linux paging counter. Neither exists on tvOS,
/// so CPU comes from `task_info` and the paging row is dropped rather than approximated — a
/// reading with no counterpart is better absent than invented.
@Observable
@MainActor
final class PlaybackStatsSampler {
    private(set) var readings: [PlaybackStats.Reading] = []

    @ObservationIgnored private var buffer = PlaybackStats.Average()
    @ObservationIgnored private var network = PlaybackStats.Average()
    @ObservationIgnored private var cpu = PlaybackStats.Average()
    /// CPU is a rate, so it needs the previous sample to subtract from.
    @ObservationIgnored private var lastCPUTime: TimeInterval?
    @ObservationIgnored private var lastSampledAt: Date?

    func reset() {
        readings = []
        buffer = PlaybackStats.Average()
        network = PlaybackStats.Average()
        cpu = PlaybackStats.Average()
        lastCPUTime = nil
        lastSampledAt = nil
    }

    /// One tick. `bufferSeconds`, `networkBitsPerSecond` and `streamBitsPerSecond` come from the
    /// engine; the rest are the process's own.
    func sample(
        bufferSeconds: Double?,
        networkBitsPerSecond: Double?,
        streamBitsPerSecond: Double?
    ) {
        if let bufferSeconds, bufferSeconds.isFinite, bufferSeconds >= 0 { buffer.add(bufferSeconds) }
        if let networkBitsPerSecond, networkBitsPerSecond > 0 { network.add(networkBitsPerSecond) }

        let cpuPercent = sampleCPUPercent()
        if let cpuPercent { cpu.add(cpuPercent) }

        readings = PlaybackStats.readings(
            buffer: bufferSeconds,
            bufferAverage: buffer.mean,
            networkBitsPerSecond: networkBitsPerSecond,
            networkAverage: network.mean,
            streamBitsPerSecond: streamBitsPerSecond,
            cpuPercent: cpuPercent,
            cpuAverage: cpu.mean,
            memoryUsedBytes: Self.footprintBytes(),
            memoryLimitBytes: Self.memoryLimitBytes(),
            thermal: ProcessInfo.processInfo.thermalState
        )
    }

    /// Task CPU time since the previous tick, over wall time since the previous tick.
    ///
    /// Reported against one core, so a busy decode thread plus a busy render thread can read
    /// past 100%. That matches what upstream prints and is the honest number — normalising by
    /// core count would hide the case the overlay exists to show.
    private func sampleCPUPercent() -> Double? {
        guard let total = Self.taskCPUSeconds() else { return nil }
        let now = Date()
        defer {
            lastCPUTime = total
            lastSampledAt = now
        }
        guard let previous = lastCPUTime, let previousAt = lastSampledAt else { return nil }
        let elapsed = now.timeIntervalSince(previousAt)
        guard elapsed > 0 else { return nil }
        return max(0, (total - previous) / elapsed) * 100
    }

    // MARK: - mach

    private static func taskCPUSeconds() -> TimeInterval? {
        var info = task_thread_times_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_thread_times_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_THREAD_TIMES_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let user = TimeInterval(info.user_time.seconds) + TimeInterval(info.user_time.microseconds) / 1_000_000
        let system = TimeInterval(info.system_time.seconds) + TimeInterval(info.system_time.microseconds) / 1_000_000
        return user + system
    }

    /// `phys_footprint` rather than `resident_size`: it is the figure jetsam actually judges,
    /// which is what makes the warning thresholds mean anything.
    private static func footprintBytes() -> Double? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return Double(info.phys_footprint)
    }

    /// What this process may still allocate, plus what it already holds — the ceiling the
    /// warning thresholds are fractions of.
    private static func memoryLimitBytes() -> Double? {
        guard let used = footprintBytes() else { return nil }
        let available = Double(os_proc_available_memory())
        guard available > 0 else { return nil }
        return used + available
    }
}
