import XCTest
@testable import Nuvio

/// Which row of the audio and subtitle panels is drawn as current.
///
/// `PlayerChrome` reads that from `PlayerTrack.isSelected` and from nothing else, so the flag has
/// to be live. On the Aether path it was not: the adapter derived it inside the track-list
/// observer, and the engine publishes its active track as a separate value that moves later. The
/// result was *Off* keeping the checkmark with a subtitle on screen, and audio lists with no
/// checkmark at all. These pin the rule the adapter now applies in one place.
final class PlayerTrackSelectionTests: XCTestCase {
    private func track(_ id: Int64) -> PlayerTrack {
        PlayerTrack(
            id: id,
            title: "Track \(id)",
            language: "eng",
            isSelected: false,
            isExternal: false,
            isDefault: false,
            isForced: false,
            isHearingImpaired: false,
            codec: "eac3",
            channelCount: 6
        )
    }

    func testOneIdentifierMarksExactlyOneTrack() {
        let marked = [track(1), track(2), track(3)].marking(selected: 2)
        XCTAssertEqual(marked.filter(\.isSelected).map(\.id), [2])
    }

    /// The subtitle panel's *Off* row is drawn from the absence of any selection, so a nil
    /// identifier has to leave the list entirely unmarked — that is what makes *Off* correct.
    func testNoSelectionLeavesEveryTrackUnmarked() {
        let marked = [track(1), track(2)].marking(selected: nil)
        XCTAssertTrue(marked.allSatisfy { !$0.isSelected })
    }

    /// External subtitles carry synthetic identifiers well above the stream indices, so an
    /// identifier the list does not hold is an ordinary state rather than a programming error.
    func testAnIdentifierTheListDoesNotHoldMarksNothing() {
        let marked = [track(1), track(2)].marking(selected: 100_000)
        XCTAssertTrue(marked.allSatisfy { !$0.isSelected })
    }

    /// The selection moves on every switch, so the previous one has to be cleared rather than
    /// added to — two checkmarks is the same defect read from the other end.
    func testMarkingReplacesAnEarlierSelection() {
        let marked = [track(1), track(2), track(3)].marking(selected: 1).marking(selected: 3)
        XCTAssertEqual(marked.filter(\.isSelected).map(\.id), [3])
    }

    func testEverythingButTheFlagSurvivesMarking() {
        let before = track(7)
        guard let after = [before].marking(selected: 7).first else { return XCTFail("empty") }
        XCTAssertTrue(after.isSelected)
        XCTAssertEqual(after.id, before.id)
        XCTAssertEqual(after.displayName, before.displayName)
        XCTAssertEqual(after.details, before.details)
    }
}
