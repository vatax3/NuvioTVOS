import Foundation

/// Whether anything installed could serve a stream for a title, so *Play* can answer before it
/// is pressed rather than after a round trip to an empty list.
///
/// Port of `PlaybackAvailability.kt`. The rule is not new — it is the same gate
/// `AddonStore.addonsProviding` already applies when a stream request goes out, `Addon.handles`,
/// read ahead of time instead of at request time — plus the scrapers, which answer for a *type*
/// rather than for an id. What is new is asking it early enough to draw.
///
/// Two properties matter more than the rule:
///
/// - **`isLoaded` exists so an empty answer is never mistaken for a negative one.** The addon
///   list hydrates from disk and the scrapers from their own store; a button drawn in that gap
///   would call everything unplayable. Nothing is disabled until both have reported.
/// - **The false negative is the expensive mistake.** Greying out a title that would have played
///   is a dead end the viewer cannot press past, while an over-permissive *Play* costs one press
///   and the empty stream list we shipped before this type existed. Every branch fails open.
struct PlaybackAvailability: Equatable {
    var addons: [Addon] = []
    /// Already filtered by the viewer's switches — `PluginStore.enabledScrapers`.
    var scrapers: [InstalledScraper] = []
    /// Both stores have reported. Until then `canStream` says yes to everything.
    var isLoaded = false

    /// `video` is the entry being played when there is one, because an addon may have attached
    /// the links to it directly; see `hasEmbeddedStreams`.
    func canStream(type: String, videoId: String, video: Video? = nil) -> Bool {
        guard isLoaded else { return true }
        if let video, video.id == videoId, video.hasEmbeddedStreams { return true }
        if addons.contains(where: {
            $0.enabled && $0.handles(id: videoId, resource: "stream", type: type)
        }) { return true }
        return scrapers.contains { $0.supports(type: type) }
    }
}
