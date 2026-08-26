import XCTest
@testable import Nuvio

/// What removing a title from a tracking account destroys, and where it destroys nothing.
///
/// The whole point of this type is that it is narrower than upstream's generic warning. A
/// warning that fires where nothing is lost teaches people to dismiss the one that matters.
final class TrackingRemovalImpactTests: XCTestCase {

    /// Simkl removes with `sync/history/remove` — the same call "mark unwatched" makes. Its list
    /// state and its watched history are one record.
    func testSimklLosesTheWatchedHistory() {
        XCTAssertEqual(TrackingRemovalImpact.losses(removingFrom: .simkl), [.watchedHistory])
        XCTAssertTrue(TrackingRemovalImpact.requiresConfirmation(removingFrom: .simkl))
    }

    /// Trakt removes with `sync/watchlist` remove, which touches the watchlist and nothing else.
    /// Warning here would be inventing a consequence.
    func testTraktLosesNothingAndIsNotWarnedAbout() {
        XCTAssertTrue(TrackingRemovalImpact.losses(removingFrom: .trakt).isEmpty)
        XCTAssertFalse(TrackingRemovalImpact.requiresConfirmation(removingFrom: .trakt))
    }

    /// The local library is not a tracking account, and a confirmation over a local toggle is
    /// friction with nothing behind it.
    func testTheLocalCaseIsNotWarnedAbout() {
        XCTAssertTrue(TrackingRemovalImpact.losses(removingFrom: nil).isEmpty)
        XCTAssertFalse(TrackingRemovalImpact.requiresConfirmation(removingFrom: nil))
    }

    /// The prompt has to name the provider and the title, or it reads as being about the local
    /// library — which is the thing the viewer thinks they are pressing.
    func testThePromptNamesBothTheTitleAndTheService() {
        let prompt = TrackingRemovalImpact.prompt(title: "Breaking Bad", provider: .simkl)

        XCTAssertTrue(prompt.contains("Breaking Bad"))
        XCTAssertTrue(prompt.contains("Simkl"))
        XCTAssertTrue(prompt.hasSuffix("?"))
    }

    /// The consequence has to say what goes, not that something goes.
    func testTheCautionNamesWhatIsLost() throws {
        let caution = try XCTUnwrap(TrackingRemovalImpact.caution(provider: .simkl))

        XCTAssertTrue(caution.contains("watched"))
        XCTAssertTrue(caution.contains("Simkl"))
        XCTAssertTrue(caution.lowercased().contains("undone"))
    }

    func testThereIsNoCautionWhereThereIsNoLoss() {
        XCTAssertNil(TrackingRemovalImpact.caution(provider: .trakt))
    }

    /// Every provider has to have an answer, or a new one silently gets the safe-looking
    /// no-warning path.
    func testEveryProviderIsAccountedFor() {
        for provider in TrackingProviderId.allCases {
            XCTAssertFalse(provider.displayName.isEmpty, "\(provider) has no name to warn with")
            let warns = TrackingRemovalImpact.requiresConfirmation(removingFrom: provider)
            XCTAssertEqual(
                warns,
                TrackingRemovalImpact.caution(provider: provider) != nil,
                "\(provider) warns and cautions inconsistently"
            )
        }
    }
}
