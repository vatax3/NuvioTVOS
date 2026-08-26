import XCTest
@testable import Nuvio

/// The template language, against Android's grammar.
///
/// The reason it is a port and not a design: a format written in the phone or Android TV app
/// must paste in here and produce the same rows. Every case below is a shape those apps emit.
final class DebridStreamTemplateTests: XCTestCase {
    private let values: [String: DebridTemplateValue] = [
        "stream.title": .text("dune part two"),
        "stream.year": .number(2024),
        "stream.resolution": .text("2160p"),
        "stream.quality": .text("BluRay"),
        "stream.encode": .text("x265"),
        "stream.visualTags": .list(["HDR", "Dolby Vision"]),
        "stream.audioTags": .list(["Atmos", "TrueHD"]),
        "stream.audioChannels": .list(["7.1"]),
        "stream.size": .bytes(64_424_509_440),
        "stream.releaseGroup": .text("FraMeSToR"),
        "service.shortName": .text("RD"),
        "service.cached": .flag(true)
    ]

    private func render(_ template: String) -> String {
        DebridStreamTemplate.render(template, values: values)
    }

    // MARK: Substitution

    func testTextOutsidePlaceholdersSurvives() {
        XCTAssertEqual(render("plain text"), "plain text")
        XCTAssertEqual(render(""), "")
        XCTAssertEqual(render("[{stream.resolution}]"), "[2160p]")
    }

    func testAnUnknownFieldContributesNothing() {
        XCTAssertEqual(render("a{stream.nonsense}b"), "ab")
    }

    /// A viewer typing into the editor passes through half-finished states, and the preview
    /// must not blank out while they are mid-brace.
    func testAnUnbalancedBraceIsShownAsTyped() {
        XCTAssertEqual(render("size: {stream.size"), "size: {stream.size")
    }

    // MARK: Transforms

    func testTransforms() {
        XCTAssertEqual(render("{stream.title::title}"), "Dune Part Two")
        XCTAssertEqual(render("{stream.quality::upper}"), "BLURAY")
        XCTAssertEqual(render("{stream.quality::lower}"), "bluray")
        XCTAssertEqual(render("{stream.size::bytes}"), "60 GB")
        XCTAssertEqual(render("{stream.visualTags::join(' | ')}"), "HDR | Dolby Vision")
        XCTAssertEqual(render("{stream.releaseGroup::replace('FraMeSToR','FRM')}"), "FRM")
    }

    /// A list with no `join` still has to print something legible.
    func testAListWithoutJoinFallsBackToCommas() {
        XCTAssertEqual(render("{stream.audioTags}"), "Atmos, TrueHD")
    }

    func testTransformsChain() {
        XCTAssertEqual(render("{stream.visualTags::join('-')::lower}"), "hdr-dolby vision")
    }

    /// Binary units, matching Android: a 1.5 GB row on the phone must not read 1.6 GB here.
    func testByteFormattingIsBinary() {
        let sizes: [Int64: String] = [
            512: "512 B",
            1024: "1 KB",
            1_572_864: "1.5 MB",
            1_073_741_824: "1 GB",
            1_610_612_736: "1.5 GB"
        ]
        for (bytes, expected) in sizes {
            XCTAssertEqual(
                DebridStreamTemplate.render("{x::bytes}", values: ["x": .bytes(bytes)]),
                expected
            )
        }
    }

    // MARK: Conditions

    func testExistsPicksTheBranch() {
        XCTAssertEqual(render(#"{stream.quality::exists["yes"||"no"]}"#), "yes")
        XCTAssertEqual(render(#"{stream.absent::exists["yes"||"no"]}"#), "no")
    }

    func testEqualityIsCaseInsensitive() {
        XCTAssertEqual(render(#"{stream.resolution::=2160p["4K"||""]}"#), "4K")
        XCTAssertEqual(render(#"{stream.quality::=BLURAY["disc"||""]}"#), "disc")
        XCTAssertEqual(render(#"{stream.resolution::=1080p["FHD"||""]}"#), "")
    }

    /// Against a list, equality means "one of these", which is how `stream.visualTags::=HDR`
    /// is meant to read.
    func testEqualityAgainstAListMeansMembership() {
        XCTAssertEqual(render(#"{stream.visualTags::=HDR["hdr"||""]}"#), "hdr")
        XCTAssertEqual(render(#"{stream.visualTags::=HLG["hlg"||""]}"#), "")
    }

    func testContainsAndComparison() {
        XCTAssertEqual(render(#"{stream.title::~dune["yes"||"no"]}"#), "yes")
        XCTAssertEqual(render(#"{stream.title::~=part["yes"||"no"]}"#), "yes")
        XCTAssertEqual(render(#"{stream.size::>0["big"||"none"]}"#), "big")
        XCTAssertEqual(render(#"{stream.year::>=2024["new"||"old"]}"#), "new")
        XCTAssertEqual(render(#"{stream.year::<2000["old"||"new"]}"#), "new")
    }

    func testBooleanTests() {
        XCTAssertEqual(render(#"{service.cached::istrue["Ready"||"Not Ready"]}"#), "Ready")
        XCTAssertEqual(render(#"{service.cached::isfalse["Not Ready"||"Ready"]}"#), "Ready")
    }

    /// `and` binds tighter than `or`, which is what makes the shipped description template's
    /// separator logic work.
    func testAndBindsTighterThanOr() {
        XCTAssertEqual(
            render(#"{stream.audioTags::exists::and::stream.audioChannels::exists[" | "||""]}"#),
            " | "
        )
        XCTAssertEqual(
            render(#"{stream.absent::exists::and::stream.quality::exists["both"||"not both"]}"#),
            "not both"
        )
        XCTAssertEqual(
            render(#"{stream.absent::exists::or::stream.quality::exists["either"||"neither"]}"#),
            "either"
        )
    }

    /// A branch is a template in its own right, which is the whole reason the defaults can put
    /// a value inside its own condition.
    func testBranchesNest() {
        XCTAssertEqual(
            render(#"{stream.size::>0["{stream.size::bytes} "||""]}"#),
            "60 GB "
        )
    }

    /// The separator characters appear inside the viewer's own arguments, so every scan has to
    /// be quote-aware or the template is cut in half.
    func testSeparatorsInsideQuotesDoNotSplit() {
        XCTAssertEqual(render("{stream.visualTags::join(' || ')}"), "HDR || Dolby Vision")
        XCTAssertEqual(render("{stream.visualTags::join(' :: ')}"), "HDR :: Dolby Vision")
        XCTAssertEqual(render(#"{stream.quality::exists["a[b]"||""]}"#), "a[b]")
    }

    func testEscapesInsideBranches() {
        XCTAssertEqual(render(#"{stream.quality::exists["a\nb"||""]}"#), "a\nb")
        XCTAssertEqual(render(#"{stream.quality::exists["say \"hi\""||""]}"#), "say \"hi\"")
    }

    // MARK: The shipped defaults

    /// The templates a viewer who never opens the editor sees. If these stop rendering, every
    /// debrid row on the television goes blank at once.
    func testTheDefaultNameRenders() {
        XCTAssertEqual(
            DebridStreamTemplate.render(DebridStreamTemplate.defaultName, values: values),
            "4K RD Instant"
        )
    }

    func testTheDefaultDescriptionRenders() {
        let rendered = DebridStreamTemplate.render(DebridStreamTemplate.defaultDescription, values: values)

        XCTAssertTrue(rendered.contains("Dune Part Two (2024)"), rendered)
        XCTAssertTrue(rendered.contains("BluRay HDR | Dolby Vision x265"), rendered)
        XCTAssertTrue(rendered.contains("Atmos | TrueHD | 7.1"), rendered)
        XCTAssertTrue(rendered.contains("60 GB FraMeSToR"), rendered)
        XCTAssertTrue(rendered.contains("Ready (RD)"), rendered)
    }

    /// A stream with almost nothing parsed still has to produce a usable row rather than a
    /// paragraph of stray punctuation.
    func testTheDefaultsDegradeOnABareStream() {
        let bare: [String: DebridTemplateValue] = ["stream.title": .text("Some Release")]

        XCTAssertEqual(
            DebridStreamTemplate.render(DebridStreamTemplate.defaultName, values: bare),
            "Direct Debrid Instant"
        )
        let description = DebridStreamTemplate.render(DebridStreamTemplate.defaultDescription, values: bare)
        XCTAssertTrue(description.hasPrefix("Some Release"), description)
        XCTAssertTrue(description.contains("Not Ready"), description)
    }

    /// A cache check that has not answered yet must not read as "Not Ready".
    func testAnUnknownCacheStateIsAbsentNotFalse() {
        let pending = values.filter { $0.key != "service.cached" }

        XCTAssertEqual(
            DebridStreamTemplate.render(#"{service.cached::exists["known"||"pending"]}"#, values: pending),
            "pending"
        )
    }
}

/// Building the values a template reads from a real stream.
final class DebridStreamFormatterTests: XCTestCase {
    private var stream: Nuvio.Stream {
        var stream = Nuvio.Stream(
            title: "Dune Part Two 2024 2160p BluRay x265 HDR Atmos 7.1-FraMeSToR",
            addonName: "Torrentio"
        )
        stream.behaviorHints = StreamBehaviorHints(videoSize: 1_073_741_824, filename: "dune.mkv")
        return stream
    }

    private func values(service: DebridProvider? = .realDebrid, cached: Bool? = true) -> [String: DebridTemplateValue] {
        DebridStreamFormatter.values(
            stream: stream, attributes: nil, service: service, isCached: cached
        )
    }

    func testTheParserFillsTheFieldsATemplateNames() {
        let values = values()

        XCTAssertEqual(values["stream.resolution"], .text("2160p"))
        XCTAssertEqual(values["stream.size"], .bytes(1_073_741_824))
        XCTAssertEqual(values["addon.name"], .text("Torrentio"))
        XCTAssertEqual(values["service.shortName"], .text("RD"))
        XCTAssertEqual(values["service.cached"], .flag(true))
    }

    /// Addons put the year in the release name; there is nowhere else on a stream for it.
    func testTheYearIsFoundInTheReleaseName() {
        XCTAssertEqual(values()["stream.year"], .number(2024))
    }

    func testAResolutionInTheThousandsIsNotMistakenForAYear() {
        var stream = Nuvio.Stream(title: "Some Show 2160p", addonName: "x")
        stream.behaviorHints = nil
        let values = DebridStreamFormatter.values(
            stream: stream, attributes: nil, service: nil, isCached: nil
        )

        XCTAssertNil(values["stream.year"], "2160 is not a year")
    }

    /// Absent rather than present-and-empty, so `exists` is false and the branch is skipped.
    func testAnUnconnectedServiceLeavesItsFieldsOut() {
        let values = values(service: nil, cached: nil)

        XCTAssertNil(values["service.shortName"])
        XCTAssertNil(values["service.cached"])
    }

    /// A cleared field means "use the shipped template", not "print nothing" — an editor that
    /// can empty a row must not be able to blank every row on the television.
    func testAnEmptyTemplateFallsBackToTheDefault() {
        let cleared = DebridStreamTemplates(name: "", description: "   ")

        XCTAssertEqual(cleared.resolved.name, DebridStreamTemplate.defaultName)
        XCTAssertEqual(cleared.resolved.description, DebridStreamTemplate.defaultDescription)
    }

    func testAViewerTemplateIsKeptExactly() {
        let theirs = DebridStreamTemplates(name: "{stream.resolution}", description: "x")

        XCTAssertEqual(theirs.resolved, theirs)
    }
}

/// The form and request parsing the on-TV editor depends on.
final class LocalConfigServerParsingTests: XCTestCase {
    func testAFormPostIsDecoded() {
        let body = Data("name=4K+%7Bstream.resolution%7D&description=line%0Aline&action=save".utf8)
        let fields = FormDecoder.decode(body)

        XCTAssertEqual(fields["name"], "4K {stream.resolution}")
        XCTAssertEqual(fields["description"], "line\nline")
        XCTAssertEqual(fields["action"], "save")
    }

    /// A viewer can clear a field, and the post then carries an empty value rather than
    /// omitting the key — the two mean different things.
    func testAnEmptyFieldDecodesToEmptyNotMissing() {
        let fields = FormDecoder.decode(Data("name=&action=save".utf8))

        XCTAssertEqual(fields["name"], "")
        XCTAssertNotNil(fields["name"])
    }

    func testAPartialRequestIsNotParsedYet() {
        XCTAssertNil(HTTPRequest(Data("POST / HTTP/1.1\r\nContent-Length: 20\r\n".utf8)))
        XCTAssertNil(
            HTTPRequest(Data("POST / HTTP/1.1\r\nContent-Length: 20\r\n\r\nshort".utf8)),
            "the body has not all arrived"
        )
    }

    func testACompleteRequestIsParsed() throws {
        let raw = "POST / HTTP/1.1\r\nHost: tv\r\nContent-Length: 9\r\n\r\nname=abcd"
        let request = try XCTUnwrap(HTTPRequest(Data(raw.utf8)))

        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.path, "/")
        XCTAssertEqual(FormDecoder.decode(request.body), ["name": "abcd"])
    }

    func testAPageLoadHasNoBody() throws {
        let request = try XCTUnwrap(HTTPRequest(Data("GET / HTTP/1.1\r\nHost: tv\r\n\r\n".utf8)))

        XCTAssertEqual(request.method, "GET")
        XCTAssertTrue(request.body.isEmpty)
    }

    /// The template goes back into the page inside a textarea. Unescaped, a stray closing tag
    /// in what the viewer typed would end the field and drop the rest into the document.
    func testTheTemplateIsEscapedBeforeItGoesBackIntoThePage() {
        let escaped = DebridFormatterPage.escape("</textarea><script>x</script> & \"q\"")

        XCTAssertFalse(escaped.contains("<"))
        XCTAssertFalse(escaped.contains(">"))
        XCTAssertTrue(escaped.contains("&amp;"))
        XCTAssertTrue(escaped.contains("&quot;"))
    }

    func testThePageCarriesBothFieldsAndTheirValues() {
        let html = DebridFormatterPage.html(
            templates: DebridStreamTemplates(name: "NAME-MARKER", description: "DESC-MARKER"),
            preview: DebridStreamFormatter.Rendered(name: "n", description: "d")
        )

        XCTAssertTrue(html.contains("name=\"name\""))
        XCTAssertTrue(html.contains("name=\"description\""))
        XCTAssertTrue(html.contains("NAME-MARKER"))
        XCTAssertTrue(html.contains("DESC-MARKER"))
        XCTAssertTrue(html.contains("method=\"post\""))
    }
}
