import XCTest
@testable import Nuvio

/// The tokens are the vocabulary imported badge packs are *written in*, so they are a contract
/// with somebody else's file rather than a presentation choice — pinned against literals for the
/// same reason the watch-party envelopes are.
final class PlaybackBadgeTokensTests: XCTestCase {
    private func tokens(_ info: PlayerStreamInfo, languages: [String] = []) -> [String] {
        playbackBadgeTokens(info, languages: languages)
    }

    func testNothingKnownYieldsNothing() {
        XCTAssertTrue(tokens(PlayerStreamInfo()).isEmpty,
                      "an engine that has not opened a file yet must not badge anything")
    }

    func testFourKResolutionYieldsAllThreeSpellings() {
        let out = tokens(PlayerStreamInfo(videoWidth: 3840, videoHeight: 2160))
        for expected in ["2160p", "4K", "UHD"] {
            XCTAssertTrue(out.contains(expected), "a pack may look for \(expected)")
        }
    }

    func testSubHDResolutionNamesItsOwnHeight() {
        let out = tokens(PlayerStreamInfo(videoWidth: 720, videoHeight: 576))
        XCTAssertTrue(out.contains("576p"))
        XCTAssertTrue(out.contains("SD"))
    }

    func testHEVCYieldsTheFourNamesPacksUse() {
        let out = tokens(PlayerStreamInfo(videoCodec: "hevc"))
        for expected in ["HEVC", "H.265", "H265", "x265"] {
            XCTAssertTrue(out.contains(expected), "a pack may look for \(expected)")
        }
    }

    func testAnUnknownCodecIsPassedThroughRatherThanDropped() {
        XCTAssertTrue(tokens(PlayerStreamInfo(videoCodec: "vp9")).contains("vp9"))
    }

    func testJOCIsAtmosAndAlsoDolbyDigitalPlus() {
        let out = tokens(PlayerStreamInfo(audioCodec: "E-AC-3 (JOC)"))
        for expected in ["DD+", "DDP", "EAC3", "Atmos"] {
            XCTAssertTrue(out.contains(expected), "a pack may look for \(expected)")
        }
    }

    /// Our own adapter writes `"eac3 · Atmos"` into the single `audioCodec` field, where upstream
    /// keeps codec and profile apart. Both shapes have to reach `Atmos`.
    func testOurOwnAtmosSpellingAlsoReachesAtmos() {
        XCTAssertTrue(tokens(PlayerStreamInfo(audioCodec: "eac3 · Atmos")).contains("Atmos"))
    }

    func testDTSHDMasterAudioYieldsTheWholeLadder() {
        let out = tokens(PlayerStreamInfo(audioCodec: "DTS-HD MA"))
        for expected in ["DTS", "DTS-HD", "DTS-HD MA"] {
            XCTAssertTrue(out.contains(expected), "a pack may look for \(expected)")
        }
        XCTAssertFalse(out.contains("DTS:X"), "plain MA is not DTS:X")
    }

    func testPlainAC3IsNotReadAsDolbyDigitalPlus() {
        let out = tokens(PlayerStreamInfo(audioCodec: "AC-3"))
        XCTAssertTrue(out.contains("DD"))
        XCTAssertFalse(out.contains("DD+"), "AC-3 is not E-AC-3")
    }

    func testChannelCountsUseTheSpellingPacksUse() {
        XCTAssertTrue(tokens(PlayerStreamInfo(audioChannelCount: 6)).contains("5.1"))
        XCTAssertTrue(tokens(PlayerStreamInfo(audioChannelCount: 8)).contains("7.1"))
        XCTAssertFalse(tokens(PlayerStreamInfo(audioChannelCount: 7)).contains("7.1"),
                       "an unusual layout has no conventional name and must not be guessed")
    }

    /// The profile 8.1 case, and the reason both range strings are read: the base layer is HDR10
    /// PQ, so the *source* colorimetry never says Dolby Vision — only what the engine reports it
    /// is presenting does.
    func testDolbyVisionIsFoundInTheOutputRangeAlone() {
        let out = tokens(PlayerStreamInfo(
            sourceRange: "BT.2020 · PQ (SMPTE ST 2084)",
            outputRange: "Dolby Vision"
        ))
        for expected in ["DV", "DoVi", "Dolby Vision"] {
            XCTAssertTrue(out.contains(expected), "a pack may look for \(expected)")
        }
    }

    func testPQAloneIsHDR10() {
        let out = tokens(PlayerStreamInfo(sourceRange: "BT.2020 · PQ", outputRange: "BT.2020 · PQ"))
        XCTAssertTrue(out.contains("HDR10"))
        XCTAssertFalse(out.contains("Dolby Vision"))
    }

    func testHLGIsHDRButNotHDR10() {
        let out = tokens(PlayerStreamInfo(sourceRange: "BT.2020 · HLG"))
        XCTAssertTrue(out.contains("HLG"))
        XCTAssertTrue(out.contains("HDR"))
        XCTAssertFalse(out.contains("HDR10"))
    }

    /// `dv` as a substring appears in ordinary words; only the whole name counts.
    func testAnAdvancedProfileIsNotMistakenForDolbyVision() {
        let out = tokens(PlayerStreamInfo(sourceRange: "Advanced BT.709", outputRange: "BT.709"))
        XCTAssertFalse(out.contains("DV"), "\"advanced\" contains \"dv\" and is not Dolby Vision")
    }

    func testAnHDRFileWithNoStatedDepthIsAssumedTenBit() {
        XCTAssertTrue(tokens(PlayerStreamInfo(sourceRange: "BT.2020 · PQ")).contains("10bit"))
    }

    func testAnSDRFileWithNoStatedDepthClaimsNoDepth() {
        let out = tokens(PlayerStreamInfo(videoCodec: "h264", sourceRange: "BT.709 · BT.1886"))
        XCTAssertFalse(out.contains("8bit"))
        XCTAssertFalse(out.contains("10bit"))
    }

    func testAStatedDepthWins() {
        XCTAssertTrue(tokens(PlayerStreamInfo(sourceRange: "BT.2020 · PQ", bitDepth: 12)).contains("12bit"))
    }

    func testTheLanguagesGivenAreCarriedThrough() {
        let out = tokens(PlayerStreamInfo(audioCodec: "AC-3"), languages: ["fre", "French"])
        XCTAssertTrue(out.contains("fre"))
        XCTAssertTrue(out.contains("French"))
    }

    /// A pattern like `2160p.*ATMOS` is written against one release name; here the two facts
    /// arrive as separate tokens, so a joined candidate has to exist for it to match at all.
    func testAJoinedCandidateIsOfferedForPatternsSpanningTwoFacts() {
        let out = tokens(PlayerStreamInfo(
            audioCodec: "E-AC-3 (JOC)", videoWidth: 3840, videoHeight: 2160
        ))
        XCTAssertTrue(out.contains { $0.contains("2160p") && $0.contains("Atmos") },
                      "no single candidate carries both facts, so such a pattern could never match")
    }

    func testNoTokenIsRepeated() {
        let out = tokens(PlayerStreamInfo(
            sourceRange: "BT.2020 · PQ", outputRange: "BT.2020 · PQ"
        ))
        XCTAssertEqual(out.count, Set(out).count, "HDR is derivable from both ranges and must be said once")
    }
}
