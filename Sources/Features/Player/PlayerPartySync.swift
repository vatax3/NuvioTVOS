import Foundation

/// The player's half of a watch party.
///
/// A port of upstream's `runPartySync`, which is a 250 ms loop — the same cadence `MPVEngine`
/// already publishes `time-pos` at, so this is driven from the position observer rather than
/// from a timer of its own.
///
/// It is a class rather than a function because the loop is *stateful*, and every piece of that
/// state earns its place by preventing a specific misbehaviour:
///
/// - **`lastSeq`** — a party command is applied once, on arrival, not re-applied every tick.
/// - **`mismatchSince`** — a disagreement about pause has to last 1.2 s before anyone acts.
///   Engines report pause transitions a few frames late, and acting on the first tick means
///   fighting them.
/// - **`lastSeek` / `lastCorrection`** — a seek is given 2.5 s to land, and corrections are made
///   at most every 500 ms. 1.0.49 corrected on every tick with no settle, so a single seek
///   provoked the next correction while it was still in flight.
/// - **`seekLeadMs`** — a seek on this hardware lands *late*; the error is measured and added to
///   the next target. Without it every correction undershoots by the same amount, forever.
/// - **`isBehind`** — the viewer deliberately went back while not allowed to drive. They are not
///   blocked and not corrected; they watch on their own until they catch up.
///
/// The loop decides; `PlayerView` acts. That split is what makes any of this testable.
@MainActor
final class PlayerPartyLoop {
    /// Everything the loop needs to know about this device, this tick.
    struct Input {
        var positionMs: Int64
        var durationMs: Int64
        var isPaused: Bool
        var isLoading: Bool
        /// False until the first frame is on screen — before that this device has no position
        /// worth publishing or correcting.
        var hasRendered: Bool
        var mediaKey: String
        /// The speed the viewer themselves chose, which a nudge has to hand back.
        var viewerRate: Double
    }

    /// What the player should do about it.
    enum Instruction: Equatable {
        case seek(toMs: Int64)
        case setRate(Double)
        case restoreRate
        case applyPause(Bool)
        case publish(positionMs: Int64, paused: Bool, rate: Double)
        case report(status: PartyMemberStatus, behindMs: Int64?)
        /// Tell the viewer something in one line — "only the host can control playback".
        case message(PlayerPartyMessage)
    }

    /// How far behind the party this device deliberately is, for the badge.
    private(set) var isBehind = false
    private(set) var behindMs: Int64?

    private var lastSeq: (seq: Int64, memberId: String?)?
    private var mismatchSince: ContinuousClock.Instant?
    private var lastSeek: ContinuousClock.Instant?
    private var lastCorrection: ContinuousClock.Instant?
    private var bufferingSince: ContinuousClock.Instant?
    private var seekLeadMs: Int64 = 0
    private var measuresSeekLead = false
    private var isNudging = false
    private var hasPublishedInitial = false
    private var previousKey: String?
    private var previousPositionMs: Int64?
    private var wasBehind = false

    private static let mismatchDelay = Duration.milliseconds(1200)
    private static let seekSettle = Duration.milliseconds(2500)
    private static let correctionInterval = Duration.milliseconds(500)
    private static let bufferingReportDelay = Duration.milliseconds(1000)
    private static let maxSeekLeadMs: Int64 = 3000
    /// A position jump larger than this, between two ticks, is somebody scrubbing rather than
    /// the film playing — `MPVEngine` publishes at 4 Hz and treats the same figure as a
    /// discontinuity.
    private static let seekDetectionMs: Int64 = 1500
    private static let behindStepMs: Int64 = 1000

    func reset() {
        lastSeq = nil
        mismatchSince = nil
        lastSeek = nil
        lastCorrection = nil
        bufferingSince = nil
        seekLeadMs = 0
        measuresSeekLead = false
        isNudging = false
        hasPublishedInitial = false
        previousPositionMs = nil
        isBehind = false
        behindMs = nil
        wasBehind = false
    }

    /// One turn of the loop.
    func tick(_ input: Input, store: PartyStore) -> [Instruction] {
        guard let party = store.party else {
            reset()
            return []
        }

        var instructions: [Instruction] = []

        // A change of episode resets everything about where we are.
        if previousKey != input.mediaKey {
            previousKey = input.mediaKey
            isBehind = false
            behindMs = nil
            lastSeq = nil
            previousPositionMs = nil
            hasPublishedInitial = false
        }

        instructions.append(contentsOf: reportStatus(input, party: party, store: store))

        // Not what the party is watching: say so and stay out of it.
        guard party.media.key == input.mediaKey else {
            if isNudging { isNudging = false; instructions.append(.restoreRate) }
            return instructions
        }

        guard let playback = store.playback else {
            // Nobody has said where the film is. The host says so, once there is a frame to
            // speak for — and only the host, or two devices joining together both claim it.
            if input.hasRendered, !hasPublishedInitial, party.isHost {
                hasPublishedInitial = true
                instructions.append(.publish(
                    positionMs: input.positionMs, paused: input.isPaused, rate: input.viewerRate
                ))
            }
            previousPositionMs = input.positionMs
            return instructions
        }
        hasPublishedInitial = true
        guard input.hasRendered else { return instructions }

        // Being allowed to drive again ends a deliberate absence.
        if isBehind, party.canControl { setBehind(false) }

        let expected = PartySync.expectedPositionMs(
            playback, nowMs: store.serverNowMs, durationMs: input.durationMs
        )

        if isBehind {
            if isNudging { isNudging = false; instructions.append(.restoreRate) }
            mismatchSince = nil
            let gap = expected - input.positionMs
            if PartySync.shouldRejoin(gapMs: gap, isPlaying: !input.isPaused && !input.isLoading) {
                setBehind(false)
            } else {
                if behindMs == nil || abs(gap - (behindMs ?? 0)) >= Self.behindStepMs {
                    behindMs = max(0, gap)
                }
                wasBehind = true
                previousPositionMs = input.positionMs
                return instructions
            }
        }
        if wasBehind {
            wasBehind = false
            lastSeq = nil
            if !party.canControl { instructions.append(.message(.caughtUp)) }
        }

        // A new command from the room, applied once.
        let identity = (seq: playback.seq, memberId: playback.memberId)
        if lastSeq.map({ $0 != identity }) ?? true {
            let forced = lastSeq == nil
            lastSeq = identity
            instructions.append(contentsOf: apply(
                playback, expected: expected, input: input, party: party, forced: forced
            ))
            previousPositionMs = input.positionMs
            return instructions
        }

        // Somebody scrubbed on this device.
        if let jump = detectOwnSeek(input), !input.isLoading {
            instructions.append(contentsOf: ownSeek(
                toMs: jump, expected: expected, party: party, input: input
            ))
            previousPositionMs = input.positionMs
            return instructions
        }
        previousPositionMs = input.positionMs

        guard !input.isLoading else {
            mismatchSince = nil
            return instructions
        }

        // Playing when the room is paused, or the other way round.
        if input.isPaused != playback.paused {
            let since = mismatchSince ?? ContinuousClock.now
            mismatchSince = since
            guard ContinuousClock.now - since > Self.mismatchDelay else { return instructions }
            mismatchSince = nil
            if party.canControl {
                instructions.append(.publish(
                    positionMs: input.positionMs, paused: input.isPaused, rate: playback.rate
                ))
            } else if !input.isPaused {
                // Not allowed to drive, and running while the room is held: adopt the room's
                // pause rather than drift away from it.
                instructions.append(.applyPause(true))
            } else {
                // Paused themselves while the room plays on: that is a choice, not a fault.
                setBehind(true)
                instructions.append(.message(.hostOnly))
            }
            return instructions
        }
        mismatchSince = nil

        let settled = lastSeek.map { ContinuousClock.now - $0 > Self.seekSettle } ?? true
        let due = lastCorrection.map { ContinuousClock.now - $0 >= Self.correctionInterval } ?? true
        guard settled, due else { return instructions }
        lastCorrection = ContinuousClock.now

        let drift = input.positionMs - expected
        if measuresSeekLead, !playback.paused {
            measuresSeekLead = false
            if abs(drift) < Self.maxSeekLeadMs {
                seekLeadMs = min(Self.maxSeekLeadMs, max(0, seekLeadMs - drift))
            }
        }

        switch PartySync.correction(
            localPositionMs: input.positionMs, expectedPositionMs: expected,
            playback: playback, isNudging: isNudging
        ) {
        case .seek(let target):
            if isNudging { isNudging = false; instructions.append(.restoreRate) }
            instructions.append(.seek(toMs: lead(target, paused: playback.paused, input: input)))
            lastSeek = ContinuousClock.now
            measuresSeekLead = !playback.paused
        case .nudge(let rate):
            isNudging = true
            instructions.append(.setRate(rate))
        case .inSync:
            if isNudging { isNudging = false; instructions.append(.restoreRate) }
        }
        return instructions
    }

    // MARK: Pieces

    /// Applies a command that has just arrived.
    private func apply(
        _ playback: PartyPlayback, expected: Int64, input: Input, party: ActiveParty, forced: Bool
    ) -> [Instruction] {
        var instructions: [Instruction] = []
        if forced || input.isPaused != playback.paused {
            instructions.append(.applyPause(playback.paused))
        }
        // Our own command does not move us — we are already where it says — unless this is the
        // first one we have seen, when the position still has to be adopted.
        let own = !forced && playback.memberId == party.memberId
        if (!own || playback.paused),
           abs(input.positionMs - expected) > PartySync.pausedToleranceMs {
            instructions.append(.seek(toMs: lead(expected, paused: playback.paused, input: input)))
            measuresSeekLead = !playback.paused
        }
        lastSeek = ContinuousClock.now
        if !isNudging, abs(input.viewerRate - playback.rate) > 0.01 {
            instructions.append(.setRate(playback.rate))
        }
        mismatchSince = nil
        return instructions
    }

    private func lead(_ target: Int64, paused: Bool, input: Input) -> Int64 {
        let led = paused ? target : target + seekLeadMs
        return input.durationMs > 0 ? min(led, input.durationMs) : led
    }

    /// A position that moved further than playing could account for.
    private func detectOwnSeek(_ input: Input) -> Int64? {
        guard let previous = previousPositionMs else { return nil }
        // Not while a correction of ours is still landing — that jump is this loop's own doing.
        if let lastSeek, ContinuousClock.now - lastSeek <= Self.seekSettle { return nil }
        guard abs(input.positionMs - previous) > Self.seekDetectionMs else { return nil }
        return input.positionMs
    }

    /// What this device's own scrub means.
    private func ownSeek(
        toMs target: Int64, expected: Int64, party: ActiveParty, input: Input
    ) -> [Instruction] {
        if party.canControl {
            return [.publish(positionMs: target, paused: input.isPaused, rate: input.viewerRate)]
        }
        switch PartySync.ownSeek(
            targetMs: target, partyPositionMs: expected, isBehind: isBehind
        ) {
        case .behind:
            setBehind(true)
            return [.message(.watchingAlone)]
        case .catchUp:
            setBehind(false)
            return [.seek(toMs: expected)]
        case .blocked:
            return [.message(.hostOnly), .seek(toMs: expected)]
        }
    }

    /// Rejoins the party's position on request.
    func catchUp() { setBehind(false) }

    private func setBehind(_ behind: Bool) {
        guard isBehind != behind else { return }
        isBehind = behind
        behindMs = behind ? behindMs : nil
    }

    /// What to tell the room this device is doing.
    private func reportStatus(
        _ input: Input, party: ActiveParty, store: PartyStore
    ) -> [Instruction] {
        let status: PartyMemberStatus
        if party.media.key != input.mediaKey {
            status = .browsing
        } else if isBehind {
            status = .behind
        } else if !input.hasRendered {
            status = .loading
        } else if input.isLoading {
            let since = bufferingSince ?? ContinuousClock.now
            bufferingSince = since
            status = ContinuousClock.now - since > Self.bufferingReportDelay ? .buffering : .ready
        } else {
            bufferingSince = nil
            status = .ready
        }
        let gap = status == .behind ? behindMs.map(PartySync.reportedGapMs) : nil
        return [.report(status: status, behindMs: gap)]
    }
}

/// The one-line messages the loop can ask for.
enum PlayerPartyMessage: Equatable {
    case hostOnly
    case watchingAlone
    case caughtUp

    var text: String {
        switch self {
        case .hostOnly:
            return L10n.text(
                "party.host_only_note", fallback: "Only the host can control playback"
            )
        case .watchingAlone:
            return L10n.text(
                "party.watching_alone", fallback: "Watching on your own — catch up when you like"
            )
        case .caughtUp:
            return L10n.text("party.caught_up", fallback: "Back with the party")
        }
    }
}
