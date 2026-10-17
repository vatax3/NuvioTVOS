import Foundation
import Observation

/// Per-show shuffle settings, and the selection cache that makes a shuffled pick hold still.
///
/// The cache is the part worth explaining. A random episode drawn inside a view body is drawn
/// again on every redraw, so the *Play* button would name a different episode each time the hero
/// re-rendered and press a third one — which is upstream's own "stable shuffle targets" fix.
/// A selection is therefore made once per **visit** and kept until something real changes: the
/// viewer asks for another, the episode stops being a legal offer, or they arrive again.
///
/// Surfaces are kept apart on purpose. Home and the detail screen can be showing the same series
/// at once, and the rail settling on a different episode than the button is confusing rather than
/// random.
@Observable
@MainActor
final class EpisodeShuffleStore {
    enum Surface: String, Hashable, Sendable {
        case detail, home
    }

    private struct SelectionKey: Hashable {
        var surface: Surface
        var contentId: String
        var includesWatched: Bool
    }

    private struct Selection {
        var videoId: String
        var history = RandomEpisodePick.History()
        var visit: Int
    }

    /// `enabled:`/`watched:` per content id, as upstream stores them. Kept out of the purgeable
    /// cache: this is a choice the viewer made, and losing it silently turns shuffle off.
    private let settingsFile = JSONFileStore<[String: EpisodeShuffleSettings]>(
        filename: "episode-shuffle.json", durability: .critical
    )

    private var settings: [String: EpisodeShuffleSettings]
    private var selections: [SelectionKey: Selection] = [:]
    /// Bumped per arrival on a screen, so a fresh visit draws a fresh episode while a redraw does
    /// not. Upstream carries the same counter for the same reason.
    private var visits: [String: Int] = [:]

    init() {
        settings = settingsFile.load() ?? [:]
    }

    // MARK: Settings

    func settings(forContentId contentId: String) -> EpisodeShuffleSettings {
        settings[contentId] ?? EpisodeShuffleSettings()
    }

    /// Whether shuffle is on for this show. `isAvailable` is the global Layout switch — a show
    /// keeps its own setting while the feature is off, so turning it back on restores what the
    /// viewer had rather than clearing it.
    func isShuffling(contentId: String, type: ContentType, isAvailable: Bool) -> Bool {
        isAvailable && type == .series && settings(forContentId: contentId).isEnabled
    }

    func update(_ value: EpisodeShuffleSettings, forContentId contentId: String) {
        guard !contentId.isEmpty else { return }
        if value == EpisodeShuffleSettings() {
            settings.removeValue(forKey: contentId)
        } else {
            settings[contentId] = value
        }
        settingsFile.save(settings)
        // The pool and the stored pick are both settings-dependent, so neither survives a change.
        clearSelections(forContentId: contentId)
    }

    // MARK: Selection

    /// Marks an arrival, so the next `episode(…)` on this content draws afresh.
    func beginVisit(contentId: String) {
        visits[contentId, default: 0] += 1
    }

    /// Throws the current pick away and draws another. The viewer's "not that one".
    func reroll(surface: Surface, contentId: String) {
        for key in selections.keys where key.surface == surface && key.contentId == contentId {
            selections[key]?.videoId = ""
        }
    }

    /// The episode this surface is currently offering for `contentId`, drawing one if it has none.
    ///
    /// - Parameter current: an episode to never offer — the one already playing.
    func episode(
        surface: Surface,
        contentId: String,
        videos: [Video],
        watched: Set<String>,
        includesWatched: Bool,
        excluding current: String? = nil
    ) -> Video? {
        let key = SelectionKey(
            surface: surface, contentId: contentId, includesWatched: includesWatched
        )
        let visit = visits[contentId] ?? 0
        var selection = selections[key] ?? Selection(videoId: "", visit: visit)

        // A pick survives a redraw and a new visit survives nothing: the stored episode is kept
        // only while the visit it was drawn for is still the current one.
        if selection.visit == visit, !selection.videoId.isEmpty,
           let held = RandomEpisodePick.stillValid(
               selection.videoId, in: videos, watched: watched,
               includeWatched: includesWatched, excluding: current
           ) {
            selections[key] = selection
            return held
        }

        selection.visit = visit
        var generator = SystemRandomNumberGenerator()
        let picked = RandomEpisodePick.pick(
            from: videos, watched: watched, includeWatched: includesWatched,
            excluding: current, history: &selection.history, using: &generator
        )
        selection.videoId = picked?.id ?? ""
        selections[key] = selection
        return picked
    }

    private func clearSelections(forContentId contentId: String) {
        for key in selections.keys where key.contentId == contentId {
            selections.removeValue(forKey: key)
        }
    }
}
