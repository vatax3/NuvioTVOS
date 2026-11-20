import Foundation

/// What an auto-selected playback carries so that, when its source fails, the next matching one
/// can be tried — upstream's `PlayerRuntimeControllerSourceFallback` (1.2.0-beta.1).
///
/// Carried on the request because a source switch replaces the request: the count and the
/// sources already tried have to survive it, or a failing chain would start over at every step.
struct SourceFallbackState: Hashable {
    /// Further sources tried so far, after the one auto-play picked.
    var attempts = 0
    /// `SourceFallback.key` of every source tried, and `url:` of every link opened.
    var triedKeys: Set<String> = []
    /// Opened from the reuse-last-link cache, which is cleared when the chain fails.
    var fromLinkCache = false
    /// The playing source's torrent, so other copies of it from the same addon are skipped.
    var currentInfoHash: String?
}

enum SourceFallback {
    /// How long the next candidate is waited for while the search runs: 30 checks, 0.5 s apart.
    static let pollCount = 30
    static let pollInterval: Duration = .milliseconds(500)

    static let maxSourcesRange = 1...10
    static let defaultMaxSources = 3
    static let startupTimeoutRange = 5...45
    static let startupTimeoutStep = 5
    static let defaultStartupTimeoutSeconds = 15

    /// `streamAutoPlayFallbackActive`: only while auto source selection picks the stream, and
    /// never alongside the engine switch on error, since both react to the same failure.
    static func isActive(enabled: Bool, mode: StreamAutoPlayMode, engineSwitchOnError: Bool) -> Bool {
        enabled && mode != .off && !engineSwitchOnError
    }

    /// `sourceFallbackKey`: one source across its fresh, prepared and resolved copies.
    static func key(for stream: Stream) -> String {
        if let hash = stream.effectiveInfoHash?.lowercased() {
            return "torrent:\(stream.addonName):\(hash):\(stream.fileIdx ?? -1)"
        }
        if let url = stream.streamURL() { return urlKey(url) }
        return "meta:\(stream.addonName):\(stream.name ?? ""):\(stream.description ?? "")"
    }

    static func urlKey(_ url: String) -> String { "url:\(url)" }

    /// `nextSourceFallbackCandidate`: what auto-play would pick among the sources not yet tried,
    /// leaving out other copies of the torrent that failed from the same addon.
    static func nextCandidate(
        from streams: [Stream],
        triedKeys: Set<String>,
        failedAddonName: String?,
        failedInfoHash: String?,
        select: ([Stream]) -> Stream?
    ) -> Stream? {
        let untried = streams.filter { stream in
            if triedKeys.contains(key(for: stream)) { return false }
            if let failedInfoHash, stream.addonName == failedAddonName,
               stream.effectiveInfoHash?.caseInsensitiveCompare(failedInfoHash) == .orderedSame {
                return false
            }
            return true
        }
        return select(untried)
    }

    /// Upstream's `resolveWithSourceFallback` (d020e4af7): resolves `first` and, while a stream
    /// cannot be resolved, the one `next` picks among those not tried, up to `maxSources` further
    /// ones. Before it, a debrid result that failed to resolve on the source screen — an expired
    /// one, say — ended auto-play there, since the player's own fallback only starts once a
    /// stream is playing.
    ///
    /// Returns the stream that resolved and its link, or `nil`, with every key tried and the count
    /// of further streams, which the player takes over so its fallback goes on from them.
    static func resolve<Link>(
        first: Stream,
        maxSources: Int,
        resolve: (Stream) async -> Link?,
        next: (_ failed: Stream, _ triedKeys: Set<String>) -> Stream?
    ) async -> (resolved: (stream: Stream, link: Link)?, triedKeys: Set<String>, attempts: Int) {
        var triedKeys = Set<String>()
        var attempts = 0
        var candidate = first
        while true {
            let link = await resolve(candidate)
            triedKeys.insert(key(for: candidate))
            if let link { return ((candidate, link), triedKeys, attempts) }
            guard attempts < maxSources, let following = next(candidate, triedKeys) else {
                return (nil, triedKeys, attempts)
            }
            attempts += 1
            candidate = following
        }
    }
}

extension PlaybackRequest {
    /// The same playback from another source: the stream's own fields replaced, everything about
    /// the title and the session kept. What a fallback or a refreshed link switches to in place.
    func replacingSource(with stream: Stream, url: String) -> PlaybackRequest {
        var playback = self
        playback.streamURL = url
        playback.streamName = stream.displayName
        playback.filename = stream.behaviorHints?.filename?.nilIfBlank ?? NextEpisodeSourceMatch.filenameFromURL(url)
        playback.headers = stream.behaviorHints?.proxyHeaders?.request ?? [:]
        playback.sourceAddonName = stream.addonName
        playback.sourceAddonLogo = stream.addonLogo
        playback.sourceDescription = stream.displayDescription
        playback.sourceHints = stream.sources ?? []
        playback.sourceStableKey = stream.stableKey
        playback.sourceBingeGroup = stream.behaviorHints?.bingeGroup
        return playback
    }
}
