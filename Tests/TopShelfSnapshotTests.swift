import XCTest
@testable import Nuvio

final class TopShelfSnapshotTests: XCTestCase {
    private func progress(_ id: String, at fraction: Double) -> WatchProgress {
        WatchProgress(
            contentId: id, contentType: "movie", videoId: id,
            season: nil, episode: nil, positionSeconds: 100 * fraction, durationSeconds: 100, updatedAt: Date()
        )
    }

    /// The shelf lists what Continue Watching lists: a fixed 0.9 dropped titles at 90–95%.
    func testTheShelfFollowsTheWatchedThreshold() {
        let items = ["tt1": progress("tt1", at: 0.92), "tt2": progress("tt2", at: 0.97)]
        let previews = [
            "movie|tt1": MetaPreview(id: "tt1", type: .movie, rawType: "movie", name: "One"),
            "movie|tt2": MetaPreview(id: "tt2", type: .movie, rawType: "movie", name: "Two"),
        ]
        let shelf = TopShelfSnapshotPublisher.snapshot(progress: items, previews: previews, threshold: 0.95)
        XCTAssertEqual(shelf.entries.map(\.id), ["tt1"])
    }
}
