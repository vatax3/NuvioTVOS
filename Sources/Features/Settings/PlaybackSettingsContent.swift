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
            case .general: return "General"
            case .video: return "Video"
            case .audio: return "Audio"
            case .subtitles: return "Subtitles"
            case .autoPlay: return "Auto-play"
            case .buffering: return "Buffering"
            case .network: return "Network"
            case .advanced: return "Advanced"
            }
        }
    }

    @State private var tab: Tab = .general

    private var player: PlayerSettingsStore { settings.player }

    var body: some View {
        VStack(alignment: .leading, spacing: NuvioTheme.components.settings.rowGap) {
            ChipRow(title: "Playback") {
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
                title: "Player",
                footnote: """
                AVFoundation is the system player; MPV is used for containers AVFoundation cannot
                demux, such as MKV. The app chooses MPV automatically when necessary.
                """
            ) {
                SettingsOptionRow(
                    title: "Playback target",
                    subtitle: "Where a source opens when you press Play",
                    systemImage: "play.rectangle.fill",
                    selection: $player.playerPreference
                )
                SettingsOptionRow(
                    title: "Internal engine",
                    subtitle: player.internalPlayerEngine.summary,
                    systemImage: "cpu",
                    selection: $player.internalPlayerEngine
                )
                SettingsToggle(
                    title: "Fall back on playback error",
                    subtitle: "Switch engines automatically when a source refuses to start",
                    systemImage: "arrow.triangle.2.circlepath",
                    isOn: $player.autoSwitchInternalPlayerOnError
                )
            }

            ExternalPlayerSettingsCard()

            StreamBadgeSettingsCard()

            SettingsCard(
                title: "TV player experience",
                footnote: "Nuvio layers these optional status views above the native tvOS transport controls."
            ) {
                SettingsToggle(
                    title: "Pause overlay",
                    subtitle: "Show the title and clock while playback is paused",
                    systemImage: "pause.rectangle",
                    isOn: $player.pauseOverlayEnabled
                )
                SettingsToggle(
                    title: "Loading overlay",
                    subtitle: "Show the artwork while a stream prepares or buffers",
                    systemImage: "hourglass",
                    isOn: $player.loadingOverlayEnabled
                )
                if player.loadingOverlayEnabled {
                    SettingsToggle(
                        title: "Loading status detail",
                        subtitle: "Show the current player status",
                        systemImage: "text.magnifyingglass",
                        isOn: $player.showPlayerLoadingStatus
                    )
                }
                SettingsToggle(
                    title: "Clock",
                    subtitle: "Show the time and the projected end of the film while the transport is up",
                    systemImage: "clock",
                    isOn: $player.osdClockEnabled
                )
                SettingsToggle(
                    title: "Parental guide",
                    subtitle: "Show content warnings shortly after playback starts",
                    systemImage: "exclamationmark.shield",
                    isOn: $player.parentalGuideEnabled
                )
                SettingsToggle(
                    title: "Ask if you are still watching",
                    subtitle: "Pause auto-play after a run of episodes",
                    systemImage: "person.fill.questionmark",
                    isOn: $player.stillWatchingEnabled
                )
                if player.stillWatchingEnabled {
                    SettingsStepperRow(
                        title: "Episodes before asking",
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
                title: "Display matching",
                footnote: """
                Apple TV Settings → Video and Audio → Match Content decides whether the \
                panel may change mode at all; this decides whether Nuvio asks it to. Both \
                have to be on for 23.976 fps film to play without judder.
                """
            ) {
                SettingsOptionRow(
                    title: "Frame rate & dynamic range",
                    subtitle: player.frameRateMatchingMode.summary,
                    systemImage: "tv.badge.wifi",
                    selection: $player.frameRateMatchingMode
                )
            }

            SettingsCard(
                title: "HDR & Dolby Vision",
                footnote: """
                tvOS owns tone mapping and the Dolby Vision path. The MPV engine hands the \
                display the source colorimetry and lets libplacebo map anything the panel \
                cannot show.
                """
            ) {
                SettingsInfoRow(
                    title: "Dolby Vision & HDR output",
                    value: "Managed by tvOS",
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
                title: "Audio output",
                footnote: """
                Which of MPV's audio drivers to use. AVFoundation is the path Apple supports \
                on a television; AudioUnit is the older one, which works on iOS and in the \
                simulator but is refused by Apple TV hardware — where it fails silently and \
                leaves the picture playing with no sound. Takes effect on the next playback.
                """
            ) {
                SettingsOptionRow(
                    title: "Driver",
                    subtitle: player.mpvAudioOutput.summary,
                    systemImage: "waveform.circle",
                    selection: $player.mpvAudioOutput
                )
            }

            SettingsCard(
                title: "Languages",
                footnote: """
                Picks the audio track when a file carries several. Media default leaves the \
                choice to the file; Device language follows the Apple TV's own language.
                """
            ) {
                SettingsLanguageRow(
                    title: "Preferred audio language",
                    systemImage: "waveform",
                    specials: [
                        .init(code: "", name: "Media default"),
                        .init(code: "device", name: "Device language")
                    ],
                    code: $player.preferredAudioLanguage
                )
                SettingsLanguageRow(
                    title: "Fallback audio language",
                    systemImage: "waveform",
                    specials: [.init(code: "", name: "None")],
                    code: $player.secondaryPreferredAudioLanguage
                )
            }

            SettingsCard(
                title: "Channel layout",
                footnote: """
                Auto takes multichannel only when the output has confirmed it and downmixes \
                otherwise; force Stereo if a receiver mishandles what it is sent. Applies \
                immediately, without leaving playback.
                """
            ) {
                SettingsOptionRow(
                    title: "Output channels",
                    subtitle: player.audioOutputChannels.summary,
                    systemImage: "hifispeaker.2.fill",
                    selection: $player.audioOutputChannels
                )
            }

            SettingsCard(
                title: "Audio",
                footnote: """
                Track selection, passthrough and dynamic-range handling are supplied by the \
                native tvOS player and Apple TV audio settings.
                """
            ) {
                SettingsInfoRow(
                    title: "Passthrough & dynamic range",
                    value: "Managed by tvOS",
                    tint: colors.textTertiary
                )
            }
        }
    }

    // MARK: Subtitles

    private var subtitles: some View {
        @Bindable var player = player
        return VStack(alignment: .leading, spacing: NuvioTheme.components.settings.rowGap) {
            SettingsCard(title: "Languages") {
                SettingsLanguageRow(
                    title: "Preferred subtitle language",
                    subtitle: "Chosen automatically when the file or an addon offers it",
                    systemImage: "captions.bubble",
                    specials: [.init(code: "", name: "None")],
                    code: $player.subtitlePreferredLanguage
                )
                SettingsLanguageRow(
                    title: "Fallback subtitle language",
                    subtitle: "Used when the preferred one is not available",
                    systemImage: "captions.bubble",
                    specials: [.init(code: "", name: "None")],
                    code: $player.subtitleSecondaryLanguage
                )
                SettingsToggle(
                    title: "Only show preferred languages",
                    subtitle: "Hide every other language in the picker",
                    isOn: $player.subtitleShowOnlyPreferredLanguages
                )
            }

            SettingsCard(title: "Appearance") {
                SettingsDecimalStepperRow(
                    title: "Text size",
                    value: $player.subtitleSize,
                    range: 0.5...3.0,
                    step: 0.1,
                    format: { String(format: "%.0f%%", $0 * 100) }
                )
                SettingsOptionRow(
                    title: "Apply to styled subtitles",
                    subtitle: player.subtitleStyleOverride.summary,
                    systemImage: "textformat",
                    selection: $player.subtitleStyleOverride
                )
                SettingsToggle(title: "Bold text", isOn: $player.subtitleBold)
                SettingsTextFieldRow(
                    title: "Text colour",
                    subtitle: "Hex, e.g. #FFFFFFFF",
                    placeholder: "#FFFFFFFF",
                    text: $player.subtitleTextColor
                )
                SettingsTextFieldRow(
                    title: "Background colour",
                    subtitle: "Use #00000000 for none",
                    placeholder: "#00000000",
                    text: $player.subtitleBackgroundColor
                )
                SettingsToggle(title: "Outline", isOn: $player.subtitleOutlineEnabled)
                if player.subtitleOutlineEnabled {
                    SettingsTextFieldRow(
                        title: "Outline colour",
                        placeholder: "#FF000000",
                        text: $player.subtitleOutlineColor
                    )
                    SettingsDecimalStepperRow(
                        title: "Outline width",
                        value: $player.subtitleOutlineWidth,
                        range: 0...6,
                        step: 0.5
                    )
                }
                SettingsDecimalStepperRow(
                    title: "Vertical offset",
                    subtitle: "Lift subtitles clear of burned-in text",
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
                title: "Source auto-play",
                footnote: "When enabled, Nuvio starts a source directly instead of showing the list."
            ) {
                SettingsOptionRow(
                    title: "Auto-play mode",
                    systemImage: "bolt.fill",
                    selection: $player.streamAutoPlayMode
                )
                if player.streamAutoPlayMode != .off {
                    SettingsOptionRow(
                        title: "Only consider",
                        selection: $player.streamAutoPlaySource
                    )
                }
                if player.streamAutoPlayMode == .matchRegex {
                    SettingsTextFieldRow(
                        title: "Match pattern",
                        subtitle: "Regular expression tested against the source name",
                        placeholder: "1080p.*WEB-DL",
                        text: $player.streamAutoPlayRegex
                    )
                }
                if player.streamAutoPlayMode == .preferredQuality {
                    SettingsTextFieldRow(
                        title: "Preferred quality",
                        subtitle: "e.g. 2160p, 1080p, 720p",
                        placeholder: "1080p",
                        text: $player.autoPlayPreferredQuality
                    )
                }
            }

            SettingsCard(title: "Next episode") {
                SettingsToggle(
                    title: "Auto-play next episode",
                    systemImage: "forward.end.fill",
                    isOn: $player.autoPlayNextEpisodeEnabled
                )
                if player.autoPlayNextEpisodeEnabled {
                    SettingsOptionRow(
                        title: "Trigger on",
                        selection: $player.nextEpisodeThresholdMode
                    )
                    switch player.nextEpisodeThresholdMode {
                    case .percent:
                        SettingsStepperRow(
                            title: "Percentage watched",
                            subtitle: "Also the point a video counts as finished",
                            value: $player.nextEpisodeThresholdPercent,
                            range: 50...100,
                            format: { "\($0)%" }
                        )
                    case .minutesBeforeEnd:
                        SettingsStepperRow(
                            title: "Minutes before end",
                            value: $player.nextEpisodeThresholdMinutesBeforeEnd,
                            range: 1...15,
                            format: { "\($0) min" }
                        )
                    }
                }
            }

            SettingsCard(title: "Skip intro") {
                SettingsToggle(
                    title: "Skip intro button",
                    subtitle: "Offer a skip control when a segment is detected",
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
                title: "Buffering",
                footnote: "AVFoundation and MPV manage buffering independently. Manual buffer budgets from Nuvio Android are not applied on tvOS."
            ) {
                SettingsInfoRow(
                    title: "Buffer tuning",
                    value: "Managed by the selected player engine",
                    tint: colors.textTertiary
                )
            }
        }
    }

    // MARK: Network

    private var network: some View {
        return VStack(alignment: .leading, spacing: NuvioTheme.components.settings.rowGap) {
            SettingsCard(
                title: "Network & cache",
                footnote: "The system networking stack and the selected player engine negotiate transport, connections and media caching."
            ) {
                SettingsInfoRow(
                    title: "Transport & media cache",
                    value: "Managed by tvOS / MPV",
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
                footnote: "These options apply only when MPV is selected or required for a stream container."
            ) {
                SettingsOptionRow(
                    title: "MPV hardware decoding",
                    selection: $player.mpvHardwareDecodeMode
                )
                SettingsToggle(
                    title: "Verbose player logs",
                    subtitle: "Write MPV diagnostics to the system log",
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
                title: "Basics",
                footnote: "The few playback decisions most people ever change. Switch to Advanced in Settings → Advanced for the full set."
            ) {
                SettingsOptionRow(
                    title: "Stream selection",
                    subtitle: "Whether Nuvio picks a source for you",
                    systemImage: "play.circle",
                    selection: $player.streamAutoPlayMode
                )
                SettingsToggle(
                    title: "Auto-play next episode",
                    subtitle: "Continue into the following episode when one finishes",
                    systemImage: "forward.end.fill",
                    isOn: $player.autoPlayNextEpisodeEnabled
                )
            }

            SettingsCard(title: "Subtitles & audio") {
                SettingsTextFieldRow(
                    title: "Subtitle language",
                    subtitle: "Two-letter code, e.g. fr. Leave empty for none.",
                    placeholder: "fr",
                    text: $player.subtitlePreferredLanguage
                )
                SettingsToggle(
                    title: "Use forced subtitles",
                    subtitle: "Show subtitles for foreign dialogue in an otherwise understood track",
                    isOn: $player.subtitleUseForcedSubtitles
                )
                SettingsToggle(
                    title: "Strip SDH subtitles",
                    subtitle: "Hide sound effects and speaker labels when only an SDH track is offered",
                    isOn: $player.subtitleStripSDH
                )
                SettingsTextFieldRow(
                    title: "Audio language",
                    subtitle: "Preferred track language when a source carries several",
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
            title: "External player",
            footnote: """
            AVFoundation plays H.264 and HEVC in MP4 and HLS but cannot open MKV, which a lot of \
            debrid sources use. Handing those to Infuse, VLC, nPlayer or Outplayer works. The \
            cost: a hand-off carries only a URL, so per-stream request headers are lost and Nuvio \
            stops tracking progress once another app takes over.
            """
        ) {
            if installed.isEmpty {
                SettingsInfoRow(
                    title: "Installed players",
                    value: "None found — install Infuse, VLC, nPlayer or Outplayer",
                    tint: colors.textSecondary
                )
            } else {
                SettingsRow(
                    title: "Ask each time",
                    subtitle: "Choose at the moment of playback",
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
