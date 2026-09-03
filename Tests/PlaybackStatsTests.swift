import XCTest
@testable import Nuvio

/// The presentation half of the stats overlay. The sampling half reads the running task and the
/// mpv handle, so it has no unit test — which is exactly why the rules live here instead.
final class PlaybackStatsTests: XCTestCase {
    private let mb = 1024.0 * 1024.0

    // MARK: Memory thresholds

    func testMemoryIsOrdinaryWellBelowTheLimit() {
        XCTAssertEqual(
            PlaybackStats.memorySeverity(usedBytes: 400 * mb, limitBytes: 1_000 * mb), .normal
        )
    }

    func testMemoryWarnsBeforeItIsFatal() {
        XCTAssertEqual(
            PlaybackStats.memorySeverity(usedBytes: 800 * mb, limitBytes: 1_000 * mb), .warning
        )
    }

    func testMemoryReportsTheLimitWhenAJetsamKillIsNext() {
        XCTAssertEqual(
            PlaybackStats.memorySeverity(usedBytes: 950 * mb, limitBytes: 1_000 * mb), .limit
        )
    }

    /// A missing limit must not read as "at the limit" — dividing by zero would.
    func testAnUnknownLimitIsNotAWarning() {
        XCTAssertEqual(PlaybackStats.memorySeverity(usedBytes: 900 * mb, limitBytes: 0), .normal)
    }

    // MARK: Thermal

    func testThermalMapsToTheThreeLevelsTheOverlayDraws() {
        XCTAssertEqual(PlaybackStats.thermalSeverity(.nominal), .normal)
        XCTAssertEqual(PlaybackStats.thermalSeverity(.fair), .normal)
        XCTAssertEqual(PlaybackStats.thermalSeverity(.serious), .warning)
        XCTAssertEqual(PlaybackStats.thermalSeverity(.critical), .limit)
    }

    // MARK: Formatting

    /// The reason this is a function and not a format string: a property mpv could not answer
    /// comes back nil or zero, and `0.0 Mbps` reads as a measurement rather than a gap.
    func testAnUnavailableRateHasNoRowRatherThanAZeroOne() {
        XCTAssertNil(PlaybackStats.megabits(perSecond: nil))
        XCTAssertNil(PlaybackStats.megabits(perSecond: 0))
        XCTAssertNil(PlaybackStats.megabits(perSecond: .nan))
        XCTAssertEqual(PlaybackStats.megabits(perSecond: 12_500_000), "12.5 Mbps")
    }

    func testTheAverageHalfIsOmittedUntilThereIsOne() {
        XCTAssertEqual(
            PlaybackStats.withAverage("4.0s", mean: nil, format: PlaybackStats.seconds), "4.0s"
        )
        XCTAssertEqual(
            PlaybackStats.withAverage("4.0s", mean: 3.5, format: PlaybackStats.seconds),
            "4.0s   avg 3.5s"
        )
    }

    func testAverageIgnoresNonFiniteSamples() {
        var average = PlaybackStats.Average()
        average.add(10)
        average.add(.nan)
        average.add(20)
        XCTAssertEqual(average.count, 2)
        XCTAssertEqual(average.mean ?? 0, 15, accuracy: 0.0001)
    }

    func testAnEmptyAverageHasNoMean() {
        XCTAssertNil(PlaybackStats.Average().mean)
    }

    // MARK: Rows

    func testEveryReadingTheDeviceCanAnswerForIsDrawn() {
        let rows = PlaybackStats.readings(
            buffer: 8, bufferAverage: 7,
            networkBitsPerSecond: 30_000_000, networkAverage: 28_000_000,
            streamBitsPerSecond: 18_000_000,
            cpuPercent: 42, cpuAverage: 40,
            memoryUsedBytes: 500 * mb, memoryLimitBytes: 1_000 * mb,
            thermal: .nominal
        )
        XCTAssertEqual(rows.map(\.label), ["buffer", "network", "bitrate", "cpu", "memory", "thermal"])
    }

    /// Missing sources drop their rows. Thermal always answers, so it is always present.
    func testMissingSourcesLeaveNoEmptyRows() {
        let rows = PlaybackStats.readings(
            buffer: nil, bufferAverage: nil,
            networkBitsPerSecond: nil, networkAverage: nil,
            streamBitsPerSecond: nil,
            cpuPercent: nil, cpuAverage: nil,
            memoryUsedBytes: nil, memoryLimitBytes: nil,
            thermal: .fair
        )
        XCTAssertEqual(rows.map(\.label), ["thermal"])
    }

    /// The buffer row leads, because it is the one that explains a stall while it is happening.
    func testTheBufferLeadsTheOverlay() {
        let rows = PlaybackStats.readings(
            buffer: 2, bufferAverage: nil,
            networkBitsPerSecond: 1_000_000, networkAverage: nil,
            streamBitsPerSecond: nil, cpuPercent: nil, cpuAverage: nil,
            memoryUsedBytes: nil, memoryLimitBytes: nil, thermal: .nominal
        )
        XCTAssertEqual(rows.first?.label, "buffer")
    }

    func testMemoryCarriesItsSeverityIntoTheRow() {
        let rows = PlaybackStats.readings(
            buffer: nil, bufferAverage: nil, networkBitsPerSecond: nil, networkAverage: nil,
            streamBitsPerSecond: nil, cpuPercent: nil, cpuAverage: nil,
            memoryUsedBytes: 960 * mb, memoryLimitBytes: 1_000 * mb, thermal: .nominal
        )
        XCTAssertEqual(rows.first { $0.label == "memory" }?.severity, .limit)
    }

    /// A negative buffer is a property that has not settled, not a reading.
    func testANegativeBufferIsNotDrawn() {
        let rows = PlaybackStats.readings(
            buffer: -1, bufferAverage: nil, networkBitsPerSecond: nil, networkAverage: nil,
            streamBitsPerSecond: nil, cpuPercent: nil, cpuAverage: nil,
            memoryUsedBytes: nil, memoryLimitBytes: nil, thermal: .nominal
        )
        XCTAssertFalse(rows.contains { $0.label == "buffer" })
    }
}
