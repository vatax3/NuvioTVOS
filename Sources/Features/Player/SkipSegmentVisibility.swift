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
