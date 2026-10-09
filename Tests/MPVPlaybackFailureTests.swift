import XCTest
@testable import Nuvio

/// What a viewer is told when libmpv gives up.
///
/// We showed `mpv_error_string` directly, so someone's television read **"unrecognized file
/// format"** — accurate, untranslated, and silent on the only question that matters: try another
/// source, try the other engine, or stop. The classification exists to answer that and nothing
/// else, which is why there are three outcomes for a dozen error codes.
final class MPVPlaybackFailureTests: XCTestCase {
    // MARK: Nothing playable arrived

    /// The common case behind a dead debrid link: the request succeeded and returned an error
    /// page, so mpv has bytes and they are not a film.
    func testAnUnrecognisedFormatIsInvalidContent() {
        XCTAssertEqual(
            MPVPlaybackFailure.kind(fileError: "unrecognized file format", logLine: nil),
            .invalidContent
        )
    }

    func testAFileThatPlayedNothingIsInvalidContent() {
        XCTAssertEqual(
            MPVPlaybackFailure.kind(fileError: "no audio or video data played", logLine: nil),
            .invalidContent
        )
    }

    /// mpv's error code flattens detail the log keeps, so the log is read too.
    func testTheLogCanIdentifyInvalidContentOnItsOwn() {
        XCTAssertEqual(
            MPVPlaybackFailure.kind(
                fileError: "loading failed",
                logLine: "[demux] Unrecognized file format."
            ),
            .invalidContent
        )
    }

    // MARK: A real file this build cannot decode

    func testAFailedOutputIsAFormatProblem() {
        XCTAssertEqual(
            MPVPlaybackFailure.kind(fileError: "video output initialization failed", logLine: nil),
            .unsupportedFormat
        )
        XCTAssertEqual(
            MPVPlaybackFailure.kind(fileError: "audio output initialization failed", logLine: nil),
            .unsupportedFormat
        )
    }

    /// A missing codec shows up in the log and nowhere in the error code — which is exactly why
    /// the log is part of the input rather than decoration under the message.
    func testAMissingCodecIsRecognisedFromTheLog() {
        for line in [
            "[ffmpeg] Could not find codec parameters",
            "[vd] Could not open decoder",
            "[vo/gpu-next] hwdec failed to initialise"
        ] {
            XCTAssertEqual(
                MPVPlaybackFailure.kind(fileError: "loading failed", logLine: line),
                .unsupportedFormat,
                "\(line) should read as a format problem"
            )
        }
    }

    // MARK: It never opened

    func testAPlainLoadingFailureIsAnOpenFailure() {
        XCTAssertEqual(
            MPVPlaybackFailure.kind(fileError: "loading failed", logLine: nil), .openFailed
        )
    }

    func testNoInformationAtAllStillGivesAnAnswer() {
        XCTAssertEqual(MPVPlaybackFailure.kind(fileError: nil, logLine: nil), .openFailed)
    }

    /// Content first: a file that is not a film is not a codec problem, even when the log also
    /// mentions a decoder failing on the rubbish it was handed.
    func testInvalidContentOutranksAFormatComplaintInTheLog() {
        XCTAssertEqual(
            MPVPlaybackFailure.kind(
                fileError: "unrecognized file format",
                logLine: "[vd] Could not open decoder"
            ),
            .invalidContent
        )
    }

    // MARK: What reaches the screen

    /// The raw text is kept, because it is the only thing worth having when someone reports the
    /// failure — and discarding it to look tidy costs more than it saves.
    func testTheTechnicalDetailIsKeptBeneathTheExplanation() {
        let message = MPVPlaybackFailure.message(
            fileError: "unrecognized file format", logLine: nil
        )

        XCTAssertTrue(message.contains("unrecognized file format"))
        XCTAssertTrue(message.hasPrefix(MPVPlaybackFailure.explanation(for: .invalidContent)))
    }

    /// Except when it says nothing the explanation does not. "loading failed" under "that source
    /// could not be opened" is noise that makes the useful cases harder to spot.
    func testARedundantDetailIsNotRepeated() {
        let message = MPVPlaybackFailure.message(fileError: "loading failed", logLine: nil)

        XCTAssertEqual(message, MPVPlaybackFailure.explanation(for: .openFailed))
    }

    func testAnAbsentDetailLeavesJustTheExplanation() {
        XCTAssertEqual(
            MPVPlaybackFailure.message(fileError: nil, logLine: nil),
            MPVPlaybackFailure.explanation(for: .openFailed)
        )
        XCTAssertEqual(
            MPVPlaybackFailure.message(fileError: "   ", logLine: nil),
            MPVPlaybackFailure.explanation(for: .openFailed)
        )
    }

    /// Three kinds, three different things to do. A classification whose outcomes read the same
    /// would be worth nothing over the raw string it replaced.
    func testTheThreeExplanationsAreActuallyDifferent() {
        let all = [
            MPVPlaybackFailure.explanation(for: .invalidContent),
            MPVPlaybackFailure.explanation(for: .unsupportedFormat),
            MPVPlaybackFailure.explanation(for: .openFailed)
        ]

        XCTAssertEqual(Set(all).count, 3)
    }
}
