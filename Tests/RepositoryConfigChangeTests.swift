import XCTest
@testable import Nuvio

/// What a phone on the network can and cannot cause on its own.
final class RepositoryConfigChangeTests: XCTestCase {
    private let known = [
        (id: "r1", name: "Community Scrapers", isEnabled: true),
        (id: "r2", name: "Nightly", isEnabled: false)
    ]

    // MARK: Reading a request

    func testAnAddCarriesTheUrl() {
        let change = RepositoryConfigRequest.change(
            from: ["action": "add", "url": "  https://example.com/manifest.json "], known: known
        )
        XCTAssertEqual(change?.kind, .add(url: "https://example.com/manifest.json"))
    }

    func testAnAddWithNoUrlIsNotAChange() {
        XCTAssertNil(RepositoryConfigRequest.change(from: ["action": "add", "url": "  "], known: known))
        XCTAssertNil(RepositoryConfigRequest.change(from: ["action": "add"], known: known))
    }

    /// The id has to name something installed. Anything else is a stale tab or a probe, and
    /// neither should put a prompt on somebody's television.
    func testARemovalOfSomethingUnknownIsNotAChange() {
        XCTAssertNil(RepositoryConfigRequest.change(from: ["action": "remove", "id": "gone"], known: known))
        XCTAssertNil(RepositoryConfigRequest.change(from: ["action": "toggle", "id": ""], known: known))
    }

    func testARemovalNamesWhatItWouldRemove() {
        let change = RepositoryConfigRequest.change(from: ["action": "remove", "id": "r1"], known: known)
        XCTAssertEqual(change?.kind, .remove(id: "r1", name: "Community Scrapers"))
        XCTAssertTrue(change?.prompt.contains("Community Scrapers") ?? false)
    }

    /// A toggle is a request to flip, so the change records the state it is flipping *to* — the
    /// television is the thing that acts, and by then the row may be off screen.
    func testAToggleRecordsTheResultingState() {
        XCTAssertEqual(
            RepositoryConfigRequest.change(from: ["action": "toggle", "id": "r1"], known: known)?.kind,
            .setEnabled(id: "r1", name: "Community Scrapers", enabled: false)
        )
        XCTAssertEqual(
            RepositoryConfigRequest.change(from: ["action": "toggle", "id": "r2"], known: known)?.kind,
            .setEnabled(id: "r2", name: "Nightly", enabled: true)
        )
    }

    func testAnUnknownActionIsNotAChange() {
        XCTAssertNil(RepositoryConfigRequest.change(from: ["action": "install", "url": "x"], known: known))
        XCTAssertNil(RepositoryConfigRequest.change(from: [:], known: known))
    }

    // MARK: What the viewer is asked

    /// Adding is the only case that brings new code onto the device, so it is the only one that
    /// has to say where the request came from *and* what it means.
    func testOnlyTheDestructiveCasesNameTheNetwork() {
        let add = RepositoryConfigChange(kind: .add(url: "https://e.com/m.json"))
        XCTAssertTrue(add.caution?.contains("network") ?? false)
        XCTAssertTrue(add.caution?.contains("trust") ?? false)

        let remove = RepositoryConfigChange(kind: .remove(id: "r1", name: "Community Scrapers"))
        XCTAssertTrue(remove.caution?.contains("network") ?? false)

        let toggle = RepositoryConfigChange(kind: .setEnabled(id: "r1", name: "X", enabled: false))
        XCTAssertNil(toggle.caution, "flipping a switch needs no warning")
    }

    func testEveryPromptNamesTheThingItWouldDo() {
        let changes = [
            RepositoryConfigChange(kind: .add(url: "https://e.com/m.json")),
            RepositoryConfigChange(kind: .remove(id: "r1", name: "Community Scrapers")),
            RepositoryConfigChange(kind: .setEnabled(id: "r1", name: "Community Scrapers", enabled: true))
        ]
        for change in changes {
            XCTAssertFalse(change.prompt.isEmpty)
            XCTAssertTrue(change.prompt.hasSuffix("?"), "\(change.prompt) is not a question")
        }
    }

    func testDecliningSaysSoWhicheverChangeItWas() {
        let changes = [
            RepositoryConfigChange(kind: .add(url: "https://e.com/m.json")),
            RepositoryConfigChange(kind: .remove(id: "r1", name: "X")),
            RepositoryConfigChange(kind: .setEnabled(id: "r1", name: "X", enabled: true))
        ]
        for change in changes {
            XCTAssertTrue(change.settledNotice(approved: false).contains("declined"))
            XCTAssertFalse(change.settledNotice(approved: true).contains("declined"))
        }
    }

    func testEachChangeGetsItsOwnIdentity() {
        let one = RepositoryConfigChange(kind: .add(url: "https://e.com/m.json"))
        let two = RepositoryConfigChange(kind: .add(url: "https://e.com/m.json"))
        XCTAssertNotEqual(one.id, two.id, "two requests for the same URL are two decisions")
        XCTAssertNotEqual(one, two)
    }
}
