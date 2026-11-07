import Foundation

/// The audio and subtitle a viewer picked for one title, restored on its next episode.
///
/// Port of upstream's `TrackPreferenceDataStore` and the restore in `applyPersistedTrackPreference`,
/// which the Android app has had since before 0.8.9 and this port never had. Upstream syncs it in
/// the profile settings blob (feature `track_preference`), so it is stored under their exact keys
/// and values — a subtitle chosen on the Android app is the one this app restores, and back.
struct TrackMemory: Equatable, Sendable {
    struct Track: Equatable, Sendable {
        var language: String?
        var name: String?
        var trackId: String?
        var isForced: Bool?
    }

    enum Subtitle: Equatable, Sendable {
        /// A track the file carries.
        case embedded(Track)
        /// A subtitle from an addon, by the addon's own id.
        case addon(id: String, url: String, language: String, addonName: String)
        case disabled
    }

    var audio: Track?
    var subtitle: Subtitle?

    var isEmpty: Bool { audio == nil && subtitle == nil }

    // MARK: Upstream's fields

    /// Upstream's field names, joined to the content id as `"<field>|<contentId>"`.
    static let fields = [
        "sub_type", "sub_lang", "sub_name", "sub_track_id", "sub_is_forced", "sub_addon_id",
        "sub_addon_url", "sub_addon_name", "audio_lang", "audio_name", "audio_track_id"
    ]

    static func key(_ field: String, contentId: String) -> String { "\(field)|\(contentId)" }

    /// Every field, nil where upstream's `save` removes the key.
    var storedFields: [String: String?] {
        var out: [String: String?] = Dictionary(uniqueKeysWithValues: Self.fields.map { ($0, nil) })
        switch subtitle {
        case .embedded(let track):
            out["sub_type"] = "INTERNAL"
            out["sub_lang"] = track.language
            out["sub_name"] = track.name
            out["sub_track_id"] = track.trackId
            out["sub_is_forced"] = track.isForced.map { $0 ? "true" : "false" }
        case .addon(let id, let url, let language, let addonName):
            out["sub_type"] = "ADDON"
            out["sub_lang"] = language
            out["sub_addon_id"] = id
            out["sub_addon_url"] = url
            out["sub_addon_name"] = addonName
        case .disabled:
            out["sub_type"] = "DISABLED"
        case nil:
            break
        }
        out["audio_lang"] = audio?.language
        out["audio_name"] = audio?.name
        out["audio_track_id"] = audio?.trackId
        return out
    }

    /// Upstream's `load` + `toTrackPreference`: nil when nothing was remembered.
    init?(fields value: (String) -> String?) {
        let audioLanguage = value("audio_lang"), audioName = value("audio_name")
        let audioTrackId = value("audio_track_id")
        if audioLanguage != nil || audioName != nil || audioTrackId != nil {
            audio = Track(language: audioLanguage, name: audioName, trackId: audioTrackId)
        }
        switch value("sub_type") {
        case "INTERNAL":
            subtitle = .embedded(Track(
                language: value("sub_lang"), name: value("sub_name"), trackId: value("sub_track_id"),
                isForced: value("sub_is_forced").flatMap { $0 == "true" ? true : $0 == "false" ? false : nil }
            ))
        case "ADDON":
            subtitle = .addon(
                id: value("sub_addon_id") ?? "", url: value("sub_addon_url") ?? "",
                language: value("sub_lang") ?? "", addonName: value("sub_addon_name") ?? ""
            )
        case "DISABLED":
            subtitle = .disabled
        default:
            subtitle = nil
        }
        if isEmpty { return nil }
    }

    init(audio: Track? = nil, subtitle: Subtitle? = nil) {
        self.audio = audio
        self.subtitle = subtitle
    }

    // MARK: Saving a pick

    /// The memory after the viewer picks an audio track: the subtitle half is kept.
    ///
    /// Upstream's 1.1.0-beta.12 fix (19b8a0c2): their base for a save was a copy consumed as the
    /// restore applied, so a later save wrote the restored subtitle away. The base here is the
    /// memory as loaded at the start of playback plus this session's picks, never a consumed copy.
    func choosingAudio(_ track: Track) -> TrackMemory {
        var copy = self
        copy.audio = track
        return copy
    }

    func choosingSubtitle(_ subtitle: Subtitle) -> TrackMemory {
        var copy = self
        copy.subtitle = subtitle
        return copy
    }

    // MARK: Building from the player's tracks

    static func track(_ track: PlayerTrack) -> Track {
        Track(
            language: track.language?.nilIfBlank,
            name: track.title.nilIfBlank,
            trackId: String(track.id),
            isForced: track.isForced
        )
    }

    /// The addon subtitle behind an external track. Addon subtitles are added to the engine in
    /// `request.subtitles` order (`PlayerChrome.start`, and Aether's load options), so the nth
    /// external track is the nth addon subtitle — a `PlayerTrack` does not carry the addon's id.
    static func addonSubtitle(
        for track: PlayerTrack, in tracks: [PlayerTrack], addonSubtitles: [Nuvio.Subtitle]
    ) -> Nuvio.Subtitle? {
        let external = tracks.filter(\.isExternal)
        guard let position = external.firstIndex(where: { $0.id == track.id }),
              position < addonSubtitles.count else { return nil }
        return addonSubtitles[position]
    }

    static func externalTrack(
        for subtitle: Nuvio.Subtitle, in tracks: [PlayerTrack], addonSubtitles: [Nuvio.Subtitle]
    ) -> PlayerTrack? {
        guard let position = addonSubtitles.firstIndex(of: subtitle) else { return nil }
        let external = tracks.filter(\.isExternal)
        return position < external.count ? external[position] : nil
    }

    static func remembered(addon subtitle: Nuvio.Subtitle) -> Subtitle {
        .addon(id: subtitle.id, url: subtitle.url, language: subtitle.lang, addonName: subtitle.addonName ?? "")
    }

    // MARK: Matching — upstream's findMatchingTrackIndex

    /// Upstream's strict match (track id with language and name; then the exact name; then a
    /// name that contains it, each with the language), then its language fallback.
    static func match(_ target: Track, in tracks: [PlayerTrack]) -> PlayerTrack? {
        strictMatch(target, in: tracks) ?? languageFallback(target, in: tracks)
    }

    private static func normalised(_ value: String?) -> String? {
        value?.trimmingCharacters(in: .whitespaces).lowercased().nilIfBlank
    }

    /// Languages compare across `en` / `eng` / `en-US`, since Android's ExoPlayer and mpv do not
    /// spell them alike and the memory is shared between the two.
    private static func language(_ value: String?) -> String? {
        normalised(value).map(MediaLanguage.normalise)
    }

    private static func strictMatch(_ target: Track, in tracks: [PlayerTrack]) -> PlayerTrack? {
        let id = normalised(target.trackId), name = normalised(target.name)
        let lang = language(target.language)
        func languageAgrees(_ track: PlayerTrack) -> Bool {
            lang == nil || language(track.language) == lang
        }
        if let id, let hit = tracks.first(where: { track in
            normalised(String(track.id)) == id && languageAgrees(track)
                && (name == nil || normalised(track.title) == name
                    || normalised(track.title)?.contains(name!) == true)
        }) { return hit }
        guard let name else { return nil }
        if let hit = tracks.first(where: { normalised($0.title) == name && languageAgrees($0) }) {
            return hit
        }
        return tracks.first { normalised($0.title)?.contains(name) == true && languageAgrees($0) }
    }

    /// Same language (or a regional form of it); only forced tracks when the remembered one was
    /// forced; among several, the same regional variant first.
    private static func languageFallback(_ target: Track, in tracks: [PlayerTrack]) -> PlayerTrack? {
        guard let wanted = language(target.language) else { return nil }
        let base = baseLanguage(wanted)
        var candidates = tracks.filter { track in
            language(track.language).map { baseLanguage($0) == base } ?? false
        }
        if target.isForced == true { candidates = candidates.filter(\.isForced) }
        guard candidates.count > 1 else { return candidates.first }
        return candidates.first { language($0.language) == wanted } ?? candidates.first
    }

    private static func baseLanguage(_ code: String) -> String {
        String(code.split(separator: "-").first ?? Substring(code))
    }
}

/// The per-profile store, under upstream's keys. A `PreferenceStore` so the settings blob
/// carries it in the `track_preference` feature exactly as the Android app writes it.
@MainActor
final class TrackPreferenceStore: PreferenceStore {
    init(defaults: UserDefaults = .standard) { super.init(namespace: "trackPreference", defaults: defaults) }

    func memory(forContentId contentId: String) -> TrackMemory? {
        guard !contentId.isEmpty else { return nil }
        return TrackMemory { field in
            (self.storedValue(TrackMemory.key(field, contentId: contentId)) as? String)?.nilIfBlank
        }
    }

    /// A pick changes its own half and keeps the other as stored. Reading the store rather than
    /// a copy taken at start is what makes upstream's 1.1.0-beta.12 fix hold here: a restored
    /// subtitle is still in the store when the viewer later picks an audio track.
    func rememberAudio(_ track: TrackMemory.Track, forContentId contentId: String) {
        save((memory(forContentId: contentId) ?? TrackMemory()).choosingAudio(track), forContentId: contentId)
    }

    func rememberSubtitle(_ subtitle: TrackMemory.Subtitle, forContentId contentId: String) {
        save((memory(forContentId: contentId) ?? TrackMemory()).choosingSubtitle(subtitle), forContentId: contentId)
    }

    func save(_ memory: TrackMemory, forContentId contentId: String) {
        guard !contentId.isEmpty else { return }
        for (field, value) in memory.storedFields {
            let key = TrackMemory.key(field, contentId: contentId)
            if let value {
                if storedValue(key) as? String != value { setString(key, value) }
            } else if storedValue(key) != nil {
                remove(key)
            }
        }
    }
}
