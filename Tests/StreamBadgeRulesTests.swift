import XCTest
@testable import Nuvio

/// The shape of an imported pack, and the invariants every mutation has to leave true.
final class StreamBadgeRulesTests: XCTestCase {
    private func filter(_ name: String, _ pattern: String, enabled: Bool = true) -> StreamBadgeFilter {
        StreamBadgeFilter(id: name.lowercased(), name: name, pattern: pattern, isEnabled: enabled)
    }

    private func pack(_ url: String, active: Bool = true, filters: [StreamBadgeFilter]? = nil) -> StreamBadgeImport {
        StreamBadgeImport(
            sourceUrl: url,
            filters: filters ?? [filter("Atmos", "(?i)atmos")],
            isActive: active
        )
    }

    // MARK: Parsing

    func testParsesAPackAndDropsUnusableFilters() throws {
        let json = """
        {"filters": [
          {"id": "a", "name": "Atmos", "pattern": "(?i)atmos", "tagColor": "#3B1E54"},
          {"name": "  ", "pattern": "(?i)dts"},
          {"name": "No pattern", "pattern": ""},
          {"id": "b", "name": "HDR10+", "pattern": "HDR10\\\\+", "isEnabled": false}
        ],
         "groups": [{"id": "audio", "name": "Audio"}]}
        """

        let imported = try StreamBadgeRulesParser.parse(
            sourceUrl: " https://example.com/badges.json ", payload: Data(json.utf8)
        )

        XCTAssertEqual(imported.filters.map(\.name), ["Atmos", "HDR10+"])
        XCTAssertEqual(imported.sourceUrl, "https://example.com/badges.json", "the URL is trimmed")
        XCTAssertEqual(imported.groups.first?.name, "Audio")
        XCTAssertTrue(imported.groups.first?.isExpanded ?? false, "absent means expanded")
        XCTAssertFalse(imported.filters[1].isEnabled)
        XCTAssertEqual(imported.enabledFilterCount, 1)
    }

    /// A file that parses but yields nothing usable is a failed import, not an empty one — an
    /// empty pack would sit in the list looking like it worked.
    func testAPackWithNoUsableFiltersIsRefused() {
        let json = #"{"filters": [{"name": "Nameless pattern"}]}"#
        XCTAssertThrowsError(
            try StreamBadgeRulesParser.parse(sourceUrl: "https://e.com/b.json", payload: Data(json.utf8))
        )
    }

    func testSomethingThatIsNotAPackIsRefused() {
        XCTAssertThrowsError(
            try StreamBadgeRulesParser.parse(sourceUrl: "https://e.com/b.json", payload: Data("<html>".utf8))
        )
    }

    // MARK: Normalisation

    func testExactlyOneImportIsActive() {
        let rules = StreamBadgeRules(imports: [
            pack("https://a.json", active: false),
            pack("https://b.json", active: false)
        ]).normalized()

        XCTAssertEqual(rules.imports.count(where: \.isActive), 1)
        XCTAssertEqual(rules.activeImport?.sourceUrl, "https://a.json", "the first stands in")
    }

    func testTwoActiveImportsAreCollapsedToTheFirst() {
        let rules = StreamBadgeRules(imports: [
            pack("https://a.json", active: false),
            pack("https://b.json", active: true),
            pack("https://c.json", active: true)
        ]).normalized()

        XCTAssertEqual(rules.imports.count(where: \.isActive), 1)
        XCTAssertEqual(rules.activeImport?.sourceUrl, "https://b.json")
    }

    func testTheImportLimitHolds() {
        let rules = StreamBadgeRules(
            imports: (1...6).map { pack("https://\($0).json", active: false) }
        ).normalized()

        XCTAssertEqual(rules.imports.count, StreamBadgeRuleLimits.importLimit)
    }

    func testEmptyAndUnnamedImportsAreDropped() {
        let rules = StreamBadgeRules(imports: [
            pack("   ", active: false),
            StreamBadgeImport(sourceUrl: "https://empty.json", filters: []),
            pack("https://good.json")
        ]).normalized()

        XCTAssertEqual(rules.imports.map(\.sourceUrl), ["https://good.json"])
    }

    // MARK: Mutations

    /// Re-importing a URL is how a pack is updated. Stacking copies would fill the three slots
    /// with the same pack.
    func testReimportingReplacesInPlace() {
        let first = StreamBadgeRules().upserting(pack("https://a.json"))
        let updated = first.upserting(
            pack("https://A.json", filters: [filter("Atmos", "(?i)atmos"), filter("DTS", "(?i)dts")])
        )

        XCTAssertEqual(updated.imports.count, 1, "case-insensitively the same URL")
        XCTAssertEqual(updated.imports.first?.filters.count, 2)
    }

    func testImportingActivatesUnlessToldOtherwise() {
        let rules = StreamBadgeRules()
            .upserting(pack("https://a.json"))
            .upserting(pack("https://b.json"))
        XCTAssertEqual(rules.activeImport?.sourceUrl, "https://b.json")

        let quiet = rules.upserting(pack("https://c.json"), activate: false)
        XCTAssertEqual(quiet.activeImport?.sourceUrl, "https://b.json", "the selection is untouched")
        XCTAssertEqual(quiet.imports.count, 3)
    }

    func testActivatingAnUnknownUrlChangesNothing() {
        let rules = StreamBadgeRules().upserting(pack("https://a.json"))
        XCTAssertEqual(rules.settingActive("https://nowhere.json").activeImport?.sourceUrl, "https://a.json")
    }

    /// Removing the applied pack has to leave another one applied, or badges stop appearing with
    /// packs still in the list.
    func testRemovingTheActivePackPromotesAnother() {
        let rules = StreamBadgeRules()
            .upserting(pack("https://a.json"))
            .upserting(pack("https://b.json"))
        XCTAssertEqual(rules.activeImport?.sourceUrl, "https://b.json")

        let after = rules.removing("https://b.json")
        XCTAssertEqual(after.imports.count, 1)
        XCTAssertEqual(after.activeImport?.sourceUrl, "https://a.json")
        XCTAssertTrue(after.imports[0].isActive)
    }

    func testDisablingAFilterOnlyTouchesTheActivePack() {
        let rules = StreamBadgeRules(imports: [
            pack("https://a.json", active: true, filters: [filter("Atmos", "(?i)atmos")]),
            pack("https://b.json", active: false, filters: [filter("Atmos", "(?i)atmos")])
        ]).normalized().settingFilter(id: "atmos", enabled: false)

        XCTAssertFalse(rules.imports[0].filters[0].isEnabled)
        XCTAssertTrue(rules.imports[1].filters[0].isEnabled)
        XCTAssertEqual(rules.enabledFilterCount, 0)
    }
}

/// What a rule actually matches against.
final class StreamBadgeMatcherTests: XCTestCase {
    private func stream(
        name: String? = nil, title: String? = nil,
        description: String? = nil, filename: String? = nil,
        addon: String = "Torrentio"
    ) -> Nuvio.Stream {
        var stream = Nuvio.Stream(name: name, title: title, description: description, addonName: addon)
        if let filename {
            stream.behaviorHints = StreamBehaviorHints(filename: filename)
        }
        return stream
    }

    private func rules(_ filters: [StreamBadgeFilter]) -> StreamBadgeRules {
        StreamBadgeRules(imports: [
            StreamBadgeImport(sourceUrl: "https://a.json", filters: filters, isActive: true)
        ])
    }

    private func matched(_ stream: Nuvio.Stream, _ filters: [StreamBadgeFilter]) -> [String] {
        StreamBadgeMatcher.badges(
            for: stream,
            attributes: StreamAttributeParser.parse(stream),
            filters: StreamBadgeMatcher.compile(rules(filters))
        ).map(\.name)
    }

    func testMatchesAgainstTheFilename() {
        let stream = stream(filename: "Dune.2024.2160p.UHD.BluRay.REMUX.TrueHD.Atmos.7.1.mkv")
        XCTAssertEqual(
            matched(stream, [StreamBadgeFilter(name: "Atmos", pattern: "(?i)atmos")]),
            ["Atmos"]
        )
    }

    func testMatchesAgainstTheTitleAndDescription() {
        XCTAssertEqual(
            matched(stream(title: "Dune Part Two 2160p"), [StreamBadgeFilter(name: "4K", pattern: "2160p")]),
            ["4K"]
        )
        XCTAssertEqual(
            matched(stream(description: "👤 42 💾 60 GB"), [StreamBadgeFilter(name: "Big", pattern: "GB")]),
            ["Big"]
        )
    }

    /// The reason every candidate is also joined: pack authors write one expression spanning two
    /// facts, and addons scatter those facts across separate fields.
    func testAPatternCanSpanTwoFields() {
        let stream = stream(name: "Torrentio 4k", title: "Dune 2160p", description: "TrueHD Atmos")
        XCTAssertEqual(
            matched(stream, [StreamBadgeFilter(name: "4K Atmos", pattern: "(?i)2160p.*atmos")]),
            ["4K Atmos"]
        )
    }

    func testADisabledFilterNeverMatches() {
        XCTAssertTrue(
            matched(
                stream(title: "Dune 2160p"),
                [StreamBadgeFilter(name: "4K", pattern: "2160p", isEnabled: false)]
            ).isEmpty
        )
    }

    func testOnlyTheActivePackIsApplied() {
        let both = StreamBadgeRules(imports: [
            StreamBadgeImport(
                sourceUrl: "https://a.json",
                filters: [StreamBadgeFilter(name: "Applied", pattern: "2160p")], isActive: true
            ),
            StreamBadgeImport(
                sourceUrl: "https://b.json",
                filters: [StreamBadgeFilter(name: "Idle", pattern: "2160p")], isActive: false
            )
        ])

        let names = StreamBadgeMatcher.badges(
            for: stream(title: "Dune 2160p"), attributes: nil,
            filters: StreamBadgeMatcher.compile(both)
        ).map(\.name)
        XCTAssertEqual(names, ["Applied"])
    }

    /// One bad expression in an imported pack must cost that expression and nothing else.
    func testAnUncompilableExpressionIsDroppedNotFatal() {
        let names = matched(stream(title: "Dune 2160p"), [
            StreamBadgeFilter(name: "Broken", pattern: "([unclosed"),
            StreamBadgeFilter(name: "4K", pattern: "2160p")
        ])
        XCTAssertEqual(names, ["4K"])
    }

    /// Two rules pointing at the same logo are one badge wearing two names.
    func testBadgesAreDedupedByLogo() {
        let logo = "https://cdn.example.com/atmos.png"
        let badges = StreamBadgeMatcher.badges(
            for: stream(title: "TrueHD Atmos 2160p"), attributes: nil,
            filters: StreamBadgeMatcher.compile(rules([
                StreamBadgeFilter(name: "Atmos", pattern: "(?i)atmos", imageURL: logo),
                StreamBadgeFilter(name: "Dolby Atmos", pattern: "(?i)truehd", imageURL: logo)
            ]))
        )
        XCTAssertEqual(badges.count, 1)
        XCTAssertEqual(badges.first?.name, "Atmos", "the first rule names it")
    }

    func testBadgesWithoutLogosAreDedupedByName() {
        let badges = StreamBadgeMatcher.badges(
            for: stream(title: "TrueHD Atmos"), attributes: nil,
            filters: StreamBadgeMatcher.compile(rules([
                StreamBadgeFilter(name: "Atmos", pattern: "(?i)atmos"),
                StreamBadgeFilter(name: "Atmos", pattern: "(?i)truehd")
            ]))
        )
        XCTAssertEqual(badges.count, 1)
    }

    func testNoPacksMeansNoWork() {
        XCTAssertTrue(StreamBadgeMatcher.compile(StreamBadgeRules()).isEmpty)
    }

    // MARK: The literal pre-screen

    /// The hint is an optimisation, so the only thing that must never happen is a hint that
    /// rejects a candidate the expression would have matched.
    func testTheHintNeverRejectsARealMatch() {
        let cases: [(pattern: String, text: String)] = [
            ("(?i)atmos", "TrueHD ATMOS 7.1"),
            (#"(?i)\bDV\b"#, "Dune 2160p DV HDR"),
            ("(?i)remux|bluray", "Dune BluRay"),
            ("2160p", "Dune 2160p"),
            ("(?:HDR10)", "HDR10+ pass")
        ]
        for (pattern, text) in cases {
            let hint = StreamBadgeMatcher.literalHint(for: pattern)
            if let hint {
                XCTAssertNotNil(
                    text.range(of: hint, options: .caseInsensitive),
                    "hint \(hint) rejects \(text), which \(pattern) matches"
                )
            }
        }
    }

    func testAnAlternationYieldsNoHint() {
        XCTAssertNil(StreamBadgeMatcher.literalHint(for: "(?i)remux|bluray"))
    }

    func testAPlainPatternIsItsOwnHint() {
        XCTAssertEqual(StreamBadgeMatcher.literalHint(for: "2160p"), "2160p")
        XCTAssertEqual(StreamBadgeMatcher.literalHint(for: #"(?i)\batmos\b"#), "atmos")
    }

    func testAPatternOfPureMetacharactersYieldsNoHint() {
        XCTAssertNil(StreamBadgeMatcher.literalHint(for: #"\d{4}"#))
    }

    // MARK: Candidates

    func testCandidatesCarryEveryFieldOnce() {
        let stream = stream(name: "Torrentio", title: "Torrentio", description: "Dune", addon: "Torrentio")
        let candidates = StreamBadgeMatcher.candidates(for: stream, attributes: nil)

        XCTAssertEqual(candidates.filter { $0 == "Torrentio" }.count, 1, "duplicates collapse")
        XCTAssertTrue(candidates.contains("Dune"))
    }

    func testASingleCandidateIsNotJoinedWithItself() {
        var bare = Nuvio.Stream(addonName: "Torrentio")
        bare.name = nil
        XCTAssertEqual(StreamBadgeMatcher.candidates(for: bare, attributes: nil), ["Torrentio"])
    }
}
