import Foundation

/// The live playback readings behind the stats overlay, and the rules for presenting them.
///
/// Ported from upstream's `PlayerDebugStatsOverlay`, which reads `/proc/self/stat` and a Linux
/// paging counter. Neither exists here, so the *sampling* is rewritten against mach and mpv
/// while the *presentation* — which readings, in what order, with which thresholds — is kept.
///
/// Everything in this file is pure: it turns numbers into rows. What produces the numbers is
/// `PlaybackStatsSampler`, which cannot be unit-tested because it reads the running task.
enum PlaybackStats {
    /// How a reading should be drawn. Upstream highlights memory alone; the same three levels
    /// apply to thermal here, because on an Apple TV the thermal state is the reading most
    /// likely to explain a stutter and the one a viewer can act on.
    enum Severity: String, Hashable {
        case normal, warning, limit
    }

    struct Reading: Hashable, Identifiable {
        var label: String
        var value: String
        var severity: Severity = .normal
        var id: String { label }
    }

    /// A rolling mean kept alongside the instantaneous value, because a single frame of any of
    /// these is noise. Upstream prints both as `value   avg value`, and so does this.
    struct Average: Hashable {
        private(set) var total: Double = 0
        private(set) var count: Int = 0

        mutating func add(_ sample: Double) {
            guard sample.isFinite else { return }
            total += sample
            count += 1
        }

        var mean: Double? { count > 0 ? total / Double(count) : nil }
    }

    // MARK: - Thresholds

    /// Fractions of the app's memory limit. Below `memoryWarning` the reading is ordinary; past
    /// `memoryLimit` the process is close enough to the ceiling that a jetsam kill is the next
    /// event, which is worth saying in a colour rather than a number.
    static let memoryWarning = 0.75
    static let memoryLimit = 0.9

    static func memorySeverity(usedBytes: Double, limitBytes: Double) -> Severity {
        guard limitBytes > 0, usedBytes >= 0 else { return .normal }
        let fraction = usedBytes / limitBytes
        if fraction >= memoryLimit { return .limit }
        if fraction >= memoryWarning { return .warning }
        return .normal
    }

    /// `ProcessInfo.ThermalState` has four cases and no headroom figure — the Android reading is
    /// a float from 0 to 1, which has no counterpart. Mapped rather than faked.
    static func thermalSeverity(_ state: ProcessInfo.ThermalState) -> Severity {
        switch state {
        case .nominal, .fair: return .normal
        case .serious: return .warning
        case .critical: return .limit
        @unknown default: return .normal
        }
    }

    static func thermalLabel(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }

    // MARK: - Formatting

    /// The reading is dropped rather than shown as a zero when the source has nothing to say.
    /// A stat that reads `0.0 Mbps` because the property was missing is worse than no row.
    static func megabits(perSecond bitsPerSecond: Double?) -> String? {
        guard let bitsPerSecond, bitsPerSecond.isFinite, bitsPerSecond > 0 else { return nil }
        return String(format: "%.1f Mbps", bitsPerSecond / 1_000_000)
    }

    static func megabytes(_ bytes: Double) -> String {
        String(format: "%.0f MB", bytes / (1024 * 1024))
    }

    static func seconds(_ value: Double) -> String {
        String(format: "%.1fs", value)
    }

    static func percent(_ value: Double) -> String {
        String(format: "%.0f%%", value)
    }

    /// `value   avg mean`, the upstream shape. The average half is dropped until there are at
    /// least two samples, so the first frame does not print a mean equal to the value.
    static func withAverage(_ formatted: String, mean: Double?, format: (Double) -> String) -> String {
        guard let mean else { return formatted }
        return "\(formatted)   avg \(format(mean))"
    }

    // MARK: - Rows

    /// Assembles the overlay's rows in upstream's order, dropping any the platform could not
    /// answer for. The order is deliberate: the two a viewer can act on come first.
    static func readings(
        buffer: Double?,
        bufferAverage: Double?,
        networkBitsPerSecond: Double?,
        networkAverage: Double?,
        streamBitsPerSecond: Double?,
        cpuPercent: Double?,
        cpuAverage: Double?,
        memoryUsedBytes: Double?,
        memoryLimitBytes: Double?,
        thermal: ProcessInfo.ThermalState
    ) -> [Reading] {
        var rows: [Reading] = []

        if let buffer, buffer.isFinite, buffer >= 0 {
            rows.append(Reading(
                label: "buffer",
                value: withAverage(seconds(buffer), mean: bufferAverage, format: seconds)
            ))
        }
        if let network = megabits(perSecond: networkBitsPerSecond) {
            rows.append(Reading(
                label: "network",
                value: withAverage(network, mean: networkAverage) {
                    megabits(perSecond: $0) ?? "—"
                }
            ))
        }
        if let stream = megabits(perSecond: streamBitsPerSecond) {
            rows.append(Reading(label: "bitrate", value: stream))
        }
        if let cpuPercent, cpuPercent.isFinite {
            rows.append(Reading(
                label: "cpu",
                value: withAverage(percent(cpuPercent), mean: cpuAverage, format: percent)
            ))
        }
        if let memoryUsedBytes, memoryUsedBytes > 0 {
            let limit = memoryLimitBytes ?? 0
            let value = limit > 0
                ? "\(megabytes(memoryUsedBytes)) / \(megabytes(limit))"
                : megabytes(memoryUsedBytes)
            rows.append(Reading(
                label: "memory",
                value: value,
                severity: memorySeverity(usedBytes: memoryUsedBytes, limitBytes: limit)
            ))
        }
        rows.append(Reading(
            label: "thermal",
            value: thermalLabel(thermal),
            severity: thermalSeverity(thermal)
        ))
        return rows
    }
}
