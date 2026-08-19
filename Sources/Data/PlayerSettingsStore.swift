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
        get { option("internal_player_engine", default: .exoplayer) }
        set { setOption("internal_player_engine", newValue) }
    }

    var playerPreference: PlayerPreference {
        get { option("player_preference", default: .internalPlayer) }
        set { setOption("player_preference", newValue) }
    }

    var decoderPriority: DecoderPriority {
        get { option("decoder_priority", default: .preferHardware) }
        set { setOption("decoder_priority", newValue) }
    }

    var mpvHardwareDecodeMode: MpvHardwareDecodeMode {
        get { option("mpv_hardware_decode_mode", default: .hardwareDirect) }
        set { setOption("mpv_hardware_decode_mode", newValue) }
    }

    var autoSwitchInternalPlayerOnError: Bool {
        get { bool("auto_switch_internal_player_on_error", default: true) }
        set { setBool("auto_switch_internal_player_on_error", newValue) }
    }

    var tunnelingEnabled: Bool {
        get { bool("tunneling_enabled", default: false) }
        set { setBool("tunneling_enabled", newValue) }
    }

    var performanceModeEnabled: Bool {
        get { bool("nuvio_performance_mode_enabled", default: false) }
        set { setBool("nuvio_performance_mode_enabled", newValue) }
    }

    // MARK: - Video output

    var resizeMode: ResizeMode {
        get { option("resize_mode", default: .fit) }
        set { setOption("resize_mode", newValue) }
    }

    var frameRateMatching: Bool {
        get { bool("frame_rate_matching", default: false) }
        set { frameRateMatchingMode = newValue ? .startStop : .off }
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

    var resolutionMatchingEnabled: Bool {
        get { bool("resolution_matching_enabled", default: false) }
        set { setBool("resolution_matching_enabled", newValue) }
    }

    // MARK: - Dolby Vision / HDR

    var dolbyVision7HandlingMode: DolbyVision7HandlingMode {
        get { option("dv7_handling_mode", default: .auto) }
        set { setOption("dv7_handling_mode", newValue) }
    }

    var mapDolbyVision7ToHevc: Bool {
        get { bool("map_dv7_to_hevc", default: true) }
        set { setBool("map_dv7_to_hevc", newValue) }
    }

    var experimentalDv5ToDv81: Bool {
        get { bool("experimental_dv5_to_dv81_enabled", default: false) }
        set { setBool("experimental_dv5_to_dv81_enabled", newValue) }
    }

    var experimentalDv7ToDv81PreserveMapping: Bool {
        get { bool("experimental_dv7_to_dv81_preserve_mapping_enabled", default: false) }
        set { setBool("experimental_dv7_to_dv81_preserve_mapping_enabled", newValue) }
    }

    var stripHdr10PlusSei: Bool {
        get { bool("strip_hdr10plus_sei", default: false) }
        set { setBool("strip_hdr10plus_sei", newValue) }
    }

    // MARK: - Audio

    var preferredAudioLanguage: String {
        get { string("preferred_audio_language", default: "") }
        set { setString("preferred_audio_language", newValue) }
    }

    var secondaryPreferredAudioLanguage: String {
        get { string("secondary_preferred_audio_language", default: "") }
        set { setString("secondary_preferred_audio_language", newValue) }
    }

    var audioOutputChannels: AudioOutputChannels {
        get { option("audio_output_channels", default: .auto) }
        set { setOption("audio_output_channels", newValue) }
    }

    var forceOpticalPassthrough: Bool {
        get { bool("force_optical_passthrough", default: false) }
        set { setBool("force_optical_passthrough", newValue) }
    }

    var downmixEnabled: Bool {
        get { bool("downmix_enabled", default: false) }
        set { setBool("downmix_enabled", newValue) }
    }

    var downmixNormalizationEnabled: Bool {
        get { bool("downmix_normalization_enabled", default: true) }
        set { setBool("downmix_normalization_enabled", newValue) }
    }

    var maintainOriginalAudioOnDownmix: Bool {
        get { bool("maintain_original_audio_on_downmix", default: false) }
        set { setBool("maintain_original_audio_on_downmix", newValue) }
    }

    var centerMixLevelDb: Double {
        get { double("center_mix_level_db", default: 0) }
        set { setDouble("center_mix_level_db", newValue) }
    }

    var audioAmplificationDb: Double {
        get { double("audio_amplification_db", default: 0) }
        set { setDouble("audio_amplification_db", newValue) }
    }

    var persistAudioAmplification: Bool {
        get { bool("persist_audio_amplification", default: false) }
        set { setBool("persist_audio_amplification", newValue) }
    }

    var skipSilence: Bool {
        get { bool("skip_silence", default: false) }
        set { setBool("skip_silence", newValue) }
    }

    var rememberAudioDelayPerDevice: Bool {
        get { bool("remember_audio_delay_per_device", default: true) }
        set { setBool("remember_audio_delay_per_device", newValue) }
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

    var subtitleShowOnlyPreferredLanguages: Bool {
        get { bool("subtitle_show_only_preferred_languages", default: false) }
        set { setBool("subtitle_show_only_preferred_languages", newValue) }
    }

    var subtitleUseForcedSubtitles: Bool {
        get { bool("subtitle_use_forced_subtitles", default: true) }
        set { setBool("subtitle_use_forced_subtitles", newValue) }
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

    var useLibass: Bool {
        get { bool("use_libass", default: true) }
        set { setBool("use_libass", newValue) }
    }

    var libassRenderType: LibassRenderType {
        get { option("libass_render_type", default: .native) }
        set { setOption("libass_render_type", newValue) }
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

    var reuseLastLinkEnabled: Bool {
        get { bool("stream_reuse_last_link_enabled", default: true) }
        set { setBool("stream_reuse_last_link_enabled", newValue) }
    }

    var reuseLastLinkCacheHours: Int {
        get { int("stream_reuse_last_link_cache_hours", default: 6) }
        set { setInt("stream_reuse_last_link_cache_hours", newValue) }
    }

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

    var bufferEngineEnabled: Bool {
        get { bool("buffer_engine_enabled", default: true) }
        set { setBool("buffer_engine_enabled", newValue) }
    }

    var bufferBudgetManaged: Bool {
        get { bool("buffer_budget_managed", default: true) }
        set { setBool("buffer_budget_managed", newValue) }
    }

    var minBufferMs: Int {
        get { int("min_buffer_ms", default: 15_000) }
        set { setInt("min_buffer_ms", newValue) }
    }

    var maxBufferMs: Int {
        get { int("max_buffer_ms", default: 60_000) }
        set { setInt("max_buffer_ms", newValue) }
    }

    var bufferForPlaybackMs: Int {
        get { int("buffer_for_playback_ms", default: 2_500) }
        set { setInt("buffer_for_playback_ms", newValue) }
    }

    var bufferForPlaybackAfterRebufferMs: Int {
        get { int("buffer_for_playback_after_rebuffer_ms", default: 5_000) }
        set { setInt("buffer_for_playback_after_rebuffer_ms", newValue) }
    }

    var backBufferDurationMs: Int {
        get { int("back_buffer_duration_ms", default: 30_000) }
        set { setInt("back_buffer_duration_ms", newValue) }
    }

    var retainBackBufferFromKeyframe: Bool {
        get { bool("retain_back_buffer_from_keyframe", default: true) }
        set { setBool("retain_back_buffer_from_keyframe", newValue) }
    }

    var targetBufferSizeMb: Int {
        get { int("target_buffer_size_mb", default: 64) }
        set { setInt("target_buffer_size_mb", newValue) }
    }

    var allowLargeTargetBuffer: Bool {
        get { bool("allow_large_target_buffer", default: false) }
        set { setBool("allow_large_target_buffer", newValue) }
    }

    var enableBufferLogs: Bool {
        get { bool("enable_buffer_logs", default: false) }
        set { setBool("enable_buffer_logs", newValue) }
    }

    // MARK: - Network

    var enableHttp2: Bool {
        get { bool("enable_http2", default: true) }
        set { setBool("enable_http2", newValue) }
    }

    var useParallelConnections: Bool {
        get { bool("use_parallel_connections", default: false) }
        set { setBool("use_parallel_connections", newValue) }
    }

    var parallelNetworkEnabled: Bool {
        get { bool("parallel_network_enabled", default: false) }
        set { setBool("parallel_network_enabled", newValue) }
    }

    var parallelConnectionCount: Int {
        get { int("parallel_connection_count", default: 4) }
        set { setInt("parallel_connection_count", newValue) }
    }

    var parallelChunkSizeMb: Int {
        get { int("parallel_chunk_size_mb", default: 4) }
        set { setInt("parallel_chunk_size_mb", newValue) }
    }

    var vodCacheEnabled: Bool {
        get { bool("vod_cache_enabled", default: true) }
        set { setBool("vod_cache_enabled", newValue) }
    }

    var vodCacheSizeMode: VodCacheSizeMode {
        get { option("vod_cache_size_mode", default: .automatic) }
        set { setOption("vod_cache_size_mode", newValue) }
    }

    var vodCacheSizeMb: Int {
        get { int("vod_cache_size_mb", default: 512) }
        set { setInt("vod_cache_size_mb", newValue) }
    }

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

    var externalPlayerSendSkipSegments: Bool {
        get { bool("external_player_send_skip_segments", default: false) }
        set { setBool("external_player_send_skip_segments", newValue) }
    }

    // MARK: - Diagnostics

    var playbackIssueReportsEnabled: Bool {
        get { bool("playback_issue_reports_enabled", default: false) }
        set { setBool("playback_issue_reports_enabled", newValue) }
    }

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
