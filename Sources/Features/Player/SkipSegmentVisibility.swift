import Foundation

/// The chrome an engine is drawing over the picture, as the layers above it need to see it.
///
/// Both engines own their controls privately — AVPlayerViewController's transport bar, and the
/// MPV surface's own row and panels — and the host draws the skip card and the pause card on
/// top of both. Neither of those can be placed correctly without knowing what is already there,
/// so each engine reports it.
struct PlayerChromeState: Equatable {
    /// The transport is on screen. The viewer is looking at controls, not at bare picture.
    var controlsVisible = false
    /// A panel is covering the picture — a track chooser, the sources list, stream info.
    var panelOpen = false
    /// The engine has decided this is a live stream. See `PlayerLivePolicy`.
    var isLive = false
    /// The chapters the file lists, which the host turns into skip segments when the titles say
    /// what they are. Carried here because the chrome is the only layer that sees the engine.
    var chapters: [PlayerChapter] = []
}

/// When the skip card is on screen, and whether it may take the remote.
///
/// Port of `SkipIntroVisibilityRules.kt` and the state machine in `SkipIntroButton.kt`. Ours had
/// none of it: the card appeared with the interval, took focus unconditionally, and stayed for
/// the whole segment. Three things followed from that, all reported.
///
/// - It drew over an open track panel and stole its focus, so choosing a subtitle mid-intro
///   fought the card. Upstream leaves it on screen but unfocusable, because their overlay does
///   not sit under it; ours does, so here it goes away entirely while a panel is up.
/// - It never yielded. A ninety-second opening meant ninety seconds of a card that could not be
///   dismissed, over a picture the viewer might rather be watching.
/// - It grabbed focus even when the viewer was already in the transport, which is the one
///   moment they have said what they want the remote for — and drew straight across the title
///   of what was playing while it did.
enum SkipSegmentVisibility {
    /// `SKIP_INTRO_AUTO_HIDE_TIMEOUT_MS`.
    static let autoHideTimeout: TimeInterval = 10

    struct State: Equatable {
        /// Playback is inside a segment the viewer has not already skipped.
        var hasActiveSegment = false
        /// The countdown has run out once for this segment.
        var autoHidden = false
        var controlsVisible = false
        var panelOpen = false
        /// The next-episode countdown or the still-watching check. Upstream's `suppressFocus`:
        /// those are decisions with a deadline, so they keep the remote and the card does not
        /// compete for it — but it stays drawn, because an outro segment and the up-next card
        /// are active at the same moment by definition.
        var promptOpen = false
    }

    /// Upstream's `isSkipIntroButtonVisible`, adapted where the layouts differ.
    ///
    /// The card belongs to bare picture. It is what stands in for the transport while the
    /// transport is down, and the moment the controls are up it has nothing left to offer: they
    /// can reach the end of the opening more precisely than it can, and upstream never lets it
    /// take focus while they are showing either.
    ///
    /// **This is the one place the port diverges from `isSkipIntroButtonVisible`**, which keeps
    /// the card drawn alongside the control row. Android lays the two out in one scaffold that
    /// reserves room for both; here the card is a floating overlay over a transport that owns
    /// its own layout — and over AVKit's transport bar, whose height we cannot ask for at all —
    /// so drawn together they overlap, which is what a screenshot showed the moment Down was
    /// pressed. A red slab across the title of what is playing, unfocusable, is worse than no
    /// card, because everything it could do is on the screen underneath it.
    static func showsCard(_ state: State) -> Bool {
        state.hasActiveSegment && !state.panelOpen && !state.controlsVisible && !state.autoHidden
    }

    /// The countdown runs only while the card is on screen, which now carries upstream's
    /// `!controlsVisible` term by construction: time spent reading the controls never counts
    /// against it, and on the MPV engine a pause does not quietly spend it — pausing raises the
    /// transport there and nothing lowers it again.
    static func runsAutoHideCountdown(_ state: State) -> Bool {
        showsCard(state)
    }

    /// Whether the card should take the remote. Everything that hides it also takes the remote
    /// away from it; a prompt with a deadline outranks it while it stays on screen.
    static func claimsFocus(_ state: State) -> Bool {
        showsCard(state) && !state.promptOpen
    }
}

/// When the pause card is allowed to rise.
///
/// It is Android's "You are watching" panel: a few seconds after a deliberate pause it takes the
/// bottom of the screen and the transport steps aside, because the two draw the same title in
/// almost the same place. The rule had been only "is playback stopped", and that is not enough —
/// reported: pausing and then opening the subtitle chooser raised the card over the list of
/// languages a few seconds later.
///
/// The reason it belongs here rather than inline is that the countdown reads the answer twice —
/// once to start, once when it fires five seconds later — and those two reads have to agree.
enum PlayerPauseCardPolicy {
    /// Android's five seconds: long enough that pausing to read a subtitle or answer the door
    /// never swaps the screen out from under the viewer, short enough to settle into the card
    /// when the pause is a real interruption.
    static let delay: TimeInterval = 5

    struct State: Equatable {
        var isPaused = false
        var isEnabled = true
        /// Nothing has been drawn yet. A card describing a film that has not started is a cover,
        /// not a pause card.
        var hasStartedPlayback = false
        /// A panel is over the picture. The viewer is choosing something, not sitting idle, and
        /// the card would land on top of what they are reading.
        var panelOpen = false
        /// The next-episode countdown or the still-watching check: both hold playback stopped
        /// while they wait for an answer, so "paused" there is the app's doing, not the viewer's.
        var promptOpen = false
    }

    static func shouldRaise(_ state: State) -> Bool {
        state.isPaused && state.isEnabled && state.hasStartedPlayback
            && !state.panelOpen && !state.promptOpen
    }
}

/// What a film's end credits are actually offering to skip.
///
/// IntroDB marks a film's credits and, separately, any scene after them. Two things follow, and
/// neither is served by treating the scene as an ordinary segment: the scene must never be a card
/// of its own — "skip the post-credits scene" is not an offer anyone wants — and the credits card
/// has to say where it lands, because "Skip credits" on a film with a stinger reads like a
/// promise to skip the stinger too.
///
/// Port of `followingPostCreditsScene`, **narrowed to films**. Upstream extended it to series
/// outros three days before this was written, using a five-second tail as the only evidence. For
/// a film that tail means something — films do not pad. For an episode it is the norm: black
/// frames, a studio card, a next-episode preview. Their series path cannot produce an explicit
/// `post_credits` mark either, so on series the change is the heuristic and nothing else, and it
/// would relabel almost every ending as leading to a scene that is not there.
enum PostCreditsScene {
    /// `POST_OUTRO_AUTOPLAY_GAP_MS`. Credits that stop this far short of the end are hiding
    /// something — usually an unsubmitted stinger.
    static let unexplainedTail: Double = 5

    /// The scene a credits segment leads into, marked or inferred, if there is one.
    static func following(
        _ segment: SkipSegment,
        in segments: [SkipSegment],
        durationSeconds: Double
    ) -> SkipSegment? {
        guard segment.kind == .movieCredits else { return nil }

        let marked = segments
            .filter {
                $0.kind == .postCredits && $0.start.isFinite && $0.end.isFinite
                    && $0.end > $0.start && $0.start >= segment.end
                    // A different release can end before the submitted scene does; its start is
                    // still playable, so only the start is checked against this runtime.
                    && (durationSeconds <= 0 || $0.start < durationSeconds)
            }
            .min { $0.start < $1.start }
        if let marked { return marked }

        guard durationSeconds > 0, durationSeconds - segment.end > unexplainedTail else { return nil }
        return SkipSegment(kind: .postCredits, start: segment.end, end: durationSeconds)
    }

    /// Where pressing the card should land, or `nil` if this segment is not one to skip at all.
    static func skipTarget(
        for segment: SkipSegment,
        in segments: [SkipSegment],
        durationSeconds: Double
    ) -> Double? {
        guard segment.kind != .postCredits else { return nil }
        return following(segment, in: segments, durationSeconds: durationSeconds)?.start ?? segment.end
    }

    /// Whether a card may be drawn for this segment. The scene itself never earns one.
    static func offersCard(_ segment: SkipSegment) -> Bool {
        segment.kind != .postCredits
    }
}
