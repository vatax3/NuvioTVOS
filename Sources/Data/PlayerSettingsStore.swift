import Foundation
import Observation

/// Port of `PlayerSettingsDataStore` — the playback surface, which is by far the largest
/// settings category in NuvioTV. Key strings match the Android preference names exactly.
@Observable
@MainActor
final class PlayerSettingsStore: PreferenceStore {
    init() { super.init(namespace: "player") }

    // MARK: - Engine

    var internalPlayerEngine: InternalPlayerEngine {
        get { option("internal_player_engine", default: MPVEngineSupport.isAvailable ? .mpv : .exoplayer) }
        set { setOption("internal_player_engine", newValue) }
    }

    var playerPreference: PlayerPreference {
        get { option("player_preference", default: .internalPlayer) }
        set { setOption("player_preference", newValue) }
    }

    var mpvHardwareDecodeMode: MpvHardwareDecodeMode {
        get { option("mpv_hardware_decode_mode", default: .hardwareDirect) }
        set { setOption("mpv_hardware_decode_mode", newValue) }
    }

    var autoSwitchInternalPlayerOnError: Bool {
        get { bool("auto_switch_internal_player_on_error", default: true) }
        set { setBool("auto_switch_internal_player_on_error", newValue) }
    }

    // MARK: - Video output

    var resizeMode: ResizeMode {
        get { option("resize_mode", default: .fit) }
        set { setOption("resize_mode", newValue) }
    }

    /// Android stores the mode alongside the older boolean and derives one from the other, so a
    /// profile written by either version resolves to the same behaviour.  Kept identical here
    /// because these keys are synced between devices.
    var frameRateMatchingMode: FrameRateMatchingMode {
        get {
            option(
                "frame_rate_matching_mode",
                default: bool("frame_rate_matching", default: false) ? .startStop : .off
            )
        }
        set {
            setOption("frame_rate_matching_mode", newValue)
            setBool("frame_rate_matching", newValue != .off)
        }
    }

    // MARK: - Dolby Vision / HDR

    // MARK: - Audio

    var preferredAudioLanguage: String {
        get { string("preferred_audio_language", default: "") }
        set { setString("preferred_audio_language", newValue) }
    }

    var secondaryPreferredAudioLanguage: String {
        get { string("secondary_preferred_audio_language", default: "") }
        set { setString("secondary_preferred_audio_language", newValue) }
    }

    /// Which libmpv audio driver to use. See `MpvAudioOutput` — the default is not cosmetic,
    /// it is the difference between sound and silence on Apple TV hardware.
    var mpvAudioOutput: MpvAudioOutput {
        get { option("mpv_audio_output", default: .automatic) }
        set { setOption("mpv_audio_output", newValue) }
    }

    /// `auto` here is mpv's `auto-safe`: take multichannel only when the output has confirmed
    /// it, and downmix otherwise.
    var audioOutputChannels: AudioOutputChannels {
        get { option("audio_output_channels", default: .auto) }
        set { setOption("audio_output_channels", newValue) }
    }

    /// `player_stats_hud_enabled`: puts a Stats button in the stream information panel, which
    /// toggles the live overlay. Two steps rather than one because the overlay is a diagnostic —
    /// it should be reachable during playback without being reachable by accident.
    var statsOverlayEnabled: Bool {
        get { bool("player_stats_hud_enabled", default: false) }
        set { setBool("player_stats_hud_enabled", newValue) }
    }

    /// Whether the in-player amplification survives the film it was set on.
    ///
    /// Off by default, as upstream has it, and the default is the right one: amplification is
    /// usually a fix for one badly mastered release, and carrying it into the next film is how
    /// somebody ends up wondering why everything is loud.
    var persistAudioAmplification: Bool {
        get { bool("persist_audio_amplification", default: false) }
        set { setBool("persist_audio_amplification", newValue) }
    }

    /// The amplification to start playback at. Only read when the switch above is on; written
    /// whenever the player's own control moves, so turning the switch on adopts what is set now.
    var audioAmplificationDb: Int {
        get { int("audio_amplification_db", default: 0) }
        set { setInt("audio_amplification_db", newValue) }
    }

    /// How loud the centre channel is folded into a downmix — the dialogue control.
    ///
    /// See `PlayerAudioMix.centerMixLevel(db:)`: zero means libswresample's own default, so the
    /// setting starts out changing nothing.
    var centerMixLevelDb: Int {
        get { int("center_mix_level_db", default: 0) }
        set { setInt("center_mix_level_db", newValue) }
    }

    /// `--audio-normalize-downmix`. Prevents a 5.1 track clipping when it is folded to stereo,
    /// at the cost of some level.
    var downmixNormalization: Bool {
        get { bool("downmix_normalization_enabled", default: false) }
        set { setBool("downmix_normalization_enabled", newValue) }
    }

    // MARK: - Subtitles

    var subtitlePreferredLanguage: String {
        get { string("subtitle_preferred_language", default: "") }
        set { setString("subtitle_preferred_language", newValue) }
    }

    var subtitleSecondaryLanguage: String {
        get { string("subtitle_secondary_language", default: "") }
        set { setString("subtitle_secondary_language", newValue) }
    }

    /// Defaults to scaling rather than to mpv's own "respect the script" behaviour: a viewer
    /// who has set a text size expects it to take effect, and size is the setting they are
    /// most often reaching for. Colours are left to the script, so signs still read correctly.
    var subtitleStyleOverride: SubtitleStyleOverride {
        get { option("subtitle_style_override", default: .scale) }
        set { setOption("subtitle_style_override", newValue) }
    }

    var subtitleShowOnlyPreferredLanguages: Bool {
        get { bool("subtitle_show_only_preferred_languages", default: false) }
        set { setBool("subtitle_show_only_preferred_languages", newValue) }
    }

    var subtitleUseForcedSubtitles: Bool {
        get { bool("subtitle_use_forced_subtitles", default: true) }
        set { setBool("subtitle_use_forced_subtitles", newValue) }
    }

    /// Off by default: an SDH track is still a correct subtitle track, and a viewer who chose
    /// one may have chosen it deliberately.
    var subtitleStripSDH: Bool {
        get { bool("subtitle_strip_sdh", default: false) }
        set { setBool("subtitle_strip_sdh", newValue) }
    }

    var subtitleSize: Double {
        get { double("subtitle_size", default: 1.0) }
        set { setDouble("subtitle_size", newValue) }
    }

    var subtitleBold: Bool {
        get { bool("subtitle_bold", default: false) }
        set { setBool("subtitle_bold", newValue) }
    }

    var subtitleTextColor: String {
        get { string("subtitle_text_color", default: "#FFFFFFFF") }
        set { setString("subtitle_text_color", newValue) }
    }

    var subtitleBackgroundColor: String {
        get { string("subtitle_background_color", default: "#00000000") }
        set { setString("subtitle_background_color", newValue) }
    }

    var subtitleOutlineEnabled: Bool {
        get { bool("subtitle_outline_enabled", default: true) }
        set { setBool("subtitle_outline_enabled", newValue) }
    }

    var subtitleOutlineColor: String {
        get { string("subtitle_outline_color", default: "#FF000000") }
        set { setString("subtitle_outline_color", newValue) }
    }

    var subtitleOutlineWidth: Double {
        get { double("subtitle_outline_width", default: 2) }
        set { setDouble("subtitle_outline_width", newValue) }
    }

    var subtitleVerticalOffset: Double {
        get { double("subtitle_vertical_offset", default: 0) }
        set { setDouble("subtitle_vertical_offset", newValue) }
    }

    // MARK: - Plugins

    var pluginsEnabled: Bool {
        get { bool("plugins_enabled", default: false) }
        set { setBool("plugins_enabled", newValue) }
    }

    var groupPluginStreamsByRepository: Bool {
        get { bool("group_streams_by_repository", default: false) }
        set { setBool("group_streams_by_repository", newValue) }
    }

    var subtitleOrganizationMode: SubtitleOrganizationMode {
        get { option("subtitle_organization_mode", default: .byLanguage) }
        set { setOption("subtitle_organization_mode", newValue) }
    }

    // MARK: - Auto-play & next episode

    var streamAutoPlayMode: StreamAutoPlayMode {
        get { option("stream_auto_play_mode", default: .off) }
        set { setOption("stream_auto_play_mode", newValue) }
    }

    var streamAutoPlaySource: StreamAutoPlaySource {
        get { option("stream_auto_play_source", default: .anyAddon) }
        set { setOption("stream_auto_play_source", newValue) }
    }

    var streamAutoPlayRegex: String {
        get { string("stream_auto_play_regex", default: "") }
        set { setString("stream_auto_play_regex", newValue) }
    }

    var streamAutoPlayTimeoutSeconds: Int {
        get { int("stream_auto_play_timeout_seconds", default: 10) }
        set { setInt("stream_auto_play_timeout_seconds", newValue) }
    }

    /// Target resolution for `StreamAutoPlayMode.preferredQuality`.
    var autoPlayPreferredQuality: String {
        get { string("stream_auto_play_preferred_quality", default: "1080p") }
        set { setString("stream_auto_play_preferred_quality", newValue) }
    }

    var autoPlayNextEpisodeEnabled: Bool {
        get { bool("stream_auto_play_next_episode_enabled", default: true) }
        set { setBool("stream_auto_play_next_episode_enabled", newValue) }
    }

    var autoPlayNextEpisodeFallbackEnabled: Bool {
        get { bool("stream_auto_play_next_episode_fallback_enabled", default: true) }
        set { setBool("stream_auto_play_next_episode_fallback_enabled", newValue) }
    }

    var preferBingeGroupNextEpisode: Bool {
        get { bool("stream_auto_play_prefer_bingegroup_next_episode", default: true) }
        set { setBool("stream_auto_play_prefer_bingegroup_next_episode", newValue) }
    }

    var reuseBingeGroup: Bool {
        get { bool("stream_auto_play_reuse_binge_group", default: true) }
        set { setBool("stream_auto_play_reuse_binge_group", newValue) }
    }

    var nextEpisodeThresholdMode: NextEpisodeThresholdMode {
        get { option("next_episode_threshold_mode", default: .percent) }
        set { setOption("next_episode_threshold_mode", newValue) }
    }

    var nextEpisodeThresholdPercent: Int {
        get { int("next_episode_threshold_percent_v2", default: 95) }
        set { setInt("next_episode_threshold_percent_v2", newValue) }
    }

    var nextEpisodeThresholdMinutesBeforeEnd: Int {
        get { int("next_episode_threshold_minutes_before_end_v2", default: 2) }
        set { setInt("next_episode_threshold_minutes_before_end_v2", newValue) }
    }

    // MARK: - Link reuse

    // MARK: - Overlays

    var skipIntroEnabled: Bool {
        get { bool("skip_intro_enabled", default: true) }
        set { setBool("skip_intro_enabled", newValue) }
    }

    var pauseOverlayEnabled: Bool {
        get { bool("pause_overlay_enabled", default: true) }
        set { setBool("pause_overlay_enabled", newValue) }
    }

    var loadingOverlayEnabled: Bool {
        get { bool("loading_overlay_enabled", default: true) }
        set { setBool("loading_overlay_enabled", newValue) }
    }

    var showPlayerLoadingStatus: Bool {
        get { bool("show_player_loading_status", default: true) }
        set { setBool("show_player_loading_status", newValue) }
    }

    var osdClockEnabled: Bool {
        get { bool("osd_clock_enabled", default: false) }
        set { setBool("osd_clock_enabled", newValue) }
    }

    var parentalGuideEnabled: Bool {
        get { bool("parental_guide_enabled", default: false) }
        set { setBool("parental_guide_enabled", newValue) }
    }

    var stillWatchingEnabled: Bool {
        get { bool("still_watching_enabled", default: true) }
        set { setBool("still_watching_enabled", newValue) }
    }

    var stillWatchingEpisodeThreshold: Int {
        get { int("still_watching_episode_threshold", default: 3) }
        set { setInt("still_watching_episode_threshold", newValue) }
    }

    // MARK: - Buffering

    // MARK: - Network

    // MARK: - External player

    /// Which external app a hand-off targets. Empty means "ask me".
    var preferredExternalPlayer: String {
        get { string("preferred_external_player", default: "") }
        set { setString("preferred_external_player", newValue) }
    }

    var externalPlayerForwardSubtitles: Bool {
        get { bool("external_player_forward_subtitles", default: true) }
        set { setBool("external_player_forward_subtitles", newValue) }
    }

    // MARK: - Diagnostics

    var verboseLoggingEnabled: Bool {
        get { bool("verbose_logging_enabled", default: false) }
        set { setBool("verbose_logging_enabled", newValue) }
    }

    // MARK: - Derived

    /// Fraction of a video that counts as "finished" for watched state and Continue Watching.
    var watchedThresholdFraction: Double {
        Double(nextEpisodeThresholdPercent) / 100.0
    }

    /// Returns true when playback at `position` of `duration` should trigger the next episode.
    func shouldAdvanceToNextEpisode(position: Double, duration: Double) -> Bool {
        guard duration > 0 else { return false }
        switch nextEpisodeThresholdMode {
        case .percent:
            return position / duration >= Double(nextEpisodeThresholdPercent) / 100.0
        case .minutesBeforeEnd:
            return (duration - position) <= Double(nextEpisodeThresholdMinutesBeforeEnd) * 60
        }
    }
}
