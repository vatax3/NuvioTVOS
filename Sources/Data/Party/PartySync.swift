import Foundation

/// What to do about the gap between where this device is and where the party is.
enum PartyCorrection: Equatable, Sendable {
    case inSync
    /// Far enough out that only a jump will fix it.
    case seek(positionMs: Int64)
    /// Close, so the rate is nudged instead — a seek here would be a visible stutter for an
    /// error nobody can perceive.
    case nudge(rate: Double)
}

/// Keeping several televisions on the same frame.
///
/// Direct port of upstream's `PartySync`, and it is the file in this feature most worth porting
/// exactly: the constants are the result of their tuning against real sessions, and the
/// two-tier correction is the whole difference between "watching together" and "watching nearly
/// together with a jolt every minute".
///
/// The reason there are two tiers: a seek is the only way to close a large gap and the worst way
/// to close a small one — it drops frames, re-buffers, and is visible. So beyond a second and a
/// half the position is taken by force, and below that the **playback rate** is changed by five
/// percent until the gap closes, which nobody can hear or see.
enum PartySync {
    /// Start nudging once a quarter of a second out.
    static let nudgeStartMs: Int64 = 250
    /// Stop once inside 80ms — hysteresis, so the rate is not switched on and off every tick.
    static let nudgeStopMs: Int64 = 80
    /// Past this, nudging would take too long to converge; jump.
    static let seekThresholdMs: Int64 = 1_500
    /// While paused there is no rate to nudge, so the tolerance is simply tighter.
    static let pausedToleranceMs: Int64 = 500
    static let nudgeFactor = 0.05
    /// A position change larger than this is reported as "seeked" rather than passing silently.
    static let seekNoticeMs: Int64 = 2_000
    /// How far behind a member may be and still be waited for rather than left behind.
    static let rejoinGapMs: Int64 = 2_000
    /// "Behind" is reported in five-second steps: an exact figure that changes every tick is
    /// noise, and the question it answers is only ever "a little" or "a lot".
    static let behindStepMs: Int64 = 5_000

    /// Where the party should be *now*, given what it last said and how long ago.
    ///
    /// `nowMs` is server time. A local clock here would bake this device's offset into every
    /// correction, which is why the backend exposes a clock at all.
    static func expectedPositionMs(
        _ playback: PartyPlayback, nowMs: Int64, durationMs: Int64 = 0
    ) -> Int64 {
        let position: Int64
        if playback.paused {
            position = playback.positionMs
        } else {
            let elapsed = max(0, nowMs - playback.at)
            position = playback.positionMs + Int64(Double(elapsed) * playback.rate)
        }
        let clamped = max(0, position)
        return durationMs > 0 ? min(clamped, durationMs) : clamped
    }

    /// Whether `candidate` supersedes what we are already acting on.
    ///
    /// `seq` orders commands, and the member id breaks a tie — which is not arbitrary tidiness:
    /// two people pressing pause in the same instant produce the same `seq`, and without a
    /// deterministic rule each device would pick a different winner and they would fight.
    static func isNewer(_ candidate: PartyPlayback, than current: PartyPlayback?) -> Bool {
        guard let current else { return true }
        if candidate.seq != current.seq { return candidate.seq > current.seq }
        return (candidate.memberId ?? "") > (current.memberId ?? "")
    }

    static func correction(
        localPositionMs: Int64,
        expectedPositionMs: Int64,
        playback: PartyPlayback,
        isNudging: Bool
    ) -> PartyCorrection {
        let drift = localPositionMs - expectedPositionMs
        let distance = abs(drift)

        if playback.paused {
            return distance > pausedToleranceMs
                ? .seek(positionMs: expectedPositionMs)
                : .inSync
        }

        let threshold = isNudging ? nudgeStopMs : nudgeStartMs
        if distance > seekThresholdMs { return .seek(positionMs: expectedPositionMs) }
        if distance > threshold {
            // Ahead of the party: slow down. Behind: speed up.
            let factor = drift > 0 ? 1 - nudgeFactor : 1 + nudgeFactor
            return .nudge(rate: playback.rate * factor)
        }
        return .inSync
    }

    /// Who the party takes its position from.
    ///
    /// The host when they are present; with *host only* on, nobody else ever. Otherwise the
    /// first member who is actually online — a party whose host closed the app has to keep
    /// playing rather than freeze on their last position.
    static func coordinatorId(for party: ActiveParty) -> String? {
        var online = Set(party.presence.keys)
        online.insert(party.memberId)
        if let host = party.hostMemberId, online.contains(host) { return host }
        if party.hostOnly { return party.hostMemberId }
        return party.members.first { online.contains($0.id) }?.id ?? party.memberId
    }

    /// What to tell the room about a change, or nil when it is not worth a line.
    ///
    /// A `waiting` state and a change of title are both excluded: the first is machinery and the
    /// second announces itself.
    static func action(from previous: PartyPlayback?, to next: PartyPlayback) -> PartyAction? {
        guard let previous, !previous.waiting, !next.waiting else { return nil }
        guard previous.mediaKey == next.mediaKey else { return nil }

        if previous.paused != next.paused { return next.paused ? .paused : .resumed }
        if abs(previous.rate - next.rate) > 0.01 { return .speed }
        let expected = expectedPositionMs(previous, nowMs: next.at)
        if abs(next.positionMs - expected) > seekNoticeMs { return .seeked }
        return nil
    }

    /// What happens when *this* device seeks while the party is elsewhere.
    static func ownSeek(targetMs: Int64, partyPositionMs: Int64, isBehind: Bool) -> PartyOwnSeek {
        if targetMs < partyPositionMs - rejoinGapMs { return .behind(positionMs: targetMs) }
        return isBehind ? .catchUp : .blocked
    }

    /// Whether a member this far behind should be rejoined to the party rather than waited for.
    static func shouldRejoin(gapMs: Int64, isPlaying: Bool) -> Bool {
        isPlaying && gapMs <= rejoinGapMs
    }

    /// Who the party is still waiting for.
    ///
    /// Only members on *this* title: somebody who has moved to the next episode is not holding
    /// this one up. `ignoring` carries the members already waited out once, so one slow
    /// connection cannot stop the room indefinitely.
    static func waitingMemberIds(in party: ActiveParty, ignoring: Set<String>) -> [String] {
        party.presence.values
            .filter { $0.mediaKey == party.media.key }
            .filter { $0.status == .loading || $0.status == .buffering }
            .map(\.memberId)
            .filter { !ignoring.contains($0) }
    }

    /// The gap, rounded to the step it is reported in and never to zero — "behind by 0 seconds"
    /// is a state the badge should not be able to show.
    static func reportedGapMs(_ gapMs: Int64) -> Int64 {
        let rounded = (max(0, gapMs) + behindStepMs / 2) / behindStepMs * behindStepMs
        return max(behindStepMs, rounded)
    }
}

/// What this device's own seek means for its membership.
enum PartyOwnSeek: Equatable, Sendable {
    /// Deliberately gone back: this device drops out of sync and watches on its own.
    case behind(positionMs: Int64)
    /// Already behind and seeking forward: rejoin the party's position.
    case catchUp
    /// In sync and not allowed to drive — the seek does nothing.
    case blocked
}
