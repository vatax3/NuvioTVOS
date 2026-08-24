import XCTest
@testable import Nuvio

/// A film left on Pause was keeping the Apple TV awake all night. The lock is held for the whole
/// presentation on purpose — releasing it whenever playback is not running does not survive a
/// stream, since every buffer stall passes through a non-playing state — so the fix is not "let
/// go when paused" but "let go when the pause has lasted longer than any stall would".
final class PlaybackWakeLockPolicyTests: XCTestCase {
    private func state(holders: Int = 1, pausedFor: TimeInterval? = nil)
        -> PlaybackWakeLockPolicy.State {
        .init(holders: holders, pausedFor: pausedFor)
    }

    func testPlayingKeepsTheTelevisionAwake() {
        XCTAssertTrue(PlaybackWakeLockPolicy.keepsAwake(state()))
    }

    func testNothingHeldMeansNothingKeptAwake() {
        XCTAssertFalse(PlaybackWakeLockPolicy.keepsAwake(state(holders: 0)))
    }

    /// The regression this guards. A stall or a track change is seconds long and must not be
    /// mistaken for somebody walking away — re-arming the idle timer on each of those is what
    /// used to sleep the device mid-film.
    func testABriefPauseStillKeepsItAwake() {
        XCTAssertTrue(PlaybackWakeLockPolicy.keepsAwake(state(pausedFor: 1)))
        XCTAssertTrue(PlaybackWakeLockPolicy.keepsAwake(state(pausedFor: 30)))
        XCTAssertTrue(
            PlaybackWakeLockPolicy.keepsAwake(state(pausedFor: PlaybackWakeLockPolicy.pauseGrace - 1))
        )
    }

    func testASustainedPauseLetsItSleep() {
        XCTAssertFalse(
            PlaybackWakeLockPolicy.keepsAwake(state(pausedFor: PlaybackWakeLockPolicy.pauseGrace))
        )
        XCTAssertFalse(PlaybackWakeLockPolicy.keepsAwake(state(pausedFor: 3600)))
    }

    /// A paused player produces no further events, so nothing would re-evaluate the policy on its
    /// own. The pause has to arm a timer at the moment it begins.
    func testAFreshPauseAsksForATimer() {
        XCTAssertTrue(PlaybackWakeLockPolicy.needsGraceTimer(state(pausedFor: 0)))
    }

    func testPlaybackRunningNeedsNoTimer() {
        XCTAssertFalse(PlaybackWakeLockPolicy.needsGraceTimer(state()))
    }

    /// Once the grace has elapsed the timer has done its job; arming another would be a wake-up
    /// with nothing left to decide.
    func testAnAlreadyElapsedPauseNeedsNoFurtherTimer() {
        XCTAssertFalse(
            PlaybackWakeLockPolicy.needsGraceTimer(state(pausedFor: PlaybackWakeLockPolicy.pauseGrace))
        )
    }

    /// Long enough that no stall reaches it, short enough that the television still sleeps in a
    /// reasonable time — the system's own Sleep After starts counting from here.
    func testTheGraceIsLongerThanAnyPlausibleStall() {
        XCTAssertGreaterThanOrEqual(PlaybackWakeLockPolicy.pauseGrace, 60)
        XCTAssertLessThanOrEqual(PlaybackWakeLockPolicy.pauseGrace, 300)
    }
}
