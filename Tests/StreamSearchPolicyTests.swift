import XCTest
@testable import Nuvio

final class StreamGroupOrderingTests: XCTestCase {
    private func group(_ name: String, streams: Int = 1) -> AddonStreams {
        AddonStreams(
            addonName: name,
            addonLogo: nil,
            streams: (0..<streams).map { Nuvio.Stream(title: "\(name) \($0)", addonName: name) }
        )
    }

    private func merge(_ names: [String], installed: [String], plugins: [String] = []) -> [String] {
        var groups: [AddonStreams] = []
        for name in names {
            groups = StreamGroupOrdering.merging(
                group(name), into: groups, installedOrder: installed, pluginOrder: plugins
            )
        }
        return groups.map(\.addonName)
    }

    func testAddonsListInInstalledOrderWhateverTheArrivalOrder() {
        XCTAssertEqual(
            merge(["Torrentio", "Comet", "MediaFusion"], installed: ["MediaFusion", "Torrentio", "Comet"]),
            ["MediaFusion", "Torrentio", "Comet"]
        )
    }

    func testPluginSectionsFollowTheAddonsInArrivalOrder() {
        XCTAssertEqual(
            merge(["Zeta plugin", "Comet", "Alpha plugin"], installed: ["Comet"], plugins: ["Zeta plugin", "Alpha plugin"]),
            ["Comet", "Zeta plugin", "Alpha plugin"]
        )
    }

    func testAnAnswerReplacesItsOwnSection() {
        var groups = [group("Comet"), group("Torrentio")]
        groups = StreamGroupOrdering.merging(
            group("Comet", streams: 3), into: groups, installedOrder: ["Comet", "Torrentio"], pluginOrder: []
        )
        XCTAssertEqual(groups.map(\.addonName), ["Comet", "Torrentio"])
        XCTAssertEqual(groups.first?.streams.count, 3)
    }

    func testAnEmptyAnswerPublishesNoSection() {
        let groups = StreamGroupOrdering.merging(
            group("Comet", streams: 0), into: [group("Torrentio")], installedOrder: ["Comet", "Torrentio"], pluginOrder: []
        )
        XCTAssertEqual(groups.map(\.addonName), ["Torrentio"])
    }
}

final class SourceChipsTests: XCTestCase {
    func testEverySourceStartsLoadingOnce() {
        let chips = SourceChips.fetchStart(names: ["Comet", "Torrentio", "Comet"])
        XCTAssertEqual(chips, [
            SourceChip(name: "Comet", status: .loading),
            SourceChip(name: "Torrentio", status: .loading)
        ])
    }

    func testASourceWithStreamsSucceeds() {
        let chips = SourceChips.marking(
            succeeded: ["Torrentio"], in: SourceChips.fetchStart(names: ["Comet", "Torrentio"])
        )
        XCTAssertEqual(chips.map(\.status), [.loading, .success])
    }

    func testWhatIsStillLoadingAtTheEndFailsAndIsThenRemoved() {
        var chips = SourceChips.marking(
            succeeded: ["Torrentio"], in: SourceChips.fetchStart(names: ["Comet", "Torrentio"])
        )
        chips = SourceChips.markingRemainingAsError(chips)
        XCTAssertEqual(chips.map(\.status), [.error, .success])
        XCTAssertEqual(SourceChips.removingErrors(chips).map(\.name), ["Torrentio"])
    }

    func testTheRowListsSectionsOnScreenFirst() {
        let chips = SourceChips.fetchStart(names: ["Comet", "Torrentio", "MediaFusion"])
        XCTAssertEqual(
            SourceChips.displayOrder(available: ["Torrentio"], chips: chips),
            ["Torrentio", "Comet", "MediaFusion"]
        )
    }
}

final class StreamAutoPlayPolicyTests: XCTestCase {
    private let unlimited = StreamAutoPlayPolicy.unlimitedTimeout

    private func step(
        _ moment: StreamAutoPlayPolicy.Moment,
        timeout: Int,
        windowElapsed: Bool,
        hasStreams: Bool = true,
        cacheCheckPending: Bool = false,
        directFlow: Bool = true
    ) -> StreamAutoPlayPolicy.Step {
        StreamAutoPlayPolicy.step(
            at: moment, timeout: timeout, windowElapsed: windowElapsed, hasStreams: hasStreams,
            cacheCheckPending: cacheCheckPending, directFlow: directFlow
        )
    }

    func testInstantSelectsOnTheFirstAnswerAndGivesUpWithoutAMatch() {
        XCTAssertEqual(step(.arrival, timeout: 0, windowElapsed: true), .init(select: true, giveUpIfNoMatch: true))
    }

    func testBoundedOnlyWaitsBeforeTheWindow() {
        XCTAssertEqual(step(.arrival, timeout: 10, windowElapsed: false), .wait)
    }

    func testBoundedSelectsFromWhatArrivedWhenTheWindowEnds() {
        XCTAssertEqual(step(.windowElapsed, timeout: 10, windowElapsed: true), .init(select: true, giveUpIfNoMatch: true))
    }

    func testAWindowEndingOnNothingWaitsForTheFirstAnswer() {
        XCTAssertEqual(step(.windowElapsed, timeout: 10, windowElapsed: true, hasStreams: false), .wait)
    }

    func testUnlimitedSelectsOnEachAnswerButNeverGivesUpEarly() {
        XCTAssertEqual(step(.arrival, timeout: unlimited, windowElapsed: true), .init(select: true, giveUpIfNoMatch: false))
    }

    func testAPendingCacheCheckHoldsTheVerdict() {
        XCTAssertEqual(
            step(.arrival, timeout: 0, windowElapsed: true, cacheCheckPending: true),
            .init(select: true, giveUpIfNoMatch: false)
        )
    }

    func testEverySourceAnsweredTakesALastLookThenGivesUp() {
        XCTAssertEqual(step(.allAnswered, timeout: unlimited, windowElapsed: true), .init(select: true, giveUpIfNoMatch: true))
    }

    func testTheHardLimitEndsAutoPlay() {
        XCTAssertEqual(step(.hardTimeout, timeout: unlimited, windowElapsed: true), .init(select: false, giveUpIfNoMatch: true))
    }

    func testWithoutTheDirectFlowNothingIsGivenUp() {
        XCTAssertEqual(
            step(.allAnswered, timeout: 10, windowElapsed: true, directFlow: false),
            .init(select: true, giveUpIfNoMatch: false)
        )
    }

    func testStoredTimeoutsMoveToTheNearestSliderValue() {
        XCTAssertEqual(StreamAutoPlayPolicy.normalizedTimeout(12), 10)
        XCTAssertEqual(StreamAutoPlayPolicy.normalizedTimeout(13), 15)
        XCTAssertEqual(StreamAutoPlayPolicy.normalizedTimeout(11), unlimited)
        XCTAssertEqual(StreamAutoPlayPolicy.normalizedTimeout(30), 30)
    }

    func testARegexWithoutALetterOrDigitIsNotConfigured() {
        XCTAssertFalse(StreamAutoPlayPolicy.isRegexSelectionConfigured("  "))
        XCTAssertFalse(StreamAutoPlayPolicy.isRegexSelectionConfigured(".*"))
        XCTAssertFalse(StreamAutoPlayPolicy.isRegexSelectionConfigured("(1080p"))
        XCTAssertTrue(StreamAutoPlayPolicy.isRegexSelectionConfigured("1080p.*WEB-DL"))
    }
}
