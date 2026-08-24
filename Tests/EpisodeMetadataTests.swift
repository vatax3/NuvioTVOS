import XCTest
@testable import Nuvio

/// TMDB episode metadata, and the one field of it that had been decoded away.
///
/// Upstream shows an IMDb score per episode, fetched from two services whose base URLs are build
/// secrets — `placeholder.nuvio.tv` in the public source — so that number cannot be had here.
/// TMDB's own score arrives in the response the titles, stills and air dates already come from.
final class EpisodeMetadataTests: XCTestCase {
    private func video(season: Int, episode: Int) -> Video {
        var video = Video(id: "tt0903747:\(season):\(episode)")
        video.season = season
        video.episode = episode
        return video
    }

    private func detail(episode: Int, rating: Double?) -> TMDBClient.EpisodeDetail {
        TMDBClient.EpisodeDetail(
            season: 1, episode: episode, name: "Pilot", overview: nil, still: nil,
            airDate: "2008-01-20", runtimeMinutes: 58, rating: rating
        )
    }

    func testTheRatingIsCarriedOntoTheEpisode() {
        let merged = MetaDetailsViewModel.merging(
            [detail(episode: 1, rating: 8.2)], into: [video(season: 1, episode: 1)], season: 1
        )

        XCTAssertEqual(merged.first?.tmdbRating, 8.2)
    }

    /// The merge rule everywhere else in this function: fill blanks, never overwrite.
    func testARatingAlreadyPresentIsNotReplaced() {
        var existing = video(season: 1, episode: 1)
        existing.tmdbRating = 9.1

        let merged = MetaDetailsViewModel.merging(
            [detail(episode: 1, rating: 8.2)], into: [existing], season: 1
        )

        XCTAssertEqual(merged.first?.tmdbRating, 9.1)
    }

    func testAnEpisodeFromAnotherSeasonIsLeftAlone() {
        let merged = MetaDetailsViewModel.merging(
            [detail(episode: 1, rating: 8.2)], into: [video(season: 2, episode: 1)], season: 1
        )

        XCTAssertNil(merged.first?.tmdbRating)
        XCTAssertNil(merged.first?.released)
    }

    func testAnEpisodeNobodyScoredHasNoRating() {
        let merged = MetaDetailsViewModel.merging(
            [detail(episode: 1, rating: nil)], into: [video(season: 1, episode: 1)], season: 1
        )

        XCTAssertNil(merged.first?.tmdbRating)
        XCTAssertEqual(merged.first?.released, "2008-01-20", "The rest of the merge still runs")
    }
}
