import XCTest
@testable import Nuvio

/// Continue Watching skips a row it has no artwork for, and only this device ever cached any.
/// Titles watched on another device arrived through account sync with a resume point and nothing
/// to draw, so the rail stayed empty while the account was full (#4). `progressMissingPreviews`
/// is the list Home fetches artwork for.
@MainActor
final class ContinueWatchingArtworkTests: XCTestCase {
    private func store() -> LibraryStore {
        let store = LibraryStore()
        for existing in store.progress.values { store.clearProgress(videoId: existing.videoId) }
        store.clearPendingProgressDeletions(store.pendingProgressDeletions)
        return store
    }

    private func row(
        _ contentId: String,
        type: String = "movie",
        videoId: String? = nil,
        position: Double = 60,
        age: TimeInterval = 0
    ) -> WatchProgress {
        WatchProgress(
            contentId: contentId, contentType: type, videoId: videoId ?? contentId,
            season: nil, episode: nil, positionSeconds: position, durationSeconds: 120,
            updatedAt: Date().addingTimeInterval(-age)
        )
    }

    private func missing(_ store: LibraryStore) -> [String] {
        store.progressMissingPreviews(threshold: 0.9).map { "\($0.contentType)|\($0.contentId)" }
    }

    func testASyncedRowWithNoArtworkIsListed() {
        let store = store()
        store.adoptProgress([row("tt1")])
        XCTAssertEqual(missing(store), ["movie|tt1"])
    }

    func testFinishedRowsAreNotListed() {
        let store = store()
        store.adoptProgress([row("tt1", position: 119)])
        XCTAssertEqual(missing(store), [])
    }

    func testOneEntryPerTitleNewestFirst() {
        let store = store()
        store.adoptProgress([
            row("tt2", type: "series", videoId: "tt2:1:1", age: 300),
            row("tt2", type: "series", videoId: "tt2:1:2", age: 100),
            row("tt1", age: 200)
        ])
        XCTAssertEqual(missing(store), ["series|tt2", "movie|tt1"])
    }

    /// Cached under the row's own key, so a preview the addon labels differently still counts.
    func testACachedPreviewTakesTheRowOffTheList() {
        let store = store()
        store.adoptProgress([row("tt3", type: "tv")])
        let preview = MetaPreview(id: "tt3", type: .series, rawType: "series", name: "Show")
        store.cache(preview, contentType: "tv", contentId: "tt3")

        XCTAssertEqual(missing(store), [])
        XCTAssertEqual(store.continueWatching(threshold: 0.9).map(\.progress.contentId), ["tt3"])
    }

    func testOtherClientsSeriesTypesAskAddonsForSeries() {
        XCTAssertEqual(RemoteProgressService.metaTypes(for: "tv"), ["series"])
        XCTAssertEqual(RemoteProgressService.metaTypes(for: "movie"), ["movie"])
    }
}
