import Foundation

/// Scrub step sizes for the focused progress bar, ported from `PlayerScrubRates` on Android TV.
///
/// Holding a direction on a TV remote repeats the key, and Android maps that repeat count to
/// progressively larger jumps so a long hold crosses an episode without a single tap becoming
/// coarse.  tvOS delivers the same repeats as a stream of move commands rather than one key
/// event with a counter, so the caller counts them; the thresholds and steps are Android's.
enum PlayerScrubRates {
    static let shortStep: Double = 10
    static let mediumStep: Double = 20
    static let longStep: Double = 30
    static let veryLongStep: Double = 60

    private static let mediumThreshold = 3
    private static let longThreshold = 8
    private static let veryLongThreshold = 15

    /// A repeat is only a repeat while the presses keep coming.  Anything slower is a fresh
    /// tap, which must go back to the 10 s step instead of inheriting the previous acceleration.
    static let repeatWindow: TimeInterval = 0.45

    /// Seconds to jump for the given number of consecutive move commands (always positive).
    static func step(forRepeatCount count: Int) -> Double {
        switch max(0, count) {
        case veryLongThreshold...: return veryLongStep
        case longThreshold...: return longStep
        case mediumThreshold...: return mediumStep
        default: return shortStep
        }
    }

    /// Signed delta for a backward (`forward: false`) or forward scrub.
    static func delta(forRepeatCount count: Int, forward: Bool) -> Double {
        let step = step(forRepeatCount: count)
        return forward ? step : -step
    }
}
