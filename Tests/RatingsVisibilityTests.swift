import XCTest
@testable import Nuvio

/// The rating-visibility rules, reinstated after the 1.0.15 audit withdrew them against a tree
/// older than the release it named. They ship in Android TV `0.8.7-beta` and above.
final class RatingsVisibilityTests: XCTestCase {
    func testHomeIsAPlainSwitch() {
        XCTAssertTrue(HomeRatingsVisibility.showAll.showsRatings)
        XCTAssertFalse(HomeRatingsVisibility.hideAll.showsRatings)
    }

    func testTheTitleRatingSurvivesEverythingButHideAll() {
        XCTAssertTrue(DetailRatingsVisibility.showAll.showsTitleRating)
        XCTAssertTrue(DetailRatingsVisibility.hideUnwatchedEpisodes.showsTitleRating)
        XCTAssertTrue(DetailRatingsVisibility.hideEpisodes.showsTitleRating)
        XCTAssertFalse(DetailRatingsVisibility.hideAll.showsTitleRating)
    }

    /// The setting worth having: a 9.6 three episodes ahead says something happens there, so the
    /// score is itself a spoiler until the episode has been watched.
    func testHideUntilWatchedIsExactlyThat() {
        let mode = DetailRatingsVisibility.hideUnwatchedEpisodes

        XCTAssertTrue(mode.showsEpisodeRating(isWatched: true))
        XCTAssertFalse(mode.showsEpisodeRating(isWatched: false))
    }

    func testTheOtherModesIgnoreWatchedState() {
        for watched in [true, false] {
            XCTAssertTrue(DetailRatingsVisibility.showAll.showsEpisodeRating(isWatched: watched))
            XCTAssertFalse(DetailRatingsVisibility.hideEpisodes.showsEpisodeRating(isWatched: watched))
            XCTAssertFalse(DetailRatingsVisibility.hideAll.showsEpisodeRating(isWatched: watched))
        }
    }

    /// Hiding everything must also hide the episodes; a mode that hid the title and left the
    /// episode scores on screen would be the wrong way round.
    func testHidingEverythingHidesTheEpisodesToo() {
        XCTAssertFalse(DetailRatingsVisibility.hideAll.showsEpisodeRating(isWatched: true))
    }

    /// The keys are the wire format for account sync, so they must stay the Android ones.
    func testTheStoredKeysMatchAndroid() {
        XCTAssertEqual(HomeRatingsVisibility.showAll.rawValue, "SHOW_ALL")
        XCTAssertEqual(HomeRatingsVisibility.hideAll.rawValue, "HIDE_ALL")
        XCTAssertEqual(DetailRatingsVisibility.hideUnwatchedEpisodes.rawValue, "HIDE_UNWATCHED_EPISODES")
        XCTAssertEqual(DetailRatingsVisibility.hideEpisodes.rawValue, "HIDE_EPISODES")
    }

    func testEveryModeIsDescribed() {
        for mode in DetailRatingsVisibility.allCases {
            XCTAssertFalse(mode.displayName.isEmpty)
            XCTAssertFalse(mode.summary.isEmpty)
        }
    }
}

/// Ordering the saved-titles grid.
final class LibrarySortOptionTests: XCTestCase {
    private func item(_ name: String, _ addedAt: Date) -> SavedLibraryItem {
        SavedLibraryItem(
            preview: MetaPreview(id: name, type: .movie, rawType: "movie", name: name),
            addedAt: addedAt
        )
    }

    private var items: [SavedLibraryItem] {
        [
            item("Solaris", Date(timeIntervalSince1970: 300)),
            item("Andrei Rublev", Date(timeIntervalSince1970: 100)),
            item("stalker", Date(timeIntervalSince1970: 200))
        ]
    }

    func testRecentlyAddedIsNewestFirst() {
        XCTAssertEqual(
            items.sorted(by: .recentlyAdded).map(\.preview.name),
            ["Solaris", "stalker", "Andrei Rublev"]
        )
    }

    func testFirstAddedIsTheOtherWayRound() {
        XCTAssertEqual(
            items.sorted(by: .firstAdded).map(\.preview.name),
            ["Andrei Rublev", "stalker", "Solaris"]
        )
    }

    /// Case-insensitively, or a lowercase title lands after Z and a viewer scrolling to find it
    /// concludes it is gone.
    func testTitleSortIgnoresCase() {
        XCTAssertEqual(
            items.sorted(by: .titleAscending).map(\.preview.name),
            ["Andrei Rublev", "Solaris", "stalker"]
        )
        XCTAssertEqual(
            items.sorted(by: .titleDescending).map(\.preview.name),
            ["stalker", "Solaris", "Andrei Rublev"]
        )
    }

    func testTheStoredKeysMatchAndroid() {
        XCTAssertEqual(LibrarySortOption.recentlyAdded.rawValue, "added_desc")
        XCTAssertEqual(LibrarySortOption.firstAdded.rawValue, "added_asc")
        XCTAssertEqual(LibrarySortOption.titleAscending.rawValue, "title_asc")
        XCTAssertEqual(LibrarySortOption.titleDescending.rawValue, "title_desc")
    }

    func testSortingAnEmptyLibraryIsNotAnEdgeCase() {
        for option in LibrarySortOption.allCases {
            XCTAssertTrue([SavedLibraryItem]().sorted(by: option).isEmpty)
        }
    }
}
