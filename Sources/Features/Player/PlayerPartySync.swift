import SwiftUI

/// The player's half of a watch party: publish what this device does, and correct it against
/// what the party says.
///
/// Kept out of `PlayerView` because that file is already at the type-checker's limit, and
/// because the loop is worth reading on its own. Two directions, and they must not cross:
///
/// - **Outward.** A pause, a seek or a speed change made *here* is published, so everybody
///   follows. Only when this device may drive — with *host only* on, a guest's pause is their
///   own business.
/// - **Inward.** Every tick, where this device is gets compared with where the party should be,
///   and the difference is closed by `PartySync` — a rate nudge for small drift, a seek for
///   large. A correction must never be republished as a command, or two devices chase each other
///   around the film.
@MainActor
struct PlayerPartyCoordinator {
    let store: PartyStore
    /// The media this player is showing, so a member on the next episode is not corrected
    /// against this one's position.
    let mediaKey: String?

    /// True while a correction is in flight, which the caller feeds back in so the rate is not
    /// switched on and off every tick — `PartySync`'s hysteresis needs to know.
    var isNudging: Bool

    /// What the player should do about the party, this tick.
    enum Instruction: Equatable {
        case none
        case seek(to: Double)
        case setRate(Double)
        case restoreRate
        case pause(Bool)
    }

    /// Compares this device's position with the party's and says what to do about it.
    ///
    /// Returns `.none` when there is no party, when this player is showing something else, or
    /// when the gap is inside tolerance — which is the overwhelmingly common case, so the cheap
    /// exits come first.
    func instruction(positionMs: Int64, isPaused: Bool, durationMs: Int64) -> Instruction {
        guard let party = store.party, let playback = store.playback else { return .none }
        // A member who has moved on to the next episode is not behind on this one.
        guard playback.mediaKey == nil || playback.mediaKey == mediaKey else { return .none }
        // Nobody corrects the device that is leading: it *is* the position.
        guard playback.memberId != party.memberId else { return .none }

        if playback.paused != isPaused { return .pause(playback.paused) }

        let expected = PartySync.expectedPositionMs(
            playback, nowMs: store.serverNowMs, durationMs: durationMs
        )
        switch PartySync.correction(
            localPositionMs: positionMs,
            expectedPositionMs: expected,
            playback: playback,
            isNudging: isNudging
        ) {
        case .inSync:
            return isNudging ? .restoreRate : .none
        case .seek(let target):
            return .seek(to: Double(target) / 1000)
        case .nudge(let rate):
            return .setRate(rate)
        }
    }

    /// What this device should tell the party about itself, so the others can wait rather than
    /// run ahead.
    func status(isLoading: Bool, isBehindMs: Int64?) -> PartyMemberStatus {
        if isLoading { return .buffering }
        if isBehindMs != nil { return .behind }
        return .ready
    }
}
