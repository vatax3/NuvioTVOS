import XCTest
@testable import Nuvio

/// Shuffle, which has one property worth more than all the others: it must not keep offering the
/// same episode. That cannot be read off the code — a draw either repeats or it does not — so it
/// is drawn here against a seeded generator, many times.
final class EpisodeShuffleTests: XCTestCase {
    /// Deterministic, so a failure is reproducible rather than "it happened once in CI".
    private struct SeededGenerator: RandomNumberGenerator {
        private var state: UInt64
        init(seed: UInt64) { state = seed == 0 ? 0x9E3779B97F4A7C15 : seed }
        mutating func next() -> UInt64 {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            return state
        }
    }

    private func episodes(_ count: Int, season: Int = 1) -> [Video] {
        (1...count).map {
            Video(id: "s\(season)e\($0)", name: "Episode \($0)", season: season, episode: $0)
        }
    }

    // MARK: The point of it

    /// Every episode is offered once before any is offered twice. A uniform random draw would
    /// repeat within a handful of picks on a short season, which is what makes shuffle feel broken.
    func testEveryEpisodeIsOfferedBeforeAnyRepeats() {
        var generator = SeededGenerator(seed: 42)
        var history = RandomEpisodePick.History()
        let pool = episodes(8)

        var drawn: [String] = []
        for _ in 0..<8 {
            let pick = RandomEpisodePick.pick(
                from: pool, watched: [], includeWatched: true,
                history: &history, using: &generator
            )
            drawn.append(pick?.id ?? "nil")
        }

        XCTAssertEqual(Set(drawn).count, 8, "a full pass must cover the season exactly once")
    }

    /// And when the pool is exhausted it starts again — without handing back the episode just
    /// shown, which is the one repeat a viewer would actually notice.
    func testTheCycleRestartsWithoutRepeatingTheLastPick() {
        var generator = SeededGenerator(seed: 7)
        var history = RandomEpisodePick.History()
        let pool = episodes(5)

        var drawn: [String] = []
        for _ in 0..<15 {
            guard let pick = RandomEpisodePick.pick(
                from: pool, watched: [], includeWatched: true,
                history: &history, using: &generator
            ) else { return XCTFail("the pool should never run dry when watched are included") }
            drawn.append(pick.id)
        }

        for (index, id) in drawn.enumerated().dropFirst() {
            XCTAssertNotEqual(id, drawn[index - 1], "two identical picks in a row at \(index)")
        }
    }

    // MARK: What the pool is

    func testWatchedEpisodesAreExcludedUnlessAskedFor() {
        var generator = SeededGenerator(seed: 1)
        var history = RandomEpisodePick.History()
        let pool = episodes(3)
        let watched: Set<String> = ["s1e1", "s1e2"]

        for _ in 0..<10 {
            let pick = RandomEpisodePick.pick(
                from: pool, watched: watched, includeWatched: false,
                history: &history, using: &generator
            )
            XCTAssertEqual(pick?.id, "s1e3", "only the unwatched episode may be offered")
        }
    }

    /// Nothing left is a real answer, and it has to be nil rather than a fallback: the viewer's
    /// next move is to include watched episodes, and only an empty answer tells them so.
    func testNothingLeftIsNilRatherThanAFallback() {
        var generator = SeededGenerator(seed: 1)
        var history = RandomEpisodePick.History()
        let pool = episodes(2)

        XCTAssertNil(
            RandomEpisodePick.pick(
                from: pool, watched: ["s1e1", "s1e2"], includeWatched: false,
                history: &history, using: &generator
            )
        )
    }

    /// The episode playing now is never the one offered next.
    func testTheCurrentEpisodeIsNeverOffered() {
        var generator = SeededGenerator(seed: 99)
        var history = RandomEpisodePick.History()
        let pool = episodes(4)

        for _ in 0..<20 {
            let pick = RandomEpisodePick.pick(
                from: pool, watched: [], includeWatched: true, excluding: "s1e2",
                history: &history, using: &generator
            )
            XCTAssertNotEqual(pick?.id, "s1e2")
        }
    }

    /// An addon listing one episode under two ids would otherwise weight it twice.
    func testDuplicatesAreCollapsed() {
        let pool = episodes(2) + [Video(id: "other-id", season: 1, episode: 1)]

        let candidates = RandomEpisodePick.candidates(
            in: pool, watched: [], includeWatched: true
        )

        XCTAssertEqual(candidates.count, 2)
    }

    /// Specials are not what anybody means by "an episode of this show".
    func testSpecialsAndMissingNumbersAreNotCandidates() {
        let pool = [
            Video(id: "special", season: 0, episode: 1),
            Video(id: "no-number", season: 1, episode: nil),
            Video(id: "blank", season: 1, episode: 1),
            Video(id: "", season: 1, episode: 2)
        ]

        let candidates = RandomEpisodePick.candidates(
            in: pool, watched: [], includeWatched: true
        )

        XCTAssertEqual(candidates.map(\.id), ["blank"])
    }
}
