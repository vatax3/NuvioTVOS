import Foundation

/// The four directional presses, kept independent of SwiftUI's `MoveCommandDirection` so the
/// rules below can be exercised without a view hierarchy.
enum PlayerRemoteDirection: Equatable { case up, down, left, right }

/// What a press other than Menu means during playback.
enum PlayerRemoteAction: Equatable {
    /// The press belongs to whatever currently owns focus — a panel row, a transport button —
    /// and the player must not act on it a second time.
    case none
    case reveal
    case togglePause
    case resume
    case seek(forward: Bool)
    case dismissPauseCard
}

/// Which element must own the remote for the player to stay controllable.
///
/// tvOS routes directional input, Select and Play/Pause through whatever holds focus. A view
/// that is merely faded out still holds it, and a view that has just been taken out of the
/// focus graph leaves it nowhere at all — both end with a remote that appears dead. Naming the
/// owner for every state, in one place, is what makes "press anything to bring the controls
/// back" true rather than approximately true.
enum PlayerFocusOwner: Equatable {
    /// The invisible full-screen sink. It owns the remote whenever the transport is down, so a
    /// press has somewhere to land and the player can read it.
    case sink
    /// The transport's home position, Play/Pause.
    case transport
    /// The scrubber, which is where a seek should leave the viewer.
    case progress
    /// A panel, an error, or a card the host drew over playback owns focus. Leave it alone.
    case unmanaged
}

/// The playback-side companion to `PlayerExitPolicy`: that one decides what Menu means, this
/// one decides what every other press means and where focus has to be for it to arrive.
enum PlayerRemotePolicy {
    struct State {
        var hasError = false
        var hasOpenPanel = false
        /// A focusable layer the host drew over playback: the skip-intro card, the next-episode
        /// countdown, the still-watching check. Each one owns the remote while it is up.
        var hasFocusableOverlay = false
        /// The pause card. It hides the transport without closing it, so the buttons underneath
        /// have to leave the focus graph with it.
        var showsPauseCard = false
        var showsControls = false
    }

    /// The transport is reachable only when it is both drawn and unobstructed. Anything that
    /// hides it must also take its buttons out of the focus graph, or the remote goes on
    /// operating controls nobody can see — a Select on an invisible button opening a panel.
    static func controlsInteractable(_ state: State) -> Bool {
        state.showsControls && !state.hasOpenPanel && !state.showsPauseCard && !state.hasError
    }

    static func focusOwner(_ state: State) -> PlayerFocusOwner {
        if state.hasError || state.hasOpenPanel || state.hasFocusableOverlay { return .unmanaged }
        return controlsInteractable(state) ? .transport : .sink
    }

    static func move(_ direction: PlayerRemoteDirection, in state: State) -> PlayerRemoteAction {
        guard focusOwner(state) == .sink else { return .none }
        // The pause card covers the picture with its own metadata; seeking behind it would be
        // invisible, so the first press takes it away and the transport comes back in its place.
        if state.showsPauseCard { return .dismissPauseCard }
        switch direction {
        case .left: return .seek(forward: false)
        case .right: return .seek(forward: true)
        case .up, .down: return .reveal
        }
    }

    static func select(in state: State) -> PlayerRemoteAction {
        guard focusOwner(state) == .sink else { return .none }
        return state.showsPauseCard ? .resume : .reveal
    }

    /// The one press whose meaning never changes: a dedicated Play/Pause key is not a request
    /// to navigate, so it works from inside a panel too.
    static func playPause(in state: State) -> PlayerRemoteAction {
        state.hasError ? .none : .togglePause
    }
}
