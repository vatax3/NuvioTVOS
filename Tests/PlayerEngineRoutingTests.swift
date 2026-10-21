import XCTest
@testable import Nuvio

/// The cascade had no tests at all while it was two engines and four booleans inside the view.
/// These are the cases that decide whether a viewer sees a picture, an error, or a silent
/// hand-off they did not ask for.
final class PlayerEngineRoutingTests: XCTestCase {
    private let all = PlayerEngineRouting.Availability(aether: true, mpv: true)

    private func context(
        setting: InternalPlayerEngine = .aether,
        override: InternalPlayerEngine? = nil,
        refused: Set<InternalPlayerEngine> = [],
        availability: PlayerEngineRouting.Availability? = nil,
        playableByAVFoundation: Bool = true
    ) -> PlayerEngineRouting.Context {
        PlayerEngineRouting.Context(
            setting: setting,
            sessionOverride: override,
            refused: refused,
            availability: availability ?? all,
            isPlayableByAVFoundation: playableByAVFoundation
        )
    }

    // MARK: Which engine plays

    func testTheViewersSettingIsHonoured() {
        for engine in InternalPlayerEngine.allCases {
            XCTAssertEqual(PlayerEngineRouting.engine(for: context(setting: engine)), engine)
        }
    }

    func testTheInPlayerOverrideOutranksTheSetting() {
        let resolved = PlayerEngineRouting.engine(for: context(setting: .aether, override: .mpv))
        XCTAssertEqual(resolved, .mpv)
    }

    /// The viewer may be pressing the button precisely to watch it fail on that engine.
    func testTheOverrideOutranksEvenARefusal() {
        let resolved = PlayerEngineRouting.engine(
            for: context(setting: .aether, override: .mpv, refused: [.mpv])
        )
        XCTAssertEqual(resolved, .mpv)
    }

    func testAnOverrideForAnEngineThisBuildLacksIsIgnored() {
        let resolved = PlayerEngineRouting.engine(
            for: context(setting: .exoplayer, override: .mpv,
                         availability: .init(aether: false, mpv: false))
        )
        XCTAssertEqual(resolved, .exoplayer)
    }

    /// An unplayable file is worse than an unexpected decoder, so a container AVFoundation has no
    /// demuxer for leaves the setting behind rather than being honoured into a refusal.
    func testAContainerAVFoundationCannotOpenLeavesThatSetting() {
        let resolved = PlayerEngineRouting.engine(
            for: context(setting: .exoplayer, playableByAVFoundation: false)
        )
        XCTAssertEqual(resolved, .aether)
    }

    func testThatSameContainerFallsToMPVWithoutAether() {
        let resolved = PlayerEngineRouting.engine(
            for: context(setting: .exoplayer,
                         availability: .init(aether: false, mpv: true),
                         playableByAVFoundation: false)
        )
        XCTAssertEqual(resolved, .mpv)
    }

    func testARefusedEngineIsNotOfferedTheSourceAgain() {
        let resolved = PlayerEngineRouting.engine(for: context(setting: .aether, refused: [.aether]))
        XCTAssertEqual(resolved, .mpv)
    }

    /// With every engine spent, the error has to name the engine the viewer chose — not one they
    /// never asked for and never saw.
    func testWhenEveryEngineHasRefusedTheSettingIsMountedForItsError() {
        let resolved = PlayerEngineRouting.engine(
            for: context(setting: .mpv, refused: [.aether, .mpv, .exoplayer])
        )
        XCTAssertEqual(resolved, .mpv)
    }

    func testAetherIsPreferredWhenTheSettingNamesAnEngineThisBuildLacks() {
        let resolved = PlayerEngineRouting.engine(
            for: context(setting: .mpv, availability: .init(aether: true, mpv: false))
        )
        XCTAssertEqual(resolved, .aether)
    }

    // MARK: Which engine gets it next

    func testTheLadderWalksThePreferenceOrder() {
        XCTAssertEqual(
            PlayerEngineRouting.fallback(after: .aether, context: context(),
                                        invitesAnotherEngine: true, automaticSwitchEnabled: true),
            .mpv
        )
        XCTAssertEqual(
            PlayerEngineRouting.fallback(after: .mpv, context: context(refused: [.aether]),
                                        invitesAnotherEngine: true, automaticSwitchEnabled: true),
            .exoplayer
        )
        XCTAssertNil(
            PlayerEngineRouting.fallback(after: .exoplayer, context: context(refused: [.aether, .mpv]),
                                         invitesAnotherEngine: true, automaticSwitchEnabled: true)
        )
    }

    /// AE#377: a second player meets the same meter, and on a connection-capped debrid account
    /// spending another connection to be refused again is the bug rather than the recovery.
    func testARefusalNoEngineWouldSurviveIsNotHandedOn() {
        XCTAssertNil(
            PlayerEngineRouting.fallback(after: .aether, context: context(),
                                         invitesAnotherEngine: false, automaticSwitchEnabled: true)
        )
    }

    func testTheViewersOwnEnginePressIsNeverSilentlyUndone() {
        XCTAssertNil(
            PlayerEngineRouting.fallback(after: .aether, context: context(override: .aether),
                                         invitesAnotherEngine: true, automaticSwitchEnabled: true)
        )
    }

    func testTheAutomaticSwitchSettingIsObeyed() {
        XCTAssertNil(
            PlayerEngineRouting.fallback(after: .aether, context: context(),
                                         invitesAnotherEngine: true, automaticSwitchEnabled: false)
        )
    }

    func testAnEngineThisBuildLacksIsSkippedInTheLadder() {
        XCTAssertEqual(
            PlayerEngineRouting.fallback(
                after: .aether,
                context: context(availability: .init(aether: true, mpv: false)),
                invitesAnotherEngine: true, automaticSwitchEnabled: true
            ),
            .exoplayer
        )
    }

    // MARK: The order itself

    /// Aether first because it is the only one of the three that passes an Atmos bitstream through
    /// from the containers addons serve; AVFoundation last because its demuxer set is the floor.
    func testThePreferenceOrderIsAetherThenMPVThenAVFoundation() {
        XCTAssertEqual(PlayerEngineRouting.preferenceOrder, [.aether, .mpv, .exoplayer])
    }

    func testEveryEngineIsReachableFromTheOrder() {
        XCTAssertEqual(Set(PlayerEngineRouting.preferenceOrder), Set(InternalPlayerEngine.allCases))
    }
}
