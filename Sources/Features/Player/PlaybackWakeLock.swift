import AVFoundation
import OSLog
import UIKit

/// A transport instruction from the host to whichever engine is mounted.
///
/// It carries the state that is wanted rather than meaning "pause", so the same channel can
/// resume — the Still Watching prompt pauses through it, and an audio route change resumes
/// through it. The id makes each instruction distinct, so pausing, resuming and pausing again
/// are three deliveries rather than one that appears not to change.
struct PlaybackTransportRequest: Equatable {
    let id = UUID()
    let paused: Bool
}

/// `AVAudioSession` category and activation changes can block while the system reconfigures
/// audio routes, so they are kept off the main actor: a player start must never stall SwiftUI
/// focus and animation work. The failure string comes back on the main actor for the caller to
/// log, because that is the only thing an audio-route failure can usefully do.
enum PlaybackAudioSession {
    private static let queue = DispatchQueue(label: "com.nuvio.tvos.audio-session")

    static func activateMoviePlayback(onFailure: (@MainActor (String) -> Void)? = nil) {
        queue.async {
            let session = AVAudioSession.sharedInstance()
            do {
                try session.setCategory(.playback, mode: .moviePlayback)
                try session.setActive(true)
            } catch {
                let message = "audio session: \(error.localizedDescription)"
                guard let onFailure else { return }
                Task { @MainActor in onFailure(message) }
            }
        }
    }

    /// Calls back whenever the audio route changes under playback, with the session already
    /// re-activated.
    ///
    /// AirPods connecting or disconnecting mid-film tears the session down, and the player is
    /// left paused with no indication why. On iOS the convention is to stay paused — unplugging
    /// headphones there means "do not play this out loud in public". An Apple TV has no such
    /// case: the audio simply moves back to the television, in the viewer's own living room,
    /// with the film still on screen. So the route change is reported and playback resumes.
    ///
    /// The caller decides whether to act on it. A viewer who paused deliberately must stay
    /// paused, and only the player knows that.
    static func observeRouteChanges(onChange: @escaping @MainActor () -> Void) -> NSObjectProtocol {
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { notification in
            let raw = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            let reason = raw.flatMap(AVAudioSession.RouteChangeReason.init(rawValue:))
            switch reason {
            case .newDeviceAvailable, .oldDeviceUnavailable, .override,
                 .routeConfigurationChange, .categoryChange:
                break
            default:
                // `.unknown`, `.wakeFromSleep` and `.noSuitableRouteForCategory` are not a
                // device change under the viewer's hands; resuming on them would be guessing.
                return
            }
            // The session is deactivated as part of the change, so it has to be taken back
            // before anything can be played through the new route.
            activateMoviePlayback()
            Task { @MainActor in onChange() }
        }
    }

    static func endObserving(_ token: NSObjectProtocol) {
        NotificationCenter.default.removeObserver(token)
    }
}

/// Keeps the Apple TV awake for the whole player session.
///
/// tvOS treats a system video controller as "playing video" and holds sleep off by itself. The
/// MPV surface is a `CAMetalLayer` the system knows nothing about, so Settings → General →
/// Sleep After (15 minutes by default) applies during playback exactly as it would to a menu
/// left on screen: the film keeps running, the television goes to the screen saver.
///
/// Held for the entire presentation rather than only while `isPaused` is false. Toggling on
/// playback status is what one would write first and it does not survive contact with a stream:
/// every buffer stall and every track change passes through a non-playing state, re-arming the
/// idle timer, and the accumulated idle time is what eventually sleeps the device mid-film.
/// The Still Watching prompt is what stops an abandoned session, the same as on Android.
@MainActor
enum PlaybackWakeLock {
    private static var holdCount = 0
    private static var reassertTimer: Timer?
    /// Sleeping mid-film leaves no trace of its own, so the hold says when it is taken and
    /// dropped. `log stream --predicate 'category == "Playback"'` is then the whole story.
    private static let log = Logger(subsystem: "com.nuvio.tvos", category: "Playback")

    /// Nested acquires are reference-counted: an engine hand-off mounts the second player
    /// before the first is torn down, and sleep must not be re-enabled in between.
    static func acquire() {
        holdCount += 1
        apply(disabled: true)
        log.notice("wake lock held (holders: \(holdCount, privacy: .public))")
        PlaybackAudioSession.activateMoviePlayback()
        startReassertTimerIfNeeded()
    }

    static func release() {
        holdCount = max(0, holdCount - 1)
        log.notice("wake lock released (holders: \(holdCount, privacy: .public))")
        guard holdCount == 0 else { return }
        reassertTimer?.invalidate()
        reassertTimer = nil
        apply(disabled: false)
    }

    /// Forces the idle timer back off while a hold is active. Returning from the background,
    /// and anything else that rebuilds the application state, can clear the flag underneath us.
    static func reassert() {
        guard holdCount > 0 else { return }
        apply(disabled: true)
    }

    private static func apply(disabled: Bool) {
        guard UIApplication.shared.isIdleTimerDisabled != disabled else { return }
        UIApplication.shared.isIdleTimerDisabled = disabled
    }

    private static func startReassertTimerIfNeeded() {
        guard reassertTimer == nil else { return }
        // Sleep After is 15 minutes at its shortest, so a minute's cadence re-arms the flag
        // long before any cleared state could accumulate enough idle time to matter.
        let timer = Timer(timeInterval: 60, repeats: true) { _ in
            Task { @MainActor in reassert() }
        }
        RunLoop.main.add(timer, forMode: .common)
        reassertTimer = timer
    }
}
