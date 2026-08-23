import XCTest
@testable import Nuvio

final class PlayerRecoveryPolicyTests: XCTestCase {
    func testStartupUsesFirstFrameTimeout() {
        let state = PlayerRecoveryPolicy.State(
            isLoading: true, hasStartedPlayback: false, isPaused: false,
            panelOpen: false, promptOpen: false, automaticAttempts: 0
        )
        XCTAssertEqual(PlayerRecoveryPolicy.timeout(for: state), PlayerRecoveryPolicy.firstFrameTimeout)
    }

    func testSustainedBufferingUsesStallTimeout() {
        let state = PlayerRecoveryPolicy.State(
            isLoading: true, hasStartedPlayback: true, isPaused: false,
            panelOpen: false, promptOpen: false, automaticAttempts: 0
        )
        XCTAssertEqual(PlayerRecoveryPolicy.timeout(for: state), PlayerRecoveryPolicy.stallTimeout)
    }

    func testRecoveryNeverRunsBehindViewerOwnedUI() {
        for state in [
            PlayerRecoveryPolicy.State(isLoading: true, hasStartedPlayback: false, isPaused: true, panelOpen: false, promptOpen: false, automaticAttempts: 0),
            PlayerRecoveryPolicy.State(isLoading: true, hasStartedPlayback: false, isPaused: false, panelOpen: true, promptOpen: false, automaticAttempts: 0),
            PlayerRecoveryPolicy.State(isLoading: true, hasStartedPlayback: false, isPaused: false, panelOpen: false, promptOpen: true, automaticAttempts: 0)
        ] {
            XCTAssertNil(PlayerRecoveryPolicy.timeout(for: state))
        }
    }

    func testAutomaticRecoveryHasOneAttemptBudget() {
        let state = PlayerRecoveryPolicy.State(
            isLoading: true, hasStartedPlayback: true, isPaused: false,
            panelOpen: false, promptOpen: false, automaticAttempts: 1
        )
        XCTAssertNil(PlayerRecoveryPolicy.timeout(for: state))
    }
}
