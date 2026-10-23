import XCTest
@testable import Nuvio

/// The rules behind chapter skipping, ported with upstream's `PlayerChaptersTest`.
///
/// They are mpv's rules, and each one exists because the obvious implementation feels wrong in a
/// specific way: a list of one offers a control that does nothing, and a *previous* that always
/// goes back makes restarting the chapter you are in impossible.
final class PlayerChaptersTests: XCTestCase {
    private func chapters(_ starts: Double...) -> [PlayerChapter] {
        starts.map { PlayerChapter(start: $0, title: nil) }
    }

    func testASingleChapterIsNoChapters() {
        XCTAssertTrue(PlayerChapters.normalize(chapters(0)).isEmpty)
        XCTAssertEqual(PlayerChapters.normalize(chapters(0, 600)).count, 2)
    }

    func testTheListIsSortedAndDeduplicatedByStart() {
        let normalized = PlayerChapters.normalize(chapters(600, 0, 600, 300))
        XCTAssertEqual(normalized.map(\.start), [0, 300, 600])
    }

    func testNegativeStartsAreDropped() {
        XCTAssertEqual(PlayerChapters.normalize(chapters(-5, 0, 300)).map(\.start), [0, 300])
    }

    func testTheCurrentChapterIsTheLastOneStarted() {
        let list = chapters(0, 300, 600)
        XCTAssertEqual(PlayerChapters.index(in: list, at: 0), 0)
        XCTAssertEqual(PlayerChapters.index(in: list, at: 299), 0)
        XCTAssertEqual(PlayerChapters.index(in: list, at: 300), 1)
        XCTAssertEqual(PlayerChapters.index(in: list, at: 10_000), 2)
    }

    /// A file whose first chapter starts after a pre-roll has a position belonging to no chapter.
    func testBeforeTheFirstChapterThereIsNone() {
        XCTAssertNil(PlayerChapters.index(in: chapters(60, 300), at: 10))
        XCTAssertNil(PlayerChapters.previousStart(in: chapters(60, 300), from: 10))
    }

    func testNextIsTheFirstStartAfterThePosition() {
        let list = chapters(0, 300, 600)
        XCTAssertEqual(PlayerChapters.nextStart(in: list, from: 0), 300)
        XCTAssertEqual(PlayerChapters.nextStart(in: list, from: 300), 600)
        XCTAssertNil(PlayerChapters.nextStart(in: list, from: 600))
    }

    /// The rule that makes the control usable: deep into a chapter, *previous* restarts it.
    func testPreviousRestartsTheChapterYouAreInsideOf() {
        let list = chapters(0, 300, 600)
        XCTAssertEqual(PlayerChapters.previousStart(in: list, from: 400), 300)
    }

    /// Just after a boundary it goes back instead, so two chapters are never one press apart.
    func testPreviousJustPastABoundaryGoesBack() {
        let list = chapters(0, 300, 600)
        XCTAssertEqual(PlayerChapters.previousStart(in: list, from: 302), 0)
        XCTAssertEqual(PlayerChapters.previousStart(in: list, from: 303), 0)
        XCTAssertEqual(PlayerChapters.previousStart(in: list, from: 304), 300)
    }

    /// Inside the first chapter there is nowhere back to, so it restarts rather than refusing.
    func testPreviousInTheFirstChapterRestartsIt() {
        XCTAssertEqual(PlayerChapters.previousStart(in: chapters(0, 300), from: 1), 0)
    }

    /// Asserted on the number rather than on the whole string: the tables are localised and the
    /// test host does not always run in English, which is how the first version of this failed.
    func testAnUntitledChapterIsNumbered() {
        for untitled in [nil, "", "  "] as [String?] {
            let name = PlayerChapter(start: 0, title: untitled).displayName(number: 3)
            XCTAssertTrue(name.hasSuffix("3"), "\(String(describing: untitled)) gave \(name)")
            XCTAssertNotEqual(name, untitled ?? "")
        }
    }

    func testATitledChapterKeepsItsTitle() {
        XCTAssertEqual(PlayerChapter(start: 0, title: "Opening").displayName(number: 3), "Opening")
    }
}
