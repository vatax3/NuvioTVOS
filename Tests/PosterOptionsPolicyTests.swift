import XCTest
@testable import Nuvio

/// Which rows a long press offers, and — more to the point — which it does not.
final class PosterOptionsPolicyTests: XCTestCase {
    private func context(
        type: ContentType = .movie,
        inLibrary: Bool = false,
        watched: Bool = false,
        progress: Bool = false
    ) -> PosterOptionsPolicy.Context {
        .init(type: type, isInLibrary: inLibrary, isWatched: watched, hasProgress: progress)
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

    /// The scope call, pinned: marking a whole series watched needs a walk over its episodes
    /// that does not exist yet, and a row that quietly does less than it says is worse than no
    /// row. If the walk lands, this test is the thing that should fail first.
    func testASeriesIsNotOfferedAWatchedRow() {
        let actions = PosterOptionsPolicy.actions(for: context(type: .series))

        XCTAssertFalse(actions.contains(.markWatched))
        XCTAssertFalse(actions.contains(.markUnwatched))
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
            [.removeFromLibrary, .removeFromContinueWatching, .markUnwatched]
        )
    }

    /// Every row needs an icon, and a typo in one would silently draw nothing on a television.
    func testEveryRowHasASymbol() {
        for action in PosterOptionsPolicy.Action.allCases {
            XCTAssertFalse(action.systemImage.isEmpty, "\(action) has no symbol")
        }
    }
}
