import XCTest
@testable import Nuvio

/// Upstream's `DebridFileSelectorParityTest` (1.2.0-beta.4), against `DebridFileSelection`.
/// Their tests assert a provider file id; these assert the index of that file.
final class DebridFileSelectionTests: XCTestCase {
    private func select(
        _ files: [(path: String, size: Int64)],
        playable: ((Int) -> Bool)? = nil,
        fileIndex: Int? = nil,
        filename: String? = nil,
        season: Int? = nil,
        episode: Int? = nil
    ) -> Int? {
        DebridFileSelection.select(
            paths: files.map(\.path),
            sizes: files.map(\.size),
            isPlayable: playable ?? { DebridFileSelection.hasVideoExtension(files[$0].path) },
            fileIndex: fileIndex,
            filenames: [filename],
            season: season,
            episode: episode
        )
    }

    func testFilenameMatchWinsBeforeTheFileIndex() {
        let files: [(path: String, size: Int64)] = [
            ("Request High Bitrate Stuff in Here.txt", 1),
            ("The Office US S01-S09/The.Office.US.S01E01.Pilot.1080p.BluRay.Remux.mkv", 5_303_936_915),
            ("The Office US S01-S09/The.Office.US.S08E13.Jury.Duty.1080p.BluRay.Remux.mkv", 5_859_312_140),
        ]
        XCTAssertEqual(
            select(files, fileIndex: 2, filename: "The.Office.US.S01E01.Pilot.1080p.BluRay.Remux.mkv", season: 1, episode: 1),
            1
        )
    }

    func testAnAmpersandHintMatchesAndInTheProviderFilename() {
        let files: [(path: String, size: Int64)] = [
            ("Madhurame Jeevitham (2026) 1080p - (DD+5.1 - 640Kbps and AAC 2.0) - ESub.mkv", 2_044_866_613),
        ]
        XCTAssertEqual(
            select(files, fileIndex: 0, filename: "Madhurame Jeevitham (2026) 1080p - (DD+5.1 - 640Kbps & AAC 2.0) - ESub.mkv"),
            0
        )
    }

    func testAnAndHintMatchesAnAmpersandInTheProviderFilename() {
        XCTAssertEqual(select([("Movie & Friends.mkv", 100)], filename: "Movie and Friends.mkv"), 0)
    }

    func testTheExactAmpersandFilenameWinsBeforeItsEquivalent() {
        XCTAssertEqual(select([("Movie & Friends.mkv", 100), ("Movie and Friends.mkv", 200)], filename: "Movie & Friends.mkv"), 0)
    }

    func testAmbiguousEquivalentFilenamesPickNothing() {
        let files: [(path: String, size: Int64)] = [
            ("Folder One/Movie and Friends.mkv", 100),
            ("Folder Two/Movie and Friends.mkv", 200),
        ]
        XCTAssertNil(select(files, filename: "Movie & Friends.mkv"))
    }

    func testTheFileIndexIsAnIndexIntoTheSourceList() {
        let files: [(path: String, size: Int64)] = [
            ("Request High Bitrate Stuff in Here.txt", 1),
            ("Show.S01E01.mkv", 500),
            ("Show.S08E13.mkv", 900),
        ]
        XCTAssertEqual(select(files, fileIndex: 1), 1)
    }

    func testTheEpisodePatternWinsBeforeTheLargestFile() {
        let files: [(path: String, size: Int64)] = [
            ("The.Office.US.S08E13.Jury.Duty.mkv", 900),
            ("The.Office.US.S01E01.Pilot.mkv", 500),
        ]
        XCTAssertEqual(select(files, season: 1, episode: 1), 1)
        XCTAssertEqual(select([("/Show.S01E01.mkv", 1_000), ("/Show.S01E02.mkv", 2_000)], season: 1, episode: 1), 0)
    }

    func testAHintNothingAnswersPicksNothingRatherThanTheLargestFile() {
        XCTAssertNil(select([("Show.S01E01.mkv", 1_000), ("Show.S01E02.mkv", 2_000)], season: 1, episode: 3))
    }

    func testWithoutHintsTheLargestVideoIsPlayed() {
        XCTAssertEqual(select([("sample.mkv", 10), ("movie.mkv", 1_000), ("extras.iso", 9_000)]), 1)
    }

    func testPremiumizeNeedsALinkForTheRequestedFile() {
        let files: [(path: String, size: Int64)] = [("Show.S01E01.mkv", 0), ("Show.S01E02.mkv", 0)]
        let links: [String?] = ["https://example.com/1", nil]
        XCTAssertNil(select(files, playable: { links[$0] != nil }, fileIndex: 0, filename: "Show.S01E02.mkv", season: 1, episode: 2))
    }
}
