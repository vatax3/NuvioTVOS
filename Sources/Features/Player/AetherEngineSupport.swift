import Foundation

/// Whether this build carries AetherEngine.
///
/// The engine arrives through `PlayerEngineKit`, a local wrapper package whose product is a
/// *dynamic* framework — which is what keeps its FFmpeg references bound to its own `AetherLib*`
/// frameworks rather than to the static mpv FFmpeg linked into this executable. See that package's
/// `Package.swift`; the arrangement is load-bearing and not a packaging preference.
enum AetherEngineSupport {
    static var isAvailable: Bool {
        #if canImport(PlayerEngineKit)
        true
        #else
        false
        #endif
    }
}
