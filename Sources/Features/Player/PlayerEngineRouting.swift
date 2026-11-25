import Foundation

/// Which engine plays this source, and which one gets it next when one refuses.
///
/// Pure and apart from the view for one reason: with three engines the cascade stopped being
/// something to read off a chain of `if`s. The old two-engine version lived as four booleans and
/// four `==` comparisons inside `PlayerView`, where a new case compiled silently and fell into the
/// AVFoundation branch without a word from the compiler. Here it is data, and it is testable.
enum PlayerEngineRouting {
    /// Which engines this build actually has. Both are compile-time facts — the frameworks are
    /// either linked or they are not — but they are passed in rather than read here so the policy
    /// can be exercised for a build the test is not running in.
    struct Availability: Equatable {
        var aether: Bool
        var mpv: Bool

        /// AVFoundation is always there: it is the platform.
        func has(_ engine: InternalPlayerEngine) -> Bool {
            switch engine {
            case .aether: return aether
            case .mpv: return mpv
            case .exoplayer: return true
            }
        }
    }

    /// Everything the decision depends on, in one value.
    struct Context: Equatable {
        /// The viewer's stored default.
        var setting: InternalPlayerEngine
        /// The in-player engine button: a one-session override, not a settings change. The viewer
        /// is fixing this file, not changing their default.
        var sessionOverride: InternalPlayerEngine?
        /// Engines that have already refused *this* source. Ordered by nothing: membership is the
        /// whole question.
        var refused: Set<InternalPlayerEngine> = []
        var availability: Availability
        /// Whether AVFoundation has a demuxer for this source, as far as the filename says. A
        /// debrid link usually carries no extension, so this is a guess and a refusal is the only
        /// reliable signal — which is what `fallback` is for.
        var isPlayableByAVFoundation: Bool = true
        /// A Blu-ray or DVD image. Only AetherEngine opens one over HTTP — it reads the disc's
        /// playlists and titles — so it goes there even when the viewer's default is another.
        var isDiscImage: Bool = false
    }

    /// `.iso` in the path or the addon's filename, as `MPVEngineSupport.requiresMPV` reads them.
    static func isDiscImage(url: String, filename: String?) -> Bool {
        func isISO(_ value: String) -> Bool { value.lowercased().hasSuffix(".iso") }
        if let filename, isISO(filename) { return true }
        return URLComponents(string: url).map { isISO($0.path) } ?? false
    }

    /// The order a source is offered to engines when nothing else decides.
    ///
    /// AetherEngine first: it is the only one of the three that passes a Dolby Atmos bitstream
    /// through from the containers addons actually serve, and it decodes on the platform's own
    /// hardware path. mpv second, for what AetherEngine will not open. AVFoundation last, because
    /// its demuxer set is the narrowest of the three — it is the floor, not a choice.
    static let preferenceOrder: [InternalPlayerEngine] = [.aether, .mpv, .exoplayer]

    /// The engine that should be mounted now.
    static func engine(for context: Context) -> InternalPlayerEngine {
        // An override is the viewer's own press and outranks everything, including a refusal: they
        // may be pressing it precisely to see the failure for themselves.
        if let override = context.sessionOverride, context.availability.has(override) {
            return override
        }

        let candidates = preferenceOrder.filter {
            context.availability.has($0) && !context.refused.contains($0)
        }
        // Every engine refused it. Mount the viewer's own choice so the error names the engine
        // they picked rather than one they never asked for.
        guard !candidates.isEmpty else { return context.setting }

        // A disc image has one engine that can open it.
        if context.isDiscImage, candidates.contains(.aether) {
            return .aether
        }

        // Their setting, when it can take this source.
        if candidates.contains(context.setting),
           context.setting != .exoplayer || context.isPlayableByAVFoundation {
            return context.setting
        }
        // Otherwise the first engine that can. An unplayable file is worse than an unexpected
        // decoder, which is why a setting is overridden here rather than honoured into a refusal.
        return candidates[0]
    }

    /// The engine to hand the source to after `current` failed, or nil when the failure should be
    /// shown to the viewer instead.
    ///
    /// - Parameters:
    ///   - invitesAnotherEngine: whether the failure is one a different engine could plausibly
    ///     play. False for an origin answering 401/403, a rate-limited origin, or a certificate
    ///     the host declined: another engine opens a second connection to be refused again, and on
    ///     a connection-capped debrid account that is the bug rather than the recovery.
    ///   - automaticSwitchEnabled: the viewer's `auto_switch_internal_player_on_error`.
    static func fallback(
        after current: InternalPlayerEngine,
        context: Context,
        invitesAnotherEngine: Bool,
        automaticSwitchEnabled: Bool
    ) -> InternalPlayerEngine? {
        guard invitesAnotherEngine, automaticSwitchEnabled else { return nil }
        // The viewer pressed the engine button themselves. Switching back without a word would
        // read as the button doing nothing, so the failure is named instead.
        guard context.sessionOverride == nil else { return nil }

        var refused = context.refused
        refused.insert(current)
        return preferenceOrder.first { context.availability.has($0) && !refused.contains($0) }
    }
}
