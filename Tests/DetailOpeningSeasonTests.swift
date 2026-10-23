import XCTest
@testable import Nuvio

/// Which season the detail screen opens on.
///
/// It opened on the first season every time, so a viewer four seasons into a series was handed
/// S1E1 and had to walk back to where they were — while the *Play* button beside the list was
/// already naming the right episode. The two now agree.
final class DetailOpeningSeasonTests: XCTestCase {
    private func episode(season: Int, episode: Int) -> Video {
        Video(id: "tt0944947:\(season):\(episode)", season: season, episode: episode)
    }

    func testItOpensOnTheSeasonHoldingTheEpisodeToResume() {
        XCTAssertEqual(
            MetaDetailsViewModel.openingSeason(resuming: episode(season: 3, episode: 4), in: [1, 2, 3, 4]),
            3
        )
    }

    /// Nothing watched: the first season the series lists, which is not always 1 — a specials
    /// season is 0, and some addons list a series whose first entry is season 2.
    func testAnUntouchedSeriesOpensOnItsFirstSeason() {
        XCTAssertEqual(MetaDetailsViewModel.openingSeason(resuming: nil, in: [0, 1, 2]), 0)
        XCTAssertEqual(MetaDetailsViewModel.openingSeason(resuming: nil, in: [2, 3]), 2)
    }

    /// Next Up can point at an episode the selected metadata does not list — a sibling addon's
    /// numbering, or a season dropped from the response. Falling back beats selecting an empty tab.
    func testASeasonTheSeriesDoesNotListFallsBack() {
        XCTAssertEqual(
            MetaDetailsViewModel.openingSeason(resuming: episode(season: 9, episode: 1), in: [1, 2]),
            1
        )
    }

    func testAMovieHasNoSeasonToOpen() {
        XCTAssertNil(MetaDetailsViewModel.openingSeason(resuming: nil, in: []))
    }
}
