import XCTest
@testable import Nuvio

/// Surviving a tvOS storage reclaim.
///
/// `library.json` and `watch-progress.json` live in Caches, which the system is documented as
/// free to empty under pressure. For a viewer signed into a Nuvio account that is survivable —
/// the next sync brings the rows back. For a viewer who never connected one, a reclaim took their
/// entire library and there was nothing to rebuild it from.
///
/// The fix is the one the addon list got in 1.0.37: keep what the viewer *made* somewhere durable
/// and let the rest be re-fetched. tvOS leaves one durable place, `UserDefaults`, which is read
/// wholesale on access and therefore budgeted — so the interesting half of this is not the copy,
/// it is what happens when the copy outgrows its budget.
final class LibraryDurabilityTests: XCTestCase {
    private func item(_ id: String, name: String = "A title", addedAt: Date) -> SavedLibraryItem {
        SavedLibraryItem(
            preview: MetaPreview(id: id, type: .movie, rawType: "movie", name: name),
            addedAt: addedAt
        )
    }

    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: What is kept

    func testARefKeepsEnoughToFindTheTitleAgain() {
        var preview = MetaPreview(id: "tt1375666", type: .movie, rawType: "movie", name: "Inception")
        preview.poster = "https://addon.test/poster.jpg"
        let ref = LibraryEntryRef(SavedLibraryItem(preview: preview, addedAt: epoch))

        XCTAssertEqual(ref.id, "tt1375666")
        XCTAssertEqual(ref.rowKey, "movie|tt1375666")
        XCTAssertEqual(ref.name, "Inception")
        XCTAssertEqual(ref.addedAt, epoch)
    }

    /// The artwork is what makes a preview large and is exactly what can be fetched again, so it
    /// is the part that does not go into the durable copy.
    func testARefIsSmallEnoughForALibraryToFit() {
        let ref = LibraryEntryRef(item("tt1375666", name: "Inception", addedAt: epoch))

        // A thousand titles inside the budget is the claim the design rests on.
        XCTAssertLessThan(DurableLibraryBudget.encodedSize([ref]) * 1_000, DurableLibraryBudget.byteBudget)
    }

    func testARestoredEntryPrefersTheCachedArtwork() {
        var cached = MetaPreview(id: "tt1375666", type: .movie, rawType: "movie", name: "Inception")
        cached.poster = "https://addon.test/poster.jpg"
        let ref = LibraryEntryRef(item("tt1375666", addedAt: epoch))

        let restored = ref.restored(preview: cached)

        XCTAssertEqual(restored.preview.poster, "https://addon.test/poster.jpg")
        XCTAssertEqual(restored.addedAt, epoch)
    }

    /// The preview cache is purgeable too, so it is usually gone in exactly the situation this
    /// recovery exists for. A row with no poster is visibly worse than one with; it is enormously
    /// better than a row that is not there.
    func testARestoredEntryStillWorksWithNoArtworkAtAll() {
        let ref = LibraryEntryRef(item("tt1375666", name: "Inception", addedAt: epoch))

        let restored = ref.restored(preview: nil)

        XCTAssertEqual(restored.preview.id, "tt1375666")
        XCTAssertEqual(restored.preview.name, "Inception")
        XCTAssertEqual(restored.preview.type, .movie)
        XCTAssertNil(restored.preview.poster)
    }

    // MARK: The budget

    /// `JSONFileStore` refuses an over-budget write and **logs rather than throws**, so a store
    /// that quietly outgrows its budget simply stops persisting — worse than the purgeable
    /// location it was moved out of. Nothing reaches a durable store un-bounded.
    func testALibraryThatFitsIsNotTrimmedAtAll() {
        let refs = (0..<200).map {
            LibraryEntryRef(item("tt\($0)", addedAt: epoch.addingTimeInterval(Double($0))))
        }

        XCTAssertEqual(DurableLibraryBudget.fitting(refs).count, 200)
    }

    func testAnOversizedLibraryIsTrimmedToFit() {
        let refs = (0..<20_000).map {
            LibraryEntryRef(
                item("tt\($0)", name: String(repeating: "A title", count: 4),
                     addedAt: epoch.addingTimeInterval(Double($0)))
            )
        }

        let kept = DurableLibraryBudget.fitting(refs)

        XCTAssertLessThan(kept.count, refs.count)
        XCTAssertLessThanOrEqual(
            DurableLibraryBudget.encodedSize(kept), DurableLibraryBudget.byteBudget
        )
    }

    /// Oldest-first, because recency is the only ordering that matches what a viewer would
    /// choose: last night's addition is the one they would miss.
    func testTrimmingDropsTheOldestFirst() {
        let refs = (0..<20_000).map {
            LibraryEntryRef(
                item("tt\($0)", name: String(repeating: "A title", count: 4),
                     addedAt: epoch.addingTimeInterval(Double($0)))
            )
        }

        let kept = DurableLibraryBudget.fitting(refs)

        // The newest survives, the oldest does not.
        XCTAssertEqual(kept.first?.id, "tt19999")
        XCTAssertFalse(kept.contains { $0.id == "tt0" })
    }

    /// The trim has to stay just under the budget rather than well under it — a rule that
    /// discarded half the library whenever it overflowed would be a different bug.
    func testTrimmingKeepsAsMuchAsFits() {
        let refs = (0..<20_000).map {
            LibraryEntryRef(
                item("tt\($0)", name: String(repeating: "A title", count: 4),
                     addedAt: epoch.addingTimeInterval(Double($0)))
            )
        }

        let kept = DurableLibraryBudget.fitting(refs)
        let oneMore = Array(
            refs.sorted { $0.addedAt > $1.addedAt }.prefix(kept.count + 1)
        )

        XCTAssertGreaterThan(DurableLibraryBudget.encodedSize(oneMore), DurableLibraryBudget.byteBudget)
    }

    func testAnEmptyLibraryTrimsToNothingWithoutFailing() {
        XCTAssertEqual(DurableLibraryBudget.fitting([LibraryEntryRef]()).count, 0)
    }

    // MARK: Resume points

    private func progress(_ videoId: String, fraction: Double, at date: Date) -> WatchProgress {
        WatchProgress(
            contentId: videoId, contentType: "movie", videoId: videoId,
            season: nil, episode: nil,
            positionSeconds: 100 * fraction, durationSeconds: 100, updatedAt: date
        )
    }

    func testResumePointsAreTrimmedByRecency() {
        let rows = (0..<20_000).map {
            progress("tt\($0)", fraction: 0.5, at: epoch.addingTimeInterval(Double($0)))
        }

        let kept = DurableLibraryBudget.fitting(rows)

        XCTAssertEqual(kept.first?.videoId, "tt19999")
        XCTAssertLessThanOrEqual(
            DurableLibraryBudget.encodedSize(kept), DurableLibraryBudget.byteBudget
        )
    }
}

/// The recovery itself, against a real store.
@MainActor
final class LibraryReclaimRecoveryTests: XCTestCase {
    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    private func emptyStore() -> LibraryStore {
        let store = LibraryStore()
        for saved in store.library { store.toggleLibrary(saved.preview) }
        store.clearPendingLibraryDeletions(store.pendingLibraryDeletions)
        for existing in store.progress.values { store.clearProgress(videoId: existing.videoId) }
        store.clearPendingProgressDeletions(store.pendingProgressDeletions)
        return store
    }

    override func tearDown() {
        Task { @MainActor in
            let store = LibraryStore()
            for saved in store.library { store.toggleLibrary(saved.preview) }
            store.clearPendingLibraryDeletions(store.pendingLibraryDeletions)
            for existing in store.progress.values { store.clearProgress(videoId: existing.videoId) }
            store.clearPendingProgressDeletions(store.pendingProgressDeletions)
        }
        super.tearDown()
    }

    /// The whole point: a title saved by a viewer with no account comes back after Caches is
    /// emptied, because a second store built from the same durable copy finds it.
    func testASavedTitleSurvivesANewStore() {
        let store = emptyStore()
        let preview = MetaPreview(id: "tt1375666", type: .movie, rawType: "movie", name: "Inception")
        store.toggleLibrary(preview)

        let reopened = LibraryStore()

        XCTAssertTrue(reopened.library.contains { $0.preview.id == "tt1375666" })
    }

    /// A removal must not be undone by the recovery. The durable copy is rewritten on the same
    /// write that performs the removal, so a title taken out is gone from both — otherwise this
    /// would resurrect exactly what the deletion queues exist to stop.
    func testARemovedTitleDoesNotComeBack() {
        let store = emptyStore()
        let preview = MetaPreview(id: "tt1375666", type: .movie, rawType: "movie", name: "Inception")
        store.toggleLibrary(preview)
        store.toggleLibrary(preview)

        let reopened = LibraryStore()

        XCTAssertFalse(reopened.library.contains { $0.preview.id == "tt1375666" })
    }

    /// The gap this nearly shipped with. On the first launch after the upgrade the durable copy
    /// does not exist, and nothing would write it until the viewer next added or removed a title —
    /// so a library saved months ago stayed unprotected for as long as nobody touched it, which is
    /// precisely the library this feature exists for.
    func testAnExistingLibraryIsProtectedOnTheFirstLaunchAfterUpgrading() {
        let store = emptyStore()
        let preview = MetaPreview(id: "tt0068646", type: .movie, rawType: "movie", name: "The Godfather")
        store.toggleLibrary(preview)

        // Stand in for an upgrade: the durable copy is gone, the purgeable one is not.
        JSONFileStore<[LibraryEntryRef]>(
            filename: "library-identity.json", durability: .critical
        ).delete()

        _ = LibraryStore()
        let durable = JSONFileStore<[LibraryEntryRef]>(
            filename: "library-identity.json", durability: .critical
        ).load() ?? []

        XCTAssertTrue(durable.contains { $0.id == "tt0068646" })
    }

    /// A resume point is what a viewer notices vanishing.
    func testAResumePointSurvivesANewStore() {
        let store = emptyStore()
        store.record(
            contentId: "tt1375666", contentType: "movie", videoId: "tt1375666",
            season: nil, episode: nil, position: 600, duration: 8_880, preview: nil
        )

        let reopened = LibraryStore()

        XCTAssertNotNil(reopened.progress(forVideoId: "tt1375666"))
    }

    /// Watched marks are the bulk of the progress store and deliberately stay purgeable: they
    /// would not fit the durable budget, and losing one costs a tick on an episode rather than a
    /// place in a film. Pinned so the exclusion stays a decision rather than drifting.
    func testAFinishedTitleIsNotKeptInTheDurableCopy() {
        let store = emptyStore()
        store.markWatched(
            contentId: "tt0111161", contentType: "movie", videoId: "tt0111161",
            season: nil, episode: nil, duration: 8_520
        )

        let durable = JSONFileStore<[WatchProgress]>(
            filename: "resume-points.json", durability: .critical
        ).load() ?? []

        XCTAssertFalse(durable.contains { $0.videoId == "tt0111161" })
    }
}
