import Foundation

/// The party's shared clock.
///
/// Every position on the wire is stamped against the *server's* clock, so each device needs its
/// own offset from it. 1.0.48 took that offset as `serverTimeMs - Date()` from whichever snapshot
/// happened to arrive, and both halves of that were wrong.
///
/// **The round trip is not free.** The server's answer describes a moment that has already
/// passed by the time it lands, so an uncompensated offset is late by a whole round trip —
/// 100–300 ms on a domestic connection. The nudge threshold is 250 ms, which means every device
/// in the party sits permanently outside it, rate-nudging against an error that is not there.
/// Halving the measured round trip is the standard correction and assumes only that the two legs
/// are roughly equal.
///
/// **And a wall clock moves.** tvOS steps `Date()` when it reaches NTP, which on an idle
/// television it does; an offset anchored to it drags the party's expected position along. The
/// anchor here is monotonic, so only the sample itself can move the clock.
///
/// Samples are kept on best round trip rather than averaged: a sample that took 40 ms is a better
/// measurement than the mean of one that took 40 and one that took 400, and the slow ones carry
/// all the asymmetry.
struct PartyClock {
    /// What a sample is timed against. `ContinuousClock` keeps running while the device sleeps,
    /// which matters on a television that is left on.
    typealias Mark = ContinuousClock.Instant

    private var anchorServerMs: Int64?
    private var anchorMark: Mark?
    private var bestRoundTripMs: Int64 = .max

    var isSynced: Bool { anchorServerMs != nil }
    /// The best round trip seen, which is also how far the offset can be trusted.
    var roundTripMs: Int64? { bestRoundTripMs == .max ? nil : bestRoundTripMs }

    func mark() -> Mark { ContinuousClock.now }

    /// Server time now, or this device's own wall clock when nothing has been measured yet.
    ///
    /// `at` is the instant being asked about; it exists so the arithmetic can be read at a known
    /// instant in a test rather than at whatever one the test happens to run at.
    func nowMs(
        at: Mark = ContinuousClock.now, localNowMs: Int64 = PartyClock.wallClockMs()
    ) -> Int64 {
        guard let anchorServerMs, let anchorMark else { return localNowMs }
        return anchorServerMs + (at - anchorMark).milliseconds
    }

    /// Folds in one `watch_party_clock` answer, measured from the mark taken before the request.
    mutating func addSample(
        serverMs: Int64, sentAt: Mark, receivedAt: Mark = ContinuousClock.now
    ) {
        let roundTripMs = max(0, (receivedAt - sentAt).milliseconds)
        guard roundTripMs <= bestRoundTripMs else { return }
        bestRoundTripMs = roundTripMs
        anchorServerMs = serverMs + roundTripMs / 2
        anchorMark = receivedAt
    }

    mutating func reset() {
        anchorServerMs = nil
        anchorMark = nil
        bestRoundTripMs = .max
    }

    static func wallClockMs() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }
}

extension Duration {
    /// Whole milliseconds, which is the unit every position on the party wire is in.
    var milliseconds: Int64 {
        let (seconds, attoseconds) = components
        return seconds * 1000 + attoseconds / 1_000_000_000_000_000
    }
}
