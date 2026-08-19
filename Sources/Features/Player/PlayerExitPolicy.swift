import Foundation

/// What one Menu/Back press means during playback.
///
/// Android resolves this in a single `BackHandler` with an ordered chain, and that ordering is
/// the whole behaviour: whichever layer is on top absorbs the press, and only a press with
/// nothing left on top ends playback.  Keeping it out of the view is what makes it checkable —
/// the failure this replaces (a press closing a track panel *and* tearing the player down, so
/// the viewer landed back on the stream list) is invisible in a screenshot and obvious here.
enum PlayerExitAction: Equatable {
    /// A duplicate delivery of a press that has already been acted on.
    case ignore
    case closePanel
    case closePrompt
    case closeMoreActions
    case hideControls
    case dismissPlayback
}

enum PlayerExitPolicy {
    /// One physical press can reach the player twice — once through the focused subtree, once
    /// more while focus is rebuilt after a panel unmounts. Long enough to absorb that echo,
    /// short enough that a deliberate second press still lands.
    static let echoWindow: TimeInterval = 0.35

    struct State {
        var hasError = false
        var hasOpenPanel = false
        /// The next-episode card or the still-watching check, drawn by the host over playback.
        var hasOpenPrompt = false
        var showsMoreActions = false
        var showsControls = false
    }

    static func action(for state: State, sinceLastHandledPress: TimeInterval) -> PlayerExitAction {
        guard sinceLastHandledPress > echoWindow else { return .ignore }
        if state.hasError { return .dismissPlayback }
        if state.hasOpenPanel { return .closePanel }
        if state.hasOpenPrompt { return .closePrompt }
        if state.showsMoreActions { return .closeMoreActions }
        // Android hides the transport before it leaves playback, so an over-pressed Menu costs
        // a viewer the controls rather than the film.
        if state.showsControls { return .hideControls }
        return .dismissPlayback
    }
}
