import XCTest
@testable import Nuvio

/// Which rows a long press offers, and — more to the point — which it does not.
final class PosterOptionsPolicyTests: XCTestCase {
    private func context(
        type: ContentType = .movie,
        inLibrary: Bool = false,
        watched: Bool = false,
        progress: Bool = false,
        suggestion: Bool = false,
        knownEpisodes: Bool = false,
        traktLists: Bool = false
    ) -> PosterOptionsPolicy.Context {
        .init(
            type: type, isInLibrary: inLibrary, isWatched: watched,
            hasProgress: progress, isNextUpSuggestion: suggestion,
            canWalkEpisodes: knownEpisodes, hasTraktLists: traktLists
        )
    }

    func testALibraryRowIsAlwaysOffered() {
        XCTAssertEqual(PosterOptionsPolicy.actions(for: context()).first, .addToLibrary)
        XCTAssertEqual(
            PosterOptionsPolicy.actions(for: context(inLibrary: true)).first,
            .removeFromLibrary
        )
    }

    /// The two library rows are one control in two states, so exactly one must ever be present.
    func testTheLibraryRowIsNeverBothAtOnce() {
        for inLibrary in [true, false] {
            let actions = PosterOptionsPolicy.actions(for: context(inLibrary: inLibrary))
            XCTAssertEqual(actions.filter { $0 == .addToLibrary || $0 == .removeFromLibrary }.count, 1)
        }
    }

    func testTheWatchedRowFollowsTheCurrentState() {
        XCTAssertTrue(PosterOptionsPolicy.actions(for: context()).contains(.markWatched))
        XCTAssertTrue(PosterOptionsPolicy.actions(for: context(watched: true)).contains(.markUnwatched))
        XCTAssertFalse(PosterOptionsPolicy.actions(for: context(watched: true)).contains(.markWatched))
    }

    /// This was the pinned scope call — a series got no watched row, because nothing walked its
    /// episodes. `SeriesWatchedWalk` does now, and the rule that replaced it is narrower: the row
    /// appears when the episodes are *known*.
    ///
    /// Worth recording how the pin behaved when the walk landed, because it did not fire.
    /// `canWalkEpisodes` arrived with a default of `false`, so this test kept passing while
    /// quietly becoming an assertion about a different case. A defaulted field is exactly how a
    /// guard stops guarding, which is why the positive case below is now its twin.
    func testASeriesWithNoKnownEpisodesIsNotOfferedAWatchedRow() {
        let actions = PosterOptionsPolicy.actions(for: context(type: .series))

        XCTAssertFalse(actions.contains(.markWatched))
        XCTAssertFalse(actions.contains(.markUnwatched))
    }

    /// An empty episode list is a series nobody has opened, not a series with no episodes. Once
    /// they are known, the row does exactly what it says.
    func testASeriesWithKnownEpisodesIsOfferedAWatchedRow() {
        XCTAssertTrue(
            PosterOptionsPolicy.actions(for: context(type: .series, knownEpisodes: true))
                .contains(.markWatched)
        )
        XCTAssertTrue(
            PosterOptionsPolicy.actions(for: context(type: .series, watched: true, knownEpisodes: true))
                .contains(.markUnwatched)
        )
    }

    /// A film is its own episode, so the walk has nothing to say about it either way.
    func testAFilmNeverNeedsKnownEpisodes() {
        for known in [true, false] {
            XCTAssertTrue(
                PosterOptionsPolicy.actions(for: context(type: .movie, knownEpisodes: known))
                    .contains(.markWatched)
            )
        }
    }

    /// The reason the dialog exists: `LibraryStore.clearProgress` shipped for releases with no
    /// caller in the interface, so a resume point could be made from anywhere and removed from
    /// nowhere.
    func testARemovableResumePointIsOfferedARemoval() {
        XCTAssertTrue(
            PosterOptionsPolicy.actions(for: context(progress: true))
                .contains(.removeFromContinueWatching)
        )
    }

    /// And it is offered for a series too, even though the watched row is not: the resume point
    /// is on an episode, but the row the viewer wants gone is the whole title.
    func testASeriesInContinueWatchingCanStillBeRemoved() {
        XCTAssertTrue(
            PosterOptionsPolicy.actions(for: context(type: .series, progress: true))
                .contains(.removeFromContinueWatching)
        )
    }

    /// A projected row has nothing watched of it, so there is no resume point to remove — what
    /// the viewer wants gone is the suggestion.
    func testASuggestionIsDismissedRatherThanRemoved() {
        let actions = PosterOptionsPolicy.actions(for: context(type: .series, suggestion: true))

        XCTAssertTrue(actions.contains(.dismissNextUp))
        XCTAssertFalse(actions.contains(.removeFromContinueWatching))
    }

    /// And the two never appear together, or the dialog offers one thing twice.
    func testASuggestionWithStaleProgressStillOffersOnlyTheDismissal() {
        let actions = PosterOptionsPolicy.actions(
            for: context(type: .series, progress: true, suggestion: true)
        )

        XCTAssertEqual(actions.filter { $0 == .dismissNextUp || $0 == .removeFromContinueWatching }.count, 1)
        XCTAssertTrue(actions.contains(.dismissNextUp))
    }

    func testNothingOffersARemovalWithNothingToRemove() {
        XCTAssertFalse(
            PosterOptionsPolicy.actions(for: context()).contains(.removeFromContinueWatching)
        )
    }

    func testDetailsIsAlwaysTheWayOut() {
        for type in [ContentType.movie, .series] {
            for progress in [true, false] {
                let actions = PosterOptionsPolicy.actions(for: context(type: type, progress: progress))
                XCTAssertEqual(actions.last, .openDetails, "details should close the list")
            }
        }
    }

    /// A dialog of six identical rows makes an irreversible choice as easy to hit as a safe one.
    func testOnlyTheUndoingRowsAreMarkedDestructive() {
        let destructive = PosterOptionsPolicy.Action.allCases.filter(\.isDestructive)

        XCTAssertEqual(
            Set(destructive),
            [.removeFromLibrary, .removeFromContinueWatching, .markUnwatched, .dismissNextUp]
        )
    }

    /// A row that opens a dialog saying "you have no lists" is worse than no row.
    func testTheListRowNeedsSomewhereToPutIt() {
        XCTAssertFalse(PosterOptionsPolicy.actions(for: context()).contains(.manageLists))
        XCTAssertTrue(
            PosterOptionsPolicy.actions(for: context(traktLists: true)).contains(.manageLists)
        )
    }

    /// Filing something into a list is not undoing anything, so it must not be dressed as
    /// destructive — that colouring only means something while it is rare.
    func testTheListRowIsNotDestructive() {
        XCTAssertFalse(PosterOptionsPolicy.Action.manageLists.isDestructive)
    }

    /// Details still closes the list, whatever else is on it.
    func testDetailsStaysLastWithTheListRowPresent() {
        XCTAssertEqual(
            PosterOptionsPolicy.actions(for: context(traktLists: true)).last,
            .openDetails
        )
    }

    /// Every row needs an icon, and a typo in one would silently draw nothing on a television.
    func testEveryRowHasASymbol() {
        for action in PosterOptionsPolicy.Action.allCases {
            XCTAssertFalse(action.systemImage.isEmpty, "\(action) has no symbol")
        }
    }
}
