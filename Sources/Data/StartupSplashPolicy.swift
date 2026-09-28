import Foundation

/// Whether the branded splash is on screen, and whether Home draws its own loader behind it.
///
/// Port of `StartupLoadingPolicy`. Two rules rather than one, and the second is the reason the
/// first is not just `enabled && loading`: the splash and Home's skeleton rails are both "we are
/// still getting ready", and drawing them together is two loading states stacked on one screen.
///
/// The destination gate matters as much. A cold launch straight into a deep link — a Top Shelf
/// row, a continue-watching tile — is a launch the viewer has already told us the destination of,
/// and covering it with a logo delays the one thing they asked for.
enum StartupSplashPolicy {
    /// Where the app came up.
    enum Destination: Equatable {
        /// Nothing resolved yet.
        case loading
        /// First run: the experience-mode and layout choices.
        case setup
        case home
        /// Anything reached directly — a deep link, or a restored destination.
        case content
    }

    /// The splash covers a launch that is heading for Home, and only while it is still working.
    ///
    /// First run is excluded deliberately: the setup flow is its own branded first impression, and
    /// a logo in front of it would be the second full-screen thing between the viewer and the app
    /// they just installed.
    static func showsSplash(enabled: Bool, isComplete: Bool, destination: Destination) -> Bool {
        enabled && !isComplete && (destination == .loading || destination == .home)
    }

    /// Home's own loader, which must not run *behind* the splash.
    ///
    /// Once the splash has gone the loader takes over if the rails are still filling, so a slow
    /// addon does not leave an empty screen — the handover is what makes one loading state rather
    /// than two.
    static func showsHomeLoader(
        isLoading: Bool, splashEnabled: Bool, isComplete: Bool
    ) -> Bool {
        isLoading && (!splashEnabled || isComplete)
    }
}
