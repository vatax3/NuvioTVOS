#if DEBUG
import Foundation

/// Seeds one saved title and one resume point, so a UI test has a poster to press on.
///
/// The long press is in the same category as the player's remote handling: whether the gesture
/// ever reaches `PosterOptionsPolicy` depends on how tvOS routes a held Select through a focused
/// `Button`, which exists only at runtime. `PosterOptionsPolicyTests` covers what the dialog
/// offers and has done since 1.0.18 — it cannot say whether anything opens it.
///
/// Two different titles rather than one: the library grid and the Continue Watching rail have
/// separate gestures on separate cards, and a single title would let one card's identifier match
/// in both places.
enum LibraryHarness {
    static let launchArgument = "-nuvioLibraryHarness"

    static var isActive: Bool {
        ProcessInfo.processInfo.arguments.contains(launchArgument)
    }

    /// In the library, not started. The row the grid draws.
    static let savedId = "harness-saved"
    /// Started and unfinished, so it lands in Continue Watching. Deliberately *not* in the
    /// library, so the dialog it opens offers removal from the rail rather than from the grid.
    static let resumeId = "harness-resume"

    /// A resume point as account sync delivers one: a real IMDb id and no artwork cached here,
    /// so Continue Watching can only show it once Home has fetched its preview from an addon
    /// (#4). Seeded only with `syncedArgument`, since it needs the network.
    static let syncedArgument = "-nuvioSyncedProgressHarness"
    static let syncedId = "tt0111161"

    private static func preview(id: String, name: String) -> MetaPreview {
        MetaPreview(id: id, type: .movie, rawType: "movie", name: name)
    }

    @MainActor
    static func seed(into library: LibraryStore) {
        guard isActive else { return }
        // Artwork persists between launches; starting without it is what makes the synced row
        // test the fetch rather than a cache left by an earlier run.
        library.clearContinueWatchingCache()

        library.adoptSavedItem(SavedLibraryItem(
            preview: preview(id: savedId, name: "Harness Saved"),
            addedAt: Date()
        ))

        let resume = preview(id: resumeId, name: "Harness Resume")
        library.cache(resume)
        library.adoptProgress(WatchProgress(
            contentId: resumeId,
            contentType: "movie",
            videoId: resumeId,
            season: nil,
            episode: nil,
            // Comfortably between the 1% floor that keeps a barely-touched title out of the rail
            // and any watched threshold a profile could be set to.
            positionSeconds: 2_400,
            durationSeconds: 6_000,
            updatedAt: Date()
        ))

        if ProcessInfo.processInfo.arguments.contains(syncedArgument) {
            library.adoptProgress(WatchProgress(
                contentId: syncedId,
                contentType: "movie",
                videoId: syncedId,
                season: nil,
                episode: nil,
                positionSeconds: 1_800,
                durationSeconds: 8_500,
                updatedAt: Date().addingTimeInterval(-60)
            ))
        }
    }
}
#endif
