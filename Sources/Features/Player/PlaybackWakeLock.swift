import AVFoundation
import OSLog
import UIKit

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
