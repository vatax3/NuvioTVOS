import XCTest
@testable import Nuvio

/// What the home hero shows while a collection folder card holds focus.
///
/// Reported: moving onto a collection rail left the hero describing whichever title the cursor
/// had been on last, because a folder is not a media item and nothing reported the change. That
/// is worse than showing nothing — the hero was captioning something the cursor was no longer on.
/// Upstream builds a `HeroPreview` from the folder itself in `buildCollectionFolderItem`, which
/// is what this mirrors.
final class CollectionHeroTests: XCTestCase {
    private func collection(
        backdrop: String? = "https://example.test/collection.jpg",
        folder: CollectionFolder
    ) -> MediaCollection {
        MediaCollection(id: "c1", title: "Saturday night", backdropImageUrl: backdrop, folders: [folder])
    }

    func testTheFolderNamesItself() {
        let folder = CollectionFolder(id: "f1", title: "Comedies")
        let hero = folder.heroPreview(in: collection(folder: folder))
        XCTAssertEqual(hero.name, "Comedies")
    }

    func testAnEmojiCoverPrefixesTheName() {
        let folder = CollectionFolder(id: "f1", title: "Comedies", coverEmoji: "🍿")
        XCTAssertEqual(folder.heroPreview(in: collection(folder: folder)).name, "🍿  Comedies")
    }

    /// The same reason the card honours it: a cover with the name burned into the artwork should
    /// not have it written over the top a second time.
    func testHideTitleSuppressesTheNameAndTheLogo() {
        let folder = CollectionFolder(
            id: "f1", title: "Comedies", coverEmoji: "🍿", hideTitle: true,
            titleLogoUrl: "https://example.test/logo.png"
        )
        let hero = folder.heroPreview(in: collection(folder: folder))
        XCTAssertEqual(hero.name, "")
        XCTAssertNil(hero.logo)
    }

    func testTheHeroBackdropIsPreferred() {
        let folder = CollectionFolder(
            id: "f1", title: "Comedies",
            coverImageUrl: "https://example.test/cover.jpg",
            heroBackdropUrl: "https://example.test/hero.jpg"
        )
        XCTAssertEqual(
            folder.heroPreview(in: collection(folder: folder)).backdropUrl,
            "https://example.test/hero.jpg"
        )
    }

    /// Upstream's fallback chain. A folder with nothing but a cover still changes the picture,
    /// which is the whole point — the hero has to answer the cursor.
    func testTheCoverStandsInForAMissingHeroImage() {
        let folder = CollectionFolder(
            id: "f1", title: "Comedies", coverImageUrl: "https://example.test/cover.jpg"
        )
        XCTAssertEqual(
            folder.heroPreview(in: collection(folder: folder)).backdropUrl,
            "https://example.test/cover.jpg"
        )
    }

    func testTheCollectionBackdropIsTheLastResort() {
        let folder = CollectionFolder(id: "f1", title: "Comedies")
        XCTAssertEqual(
            folder.heroPreview(in: collection(folder: folder)).backdropUrl,
            "https://example.test/collection.jpg"
        )
    }

    /// A folder has no year, rating, runtime or synopsis, and inventing one would be worse than
    /// the blank. The hero renders those fields only when they are there.
    func testAFolderCarriesNoneOfTheFieldsATitleWould() {
        let folder = CollectionFolder(id: "f1", title: "Comedies")
        let hero = folder.heroPreview(in: collection(folder: folder))
        XCTAssertNil(hero.description)
        XCTAssertNil(hero.releaseInfo)
        XCTAssertNil(hero.imdbRating)
        XCTAssertNil(hero.runtime)
        XCTAssertNil(hero.ageRating)
        XCTAssertTrue(hero.genres.isEmpty)
    }

    /// Two folders must never collide in the hero's animation key, or crossing between them
    /// would not crossfade.
    func testFoldersGetDistinctIdentities() {
        let first = CollectionFolder(id: "f1", title: "Comedies")
        let second = CollectionFolder(id: "f2", title: "Thrillers")
        let host = MediaCollection(id: "c1", title: "Saturday night", folders: [first, second])
        XCTAssertNotEqual(
            first.heroPreview(in: host).rowKey,
            second.heroPreview(in: host).rowKey
        )
    }
}
