import SwiftUI

/// Port of `PlaybackSettingsScreen` + `PlaybackAudioSettings` + `PlaybackSubtitleSettings` +
/// `PlaybackAutoPlaySettings` + `PlaybackBufferNetworkSettings` + `NetworkSettingsScreen`.
///
/// This is the largest category in NuvioTV, so it is split into the same sub-tabs the Android
/// screen uses rather than one endless scroll.
struct PlaybackSettingsContent: View {
    @Environment(\.nuvioColors) private var colors
    @Environment(AppSettings.self) private var settings

    enum Tab: String, CaseIterable, Identifiable {
        case general, video, audio, subtitles, autoPlay, buffering, network, advanced
        var id: String { rawValue }
        var title: String {
            switch self {
            case .general: return L10n.text("settings.playback.tab_general", fallback: "General")
            case .video: return L10n.text("settings.playback.tab_video", fallback: "Video")
            case .audio: return L10n.text("settings.playback.tab_audio", fallback: "Audio")
            case .subtitles: return L10n.text("settings.playback.tab_subtitles", fallback: "Subtitles")
            case .autoPlay: return L10n.text("settings.playback.tab_autoplay", fallback: "Auto-play")
            case .buffering: return L10n.text("settings.playback.tab_buffering", fallback: "Buffering")
            case .network: return L10n.text("settings.playback.tab_network", fallback: "Network")
            case .advanced: return L10n.text("settings.playback.tab_advanced", fallback: "Advanced")
            }
        }
    }

    @State private var tab: Tab = .general

    private var player: PlayerSettingsStore { settings.player }

    var body: some View {
        VStack(alignment: .leading, spacing: NuvioTheme.components.settings.rowGap) {
            ChipRow(title: L10n.text("settings.playback.title", fallback: "Playback")) {
                ForEach(Tab.allCases) { option in
                    NuvioChip(
                        label: option.title,
                        isSelected: tab == option,
                        action: { tab = option }
                    )
                }
            }

            switch tab {
            case .general: general
            case .video: video
            case .audio: audio
            case .subtitles: subtitles
            case .autoPlay: autoPlay
            case .buffering: buffering
            case .network: network
            case .advanced: advanced
            }
        }
    }

    // MARK: General

    private var general: some View {
        @Bindable var player = player
        return VStack(alignment: .leading, spacing: NuvioTheme.components.settings.rowGap) {
            SettingsCard(
                title: L10n.text("settings.playback.player", fallback: "Player"),
                footnote: """
                AVFoundation is the system player; MPV is used for containers AVFoundation cannot
                demux, such as MKV. The app chooses MPV automatically when necessary.
                """
            ) {
                SettingsOptionRow(
                    title: L10n.text("settings.playback.target", fallback: "Playback target"),
                    subtitle: L10n.text("settings.playback.target_subtitle", fallback: "Where a source opens when you press Play"),
                    systemImage: "play.rectangle.fill",
                    selection: $player.playerPreference
                )
                SettingsOptionRow(
                    title: L10n.text("settings.playback.internal_engine", fallback: "Internal engine"),
                    subtitle: player.internalPlayerEngine.summary,
                    systemImage: "cpu",
                    selection: $player.internalPlayerEngine
                )
                SettingsToggle(
                    title: L10n.text("settings.playback.fallback_on_error", fallback: "Fall back on playback error"),
                    subtitle: L10n.text("settings.playback.fallback_on_error_subtitle", fallback: "Switch engines automatically when a source refuses to start"),
                    systemImage: "arrow.triangle.2.circlepath",
                    isOn: $player.autoSwitchInternalPlayerOnError
                )
            }

            ExternalPlayerSettingsCard()

            StreamBadgeSettingsCard()

            SettingsCard(
                title: L10n.text("settings.playback.picture", fallback: "Picture"),
                footnote: L10n.text("settings.playback.picture_footnote", fallback: "The shape playback starts in. The player's Display button still cycles through every mode for the title you are watching.")
            ) {
                SettingsOptionRow(
                    title: L10n.text("settings.playback.default_aspect", fallback: "Default aspect"),
                    systemImage: "aspectratio",
                    selection: $player.resizeMode
                )
            }

            SettingsCard(
                title: L10n.text("settings.playback.tv_experience", fallback: "TV player experience"),
                footnote: L10n.text("settings.playback.tv_experience_footnote", fallback: "Nuvio layers these optional status views above the native tvOS transport controls.")
            ) {
                SettingsToggle(
                    title: L10n.text("settings.playback.pause_overlay", fallback: "Pause overlay"),
                    subtitle: L10n.text("settings.playback.pause_overlay_subtitle", fallback: "Show the title and clock while playback is paused"),
                    systemImage: "pause.rectangle",
                    isOn: $player.pauseOverlayEnabled
                )
                SettingsToggle(
                    title: L10n.text("settings.playback.loading_overlay", fallback: "Loading overlay"),
                    subtitle: L10n.text("settings.playback.loading_overlay_subtitle", fallback: "Show the artwork while a stream prepares or buffers"),
                    systemImage: "hourglass",
                    isOn: $player.loadingOverlayEnabled
                )
                if player.loadingOverlayEnabled {
                    SettingsToggle(
                        title: L10n.text("settings.playback.loading_detail", fallback: "Loading status detail"),
                        subtitle: L10n.text("settings.playback.loading_detail_subtitle", fallback: "Show the current player status"),
                        systemImage: "text.magnifyingglass",
                        isOn: $player.showPlayerLoadingStatus
                    )
                }
                SettingsToggle(
                    title: L10n.text("settings.playback.clock", fallback: "Clock"),
                    subtitle: L10n.text("settings.playback.clock_subtitle", fallback: "Show the time and the projected end of the film while the transport is up"),
                    systemImage: "clock",
                    isOn: $player.osdClockEnabled
                )
                SettingsToggle(
                    title: L10n.text("settings.playback.parental_guide", fallback: "Parental guide"),
                    subtitle: L10n.text("settings.playback.parental_guide_subtitle", fallback: "Show content warnings shortly after playback starts"),
                    systemImage: "exclamationmark.shield",
                    isOn: $player.parentalGuideEnabled
                )
                SettingsToggle(
                    title: L10n.text("settings.playback.still_watching", fallback: "Ask if you are still watching"),
                    subtitle: L10n.text("settings.playback.still_watching_subtitle", fallback: "Pause auto-play after a run of episodes"),
                    systemImage: "person.fill.questionmark",
                    isOn: $player.stillWatchingEnabled
                )
                if player.stillWatchingEnabled {
                    SettingsStepperRow(
                        title: L10n.text("settings.playback.episodes_before_asking", fallback: "Episodes before asking"),
                        value: $player.stillWatchingEpisodeThreshold,
                        range: 1...10
                    )
                }
            }
        }
    }

    // MARK: Video

    private var video: some View {
        @Bindable var player = player
        return VStack(alignment: .leading, spacing: NuvioTheme.components.settings.rowGap) {
            SettingsCard(
                title: L10n.text("settings.playback.display_matching", fallback: "Display matching"),
                footnote: """
                Apple TV Settings → Video and Audio → Match Content decides whether the \
                panel may change mode at all; this decides whether Nuvio asks it to. Both \
                have to be on for 23.976 fps film to play without judder.
                """
            ) {
                SettingsOptionRow(
                    title: L10n.text("settings.playback.framerate_range", fallback: "Frame rate & dynamic range"),
                    subtitle: player.frameRateMatchingMode.summary,
                    systemImage: "tv.badge.wifi",
                    selection: $player.frameRateMatchingMode
                )
            }

            SettingsCard(
                title: L10n.text("settings.playback.hdr_dv", fallback: "HDR & Dolby Vision"),
                footnote: """
                tvOS owns tone mapping and the Dolby Vision path. The MPV engine hands the \
                display the source colorimetry and lets libplacebo map anything the panel \
                cannot show.
                """
            ) {
                SettingsInfoRow(
                    title: L10n.text("settings.playback.dv_hdr_output", fallback: "Dolby Vision & HDR output"),
                    value: L10n.text("settings.playback.managed_by_tvos", fallback: "Managed by tvOS"),
                    tint: colors.textTertiary
                )
            }
        }
    }

    // MARK: Audio

    private var audio: some View {
        @Bindable var player = player
        return VStack(alignment: .leading, spacing: NuvioTheme.components.settings.rowGap) {
            SettingsCard(
                title: L10n.text("settings.playback.audio_output", fallback: "Audio output"),
                footnote: """
                Which of MPV's audio drivers to use. AVFoundation is the path Apple supports \
                on a television; AudioUnit is the older one, which works on iOS and in the \
                simulator but is refused by Apple TV hardware — where it fails silently and \
                leaves the picture playing with no sound. Takes effect on the next playback.
                """
            ) {
                SettingsOptionRow(
                    title: L10n.text("settings.playback.driver", fallback: "Driver"),
                    subtitle: player.mpvAudioOutput.summary,
                    systemImage: "waveform.circle",
                    selection: $player.mpvAudioOutput
                )
            }

            SettingsCard(
                title: L10n.text("settings.playback.languages", fallback: "Languages"),
                footnote: """
                Picks the audio track when a file carries several. Media default leaves the \
                choice to the file; Device language follows the Apple TV's own language.
                """
            ) {
                SettingsLanguageRow(
                    title: L10n.text("settings.playback.preferred_audio", fallback: "Preferred audio language"),
                    systemImage: "waveform",
                    specials: [
                        .init(code: "", name: "Media default"),
                        .init(code: "device", name: L10n.text("settings.playback.device_language", fallback: "Device language"))
                    ],
                    code: $player.preferredAudioLanguage
                )
                SettingsLanguageRow(
                    title: L10n.text("settings.playback.fallback_audio", fallback: "Fallback audio language"),
                    systemImage: "waveform",
                    specials: [.init(code: "", name: "None")],
                    code: $player.secondaryPreferredAudioLanguage
                )
            }

            SettingsCard(
                title: L10n.text("settings.playback.channel_layout", fallback: "Channel layout"),
                footnote: """
                Auto takes multichannel only when the output has confirmed it and downmixes \
                otherwise; force Stereo if a receiver mishandles what it is sent. Applies \
                immediately, without leaving playback.
                """
            ) {
                SettingsOptionRow(
                    title: L10n.text("settings.playback.output_channels", fallback: "Output channels"),
                    subtitle: player.audioOutputChannels.summary,
                    systemImage: "hifispeaker.2.fill",
                    selection: $player.audioOutputChannels
                )
            }

            SettingsCard(
                title: L10n.text("settings.playback.mixing", fallback: "Mixing"),
                footnote: """
                These shape how a multichannel track is folded down. They are set here rather \
                than in the player because libmpv builds its audio chain from them at start, \
                and changing one mid-film would mean rebuilding it under the picture.
                """
            ) {
                SettingsStepperRow(
                    title: L10n.text("settings.playback.dialogue_level", fallback: "Dialogue level"),
                    subtitle: L10n.text("settings.playback.dialogue_level_subtitle", fallback: "How loud the centre channel is folded into a downmix"),
                    systemImage: "waveform.badge.mic",
                    value: $player.centerMixLevelDb,
                    range: PlayerAudioMix.centerMixRangeDb,
                    format: { $0 == 0 ? L10n.text("settings.playback.default", fallback: "Default") : "\($0 > 0 ? "+" : "")\($0) dB" }
                )
                SettingsToggle(
                    title: L10n.text("settings.playback.prevent_clipping", fallback: "Prevent downmix clipping"),
                    subtitle: L10n.text("settings.playback.prevent_clipping_subtitle", fallback: "Trades some level for headroom when 5.1 is folded to stereo"),
                    isOn: $player.downmixNormalization
                )
            }

            SettingsCard(
                title: L10n.text("settings.playback.amplification", fallback: "Amplification"),
                footnote: """
                The player's own amplification control is under Audio while a film is playing. \
                Remembering it is off by default: it is usually the fix for one badly mastered \
                release, and carrying it into the next film is how everything ends up loud.
                """
            ) {
                SettingsToggle(
                    title: L10n.text("settings.playback.remember_amplification", fallback: "Remember amplification"),
                    subtitle: amplificationSubtitle,
                    isOn: $player.persistAudioAmplification
                )
            }

            SettingsCard(
                title: L10n.text("settings.playback.tab_audio", fallback: "Audio"),
                footnote: """
                Track selection, passthrough and dynamic-range handling are supplied by the \
                native tvOS player and Apple TV audio settings.
                """
            ) {
                SettingsInfoRow(
                    title: L10n.text("settings.playback.passthrough_range", fallback: "Passthrough & dynamic range"),
                    value: L10n.text("settings.playback.managed_by_tvos", fallback: "Managed by tvOS"),
                    tint: colors.textTertiary
                )
            }
        }
    }

    private var amplificationSubtitle: String {
        let db = player.audioAmplificationDb
        guard player.persistAudioAmplification else {
            return L10n.text("settings.playback.starts_at_zero", fallback: "Every film starts at 0 dB")
        }
        return db == 0 ? L10n.text("settings.playback.currently_zero", fallback: "Currently 0 dB") : "Currently +\(db) dB"
    }

    // MARK: Subtitles

    private var subtitles: some View {
        @Bindable var player = player
        return VStack(alignment: .leading, spacing: NuvioTheme.components.settings.rowGap) {
            SettingsCard(title: L10n.text("settings.playback.languages", fallback: "Languages")) {
                SettingsLanguageRow(
                    title: L10n.text("settings.playback.preferred_subtitle", fallback: "Preferred subtitle language"),
                    subtitle: L10n.text("settings.playback.preferred_subtitle_sub", fallback: "Chosen automatically when the file or an addon offers it"),
                    systemImage: "captions.bubble",
                    specials: [.init(code: "", name: "None")],
                    code: $player.subtitlePreferredLanguage
                )
                SettingsLanguageRow(
                    title: L10n.text("settings.playback.fallback_subtitle", fallback: "Fallback subtitle language"),
                    subtitle: L10n.text("settings.playback.fallback_subtitle_sub", fallback: "Used when the preferred one is not available"),
                    systemImage: "captions.bubble",
                    specials: [.init(code: "", name: "None")],
                    code: $player.subtitleSecondaryLanguage
                )
                SettingsToggle(
                    title: L10n.text("settings.playback.only_preferred", fallback: "Only show preferred languages"),
                    subtitle: L10n.text("settings.playback.only_preferred_sub", fallback: "Hide every other language in the picker"),
                    isOn: $player.subtitleShowOnlyPreferredLanguages
                )
                SettingsOptionRow(
                    title: L10n.text("settings.playback.group_picker", fallback: "Group the picker"),
                    subtitle: L10n.text("settings.playback.group_picker_sub", fallback: "How addon tracks are arranged in the player's subtitle menu"),
                    systemImage: "list.bullet.indent",
                    selection: $player.subtitleOrganizationMode
                )
            }

            SettingsCard(title: L10n.text("settings.playback.appearance", fallback: "Appearance")) {
                SettingsDecimalStepperRow(
                    title: L10n.text("settings.playback.text_size", fallback: "Text size"),
                    value: $player.subtitleSize,
                    range: 0.5...3.0,
                    step: 0.1,
                    format: { String(format: "%.0f%%", $0 * 100) }
                )
                SettingsOptionRow(
                    title: L10n.text("settings.playback.apply_styled", fallback: "Apply to styled subtitles"),
                    subtitle: player.subtitleStyleOverride.summary,
                    systemImage: "textformat",
                    selection: $player.subtitleStyleOverride
                )
                SettingsToggle(title: L10n.text("settings.playback.bold_text", fallback: "Bold text"), isOn: $player.subtitleBold)
                SettingsTextFieldRow(
                    title: L10n.text("settings.playback.text_colour", fallback: "Text colour"),
                    subtitle: L10n.text("settings.playback.hex_hint", fallback: "Hex, e.g. #FFFFFFFF"),
                    placeholder: "#FFFFFFFF",
                    text: $player.subtitleTextColor
                )
                SettingsTextFieldRow(
                    title: L10n.text("settings.playback.background_colour", fallback: "Background colour"),
                    subtitle: L10n.text("settings.playback.background_none_hint", fallback: "Use #00000000 for none"),
                    placeholder: "#00000000",
                    text: $player.subtitleBackgroundColor
                )
                SettingsToggle(title: L10n.text("settings.playback.outline", fallback: "Outline"), isOn: $player.subtitleOutlineEnabled)
                if player.subtitleOutlineEnabled {
                    SettingsTextFieldRow(
                        title: L10n.text("settings.playback.outline_colour", fallback: "Outline colour"),
                        placeholder: "#FF000000",
                        text: $player.subtitleOutlineColor
                    )
                    SettingsDecimalStepperRow(
                        title: L10n.text("settings.playback.outline_width", fallback: "Outline width"),
                        value: $player.subtitleOutlineWidth,
                        range: 0...6,
                        step: 0.5
                    )
                }
                SettingsDecimalStepperRow(
                    title: L10n.text("settings.playback.vertical_offset", fallback: "Vertical offset"),
                    subtitle: L10n.text("settings.playback.vertical_offset_sub", fallback: "Lift subtitles clear of burned-in text"),
                    value: $player.subtitleVerticalOffset,
                    range: -100...100,
                    step: 5,
                    format: { String(format: "%.0f", $0) }
                )
            }

        }
    }

    // MARK: Auto-play

    private var autoPlay: some View {
        @Bindable var player = player
        return VStack(alignment: .leading, spacing: NuvioTheme.components.settings.rowGap) {
            SettingsCard(
                title: L10n.text("settings.playback.source_autoplay", fallback: "Source auto-play"),
                footnote: L10n.text("settings.playback.source_autoplay_footnote", fallback: "When enabled, Nuvio starts a source directly instead of showing the list.")
            ) {
                SettingsOptionRow(
                    title: L10n.text("settings.playback.autoplay_mode", fallback: "Auto-play mode"),
                    systemImage: "bolt.fill",
                    selection: $player.streamAutoPlayMode
                )
                if player.streamAutoPlayMode != .off {
                    SettingsOptionRow(
                        title: L10n.text("settings.playback.only_consider", fallback: "Only consider"),
                        selection: $player.streamAutoPlaySource
                    )
                }
                if player.streamAutoPlayMode == .matchRegex {
                    SettingsTextFieldRow(
                        title: L10n.text("settings.playback.match_pattern", fallback: "Match pattern"),
                        subtitle: L10n.text("settings.playback.match_pattern_sub", fallback: "Regular expression tested against the source name"),
                        placeholder: "1080p.*WEB-DL",
                        text: $player.streamAutoPlayRegex
                    )
                }
                if player.streamAutoPlayMode == .preferredQuality {
                    SettingsTextFieldRow(
                        title: L10n.text("settings.playback.preferred_quality", fallback: "Preferred quality"),
                        subtitle: L10n.text("settings.playback.quality_hint", fallback: "e.g. 2160p, 1080p, 720p"),
                        placeholder: "1080p",
                        text: $player.autoPlayPreferredQuality
                    )
                }
                if player.streamAutoPlayMode != .off {
                    SettingsStepperRow(
                        title: L10n.text("settings.playback.wait_before_starting", fallback: "Wait before starting"),
                        subtitle: L10n.text("settings.playback.wait_before_starting_sub", fallback: "Your chance to pick a different source before one is chosen"),
                        value: $player.streamAutoPlayTimeoutSeconds,
                        range: 0...30,
                        format: { $0 == 0 ? L10n.text("settings.playback.immediately", fallback: "Immediately") : "\($0)s" }
                    )
                }
            }

            SettingsCard(
                title: L10n.text("settings.playback.post_play", fallback: "When something ends"),
                footnote: L10n.text(
                    "settings.playback.post_play_footnote",
                    fallback: "Films offer recommendations at the point you choose. Episodes follow the Next episode threshold below."
                )
            ) {
                SettingsToggle(
                    title: L10n.text("settings.playback.post_play_recommendations", fallback: "Post-play recommendations"),
                    subtitle: L10n.text(
                        "settings.playback.post_play_recommendations_sub",
                        fallback: "Show titles like this one as a film reaches its end"
                    ),
                    systemImage: "sparkles.rectangle.stack",
                    isOn: $player.postPlayRecommendationsEnabled
                )
                if player.postPlayRecommendationsEnabled {
                    SettingsStepperRow(
                        title: L10n.text("settings.playback.post_play_timing", fallback: "Film recommendation timing"),
                        value: $player.postPlayMovieThresholdPercent,
                        range: PostPlayRecommendation.thresholdRange,
                        format: { "\($0)%" }
                    )
                }
            }

            SettingsCard(title: L10n.text("settings.playback.next_episode", fallback: "Next episode")) {
                SettingsToggle(
                    title: L10n.text("settings.playback.autoplay_next", fallback: "Auto-play next episode"),
                    systemImage: "forward.end.fill",
                    isOn: $player.autoPlayNextEpisodeEnabled
                )
                if player.autoPlayNextEpisodeEnabled {
                    SettingsOptionRow(
                        title: L10n.text("settings.playback.trigger_on", fallback: "Trigger on"),
                        selection: $player.nextEpisodeThresholdMode
                    )
                    switch player.nextEpisodeThresholdMode {
                    case .percent:
                        SettingsStepperRow(
                            title: L10n.text("settings.playback.percentage_watched", fallback: "Percentage watched"),
                            subtitle: L10n.text("settings.playback.percentage_watched_sub", fallback: "Also the point a video counts as finished"),
                            value: $player.nextEpisodeThresholdPercent,
                            range: 50...100,
                            format: { "\($0)%" }
                        )
                    case .minutesBeforeEnd:
                        SettingsStepperRow(
                            title: L10n.text("settings.playback.minutes_before_end", fallback: "Minutes before end"),
                            value: $player.nextEpisodeThresholdMinutesBeforeEnd,
                            range: 1...15,
                            format: { "\($0) min" }
                        )
                    }
                    SettingsToggle(
                        title: L10n.text("settings.playback.keep_same_release", fallback: "Keep the same release"),
                        subtitle: L10n.text("settings.playback.keep_same_release_sub", fallback: "Play the next episode from the source you were already watching"),
                        systemImage: "square.stack.3d.down.right",
                        isOn: $player.reuseBingeGroup
                    )
                    if player.reuseBingeGroup {
                        SettingsToggle(
                            title: L10n.text("settings.playback.fallback_autoplay", fallback: "Fall back to auto-play"),
                            subtitle: L10n.text("settings.playback.fallback_autoplay_sub", fallback: "When that release has no source for the next episode"),
                            isOn: $player.autoPlayNextEpisodeFallbackEnabled
                        )
                    }
                    SettingsToggle(
                        title: L10n.text("settings.playback.remember_release", fallback: "Remember the release across episodes"),
                        subtitle: L10n.text("settings.playback.remember_release_sub", fallback: "Carry the source you chose into the rest of the run"),
                        isOn: $player.preferBingeGroupNextEpisode
                    )
                }
            }

            SettingsCard(title: L10n.text("settings.playback.skip_intro", fallback: "Skip intro")) {
                SettingsToggle(
                    title: L10n.text("settings.playback.skip_intro_button", fallback: "Skip intro button"),
                    subtitle: L10n.text("settings.playback.skip_intro_button_sub", fallback: "Offer a skip control when a segment is detected"),
                    systemImage: "forward.fill",
                    isOn: $player.skipIntroEnabled
                )
            }
        }
    }

    // MARK: Buffering

    private var buffering: some View {
        return VStack(alignment: .leading, spacing: NuvioTheme.components.settings.rowGap) {
            SettingsCard(
                title: L10n.text("settings.playback.tab_buffering", fallback: "Buffering"),
                footnote: L10n.text("settings.playback.buffer_footnote", fallback: "AVFoundation and MPV manage buffering independently. Manual buffer budgets from Nuvio Android are not applied on tvOS.")
            ) {
                SettingsInfoRow(
                    title: L10n.text("settings.playback.buffer_tuning", fallback: "Buffer tuning"),
                    value: L10n.text("settings.playback.managed_by_engine", fallback: "Managed by the selected player engine"),
                    tint: colors.textTertiary
                )
            }
        }
    }

    // MARK: Network

    private var network: some View {
        return VStack(alignment: .leading, spacing: NuvioTheme.components.settings.rowGap) {
            SettingsCard(
                title: L10n.text("settings.playback.network_cache", fallback: "Network & cache"),
                footnote: L10n.text("settings.playback.network_footnote", fallback: "The system networking stack and the selected player engine negotiate transport, connections and media caching.")
            ) {
                SettingsInfoRow(
                    title: L10n.text("settings.playback.transport_cache", fallback: "Transport & media cache"),
                    value: L10n.text("settings.playback.managed_tvos_mpv", fallback: "Managed by tvOS / MPV"),
                    tint: colors.textTertiary
                )
            }
        }
    }

    // MARK: Advanced

    private var advanced: some View {
        @Bindable var player = player
        return VStack(alignment: .leading, spacing: NuvioTheme.components.settings.rowGap) {
            SettingsCard(
                title: "MPV",
                footnote: L10n.text("settings.playback.mpv_footnote", fallback: "These options apply only when MPV is selected or required for a stream container.")
            ) {
                SettingsOptionRow(
                    title: L10n.text("settings.playback.mpv_hwdec", fallback: "MPV hardware decoding"),
                    selection: $player.mpvHardwareDecodeMode
                )
                SettingsToggle(
                    title: L10n.text("settings.playback.verbose_logs", fallback: "Verbose player logs"),
                    subtitle: L10n.text("settings.playback.verbose_logs_sub", fallback: "Write MPV diagnostics to the system log"),
                    systemImage: "ladybug",
                    isOn: $player.verboseLoggingEnabled
                )
            }
        }
    }
}

// MARK: - Essential mode

/// Port of `EssentialPlaybackSettingsContent`. The official app keeps Playback on the rail in
/// Essential mode and trims it to a handful of decisions, rather than hiding the section — so
/// this is what Playback renders when Advanced is off.
struct EssentialPlaybackSettingsContent: View {
    @Environment(AppSettings.self) private var settings

    private var player: PlayerSettingsStore { settings.player }

    var body: some View {
        @Bindable var player = player

        VStack(alignment: .leading, spacing: NuvioTheme.components.settings.rowGap) {
            SettingsCard(
                title: L10n.text("settings.playback.basics", fallback: "Basics"),
                footnote: L10n.text("settings.playback.basics_footnote", fallback: "The few playback decisions most people ever change. Switch to Advanced in Settings → Advanced for the full set.")
            ) {
                SettingsOptionRow(
                    title: L10n.text("settings.playback.stream_selection", fallback: "Stream selection"),
                    subtitle: L10n.text("settings.playback.stream_selection_sub", fallback: "Whether Nuvio picks a source for you"),
                    systemImage: "play.circle",
                    selection: $player.streamAutoPlayMode
                )
                SettingsToggle(
                    title: L10n.text("settings.playback.autoplay_next", fallback: "Auto-play next episode"),
                    subtitle: L10n.text("settings.playback.continue_next_sub", fallback: "Continue into the following episode when one finishes"),
                    systemImage: "forward.end.fill",
                    isOn: $player.autoPlayNextEpisodeEnabled
                )
            }

            SettingsCard(title: L10n.text("settings.playback.subs_audio", fallback: "Subtitles & audio")) {
                SettingsTextFieldRow(
                    title: L10n.text("settings.playback.subtitle_language", fallback: "Subtitle language"),
                    subtitle: L10n.text("settings.playback.two_letter_hint", fallback: "Two-letter code, e.g. fr. Leave empty for none."),
                    placeholder: "fr",
                    text: $player.subtitlePreferredLanguage
                )
                SettingsToggle(
                    title: L10n.text("settings.playback.forced_subs", fallback: "Use forced subtitles"),
                    subtitle: L10n.text("settings.playback.forced_subs_sub", fallback: "Show subtitles for foreign dialogue in an otherwise understood track"),
                    isOn: $player.subtitleUseForcedSubtitles
                )
                SettingsToggle(
                    title: L10n.text("settings.playback.strip_sdh", fallback: "Strip SDH subtitles"),
                    subtitle: L10n.text("settings.playback.strip_sdh_sub", fallback: "Hide sound effects and speaker labels when only an SDH track is offered"),
                    isOn: $player.subtitleStripSDH
                )
                SettingsTextFieldRow(
                    title: L10n.text("settings.playback.audio_language", fallback: "Audio language"),
                    subtitle: L10n.text("settings.playback.audio_language_sub", fallback: "Preferred track language when a source carries several"),
                    placeholder: "fr",
                    text: $player.preferredAudioLanguage
                )
            }
        }
    }
}

// MARK: - External players

/// Picks which installed app a hand-off targets, and explains what the internal player can and
/// cannot open — the container question is the main reason to reach for an external player at all.
struct ExternalPlayerSettingsCard: View {
    @Environment(\.nuvioColors) private var colors
    @Environment(AppSettings.self) private var settings

    private var installed: [ExternalPlayer] { ExternalPlayerLauncher.installed }

    var body: some View {
        @Bindable var player = settings.player

        SettingsCard(
            title: L10n.text("settings.playback.external_player", fallback: "External player"),
            footnote: """
            AVFoundation plays H.264 and HEVC in MP4 and HLS but cannot open MKV, which a lot of \
            debrid sources use. Handing those to Infuse, VLC, nPlayer or Outplayer works. The \
            cost: a hand-off carries only a URL, so per-stream request headers are lost and Nuvio \
            stops tracking progress once another app takes over.
            """
        ) {
            if installed.isEmpty {
                SettingsInfoRow(
                    title: L10n.text("settings.playback.installed_players", fallback: "Installed players"),
                    value: L10n.text("settings.playback.no_players", fallback: "None found — install Infuse, VLC, nPlayer or Outplayer"),
                    tint: colors.textSecondary
                )
            } else {
                SettingsToggle(
                    title: L10n.text("settings.playback.send_subtitle", fallback: "Send the subtitle track"),
                    subtitle: installed.contains(where: \.acceptsSubtitleURL)
                        ? L10n.text("settings.playback.send_subtitle_sub", fallback: "Infuse and VLC accept one; nPlayer and Outplayer take the video URL only")
                        : L10n.text("settings.playback.no_subtitle_support", fallback: "Neither installed player accepts a subtitle URL"),
                    systemImage: "captions.bubble",
                    isOn: $player.externalPlayerForwardSubtitles
                )
                SettingsRow(
                    title: L10n.text("settings.playback.ask_each_time", fallback: "Ask each time"),
                    subtitle: L10n.text("settings.playback.ask_each_time_sub", fallback: "Choose at the moment of playback"),
                    systemImage: "questionmark.circle",
                    trailing: {
                        Image(systemName: player.preferredExternalPlayer.isEmpty
                              ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: NuvioTheme.sizes.icons.md))
                            .foregroundStyle(player.preferredExternalPlayer.isEmpty
                                             ? colors.secondary : colors.textTertiary)
                    },
                    action: { player.preferredExternalPlayer = "" }
                )
                ForEach(installed) { candidate in
                    SettingsRow(
                        title: candidate.displayName,
                        subtitle: candidate.summary,
                        systemImage: "arrow.up.forward.app",
                        trailing: {
                            Image(systemName: player.preferredExternalPlayer == candidate.rawValue
                                  ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: NuvioTheme.sizes.icons.md))
                                .foregroundStyle(player.preferredExternalPlayer == candidate.rawValue
                                                 ? colors.secondary : colors.textTertiary)
                        },
                        action: { player.preferredExternalPlayer = candidate.rawValue }
                    )
                }
            }

        }
    }
}
