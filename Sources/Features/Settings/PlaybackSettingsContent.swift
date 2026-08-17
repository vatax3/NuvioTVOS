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
                tvOS plays through AVFoundation. The MPV engine option is reserved for the \
                extended-codec pipeline and has no effect until that backend is bundled.
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

            StreamBadgeSettingsCard()

            SettingsCard(title: "On-screen") {
                SettingsToggle(
                    title: "Pause overlay",
                    subtitle: "Show title and artwork while paused",
                    systemImage: "pause.rectangle",
                    isOn: $player.pauseOverlayEnabled
                )
                SettingsToggle(
                    title: "Loading overlay",
                    subtitle: "Cover the transition while a source is resolving",
                    systemImage: "hourglass",
                    isOn: $player.loadingOverlayEnabled
                )
                SettingsToggle(
                    title: "Loading status detail",
                    subtitle: "Show what the player is waiting on",
                    systemImage: "text.magnifyingglass",
                    isOn: $player.showPlayerLoadingStatus
                )
                SettingsToggle(
                    title: "Clock",
                    subtitle: "Show the time in the player overlay",
                    systemImage: "clock",
                    isOn: $player.osdClockEnabled
                )
                SettingsToggle(
                    title: "Parental guide",
                    subtitle: "Surface content warnings before playback starts",
                    systemImage: "exclamationmark.shield",
                    isOn: $player.parentalGuideEnabled
                )
            }

            SettingsCard(title: "Still watching") {
                SettingsToggle(
                    title: "Ask if you are still watching",
                    subtitle: "Pause after a run of unattended episodes",
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
            SettingsCard(title: "Picture") {
                SettingsOptionRow(
                    title: "Scaling",
                    subtitle: "How video fills the screen",
                    systemImage: "aspectratio",
                    selection: $player.resizeMode
                )
                SettingsOptionRow(
                    title: "Decoder priority",
                    subtitle: "Hardware decoding is cooler and quieter; software is more tolerant",
                    systemImage: "memorychip",
                    selection: $player.decoderPriority
                )
            }

            SettingsCard(
                title: "Display matching",
                footnote: "Matches the display's refresh rate to the source to remove judder."
            ) {
                SettingsToggle(
                    title: "Frame rate matching",
                    systemImage: "timelapse",
                    isOn: $player.frameRateMatching
                )
                if player.frameRateMatching {
                    SettingsOptionRow(
                        title: "Matching mode",
                        selection: $player.frameRateMatchingMode
                    )
                }
                SettingsToggle(
                    title: "Resolution matching",
                    subtitle: "Also switch output resolution to match the source",
                    systemImage: "rectangle.on.rectangle",
                    isOn: $player.resolutionMatchingEnabled
                )
            }

            SettingsCard(
                title: "Dolby Vision & HDR",
                footnote: """
                Profile 7 carries a second enhancement layer most TVs cannot read. These \
                controls decide whether Nuvio passes it through or plays the HDR10 base layer.
                """
            ) {
                SettingsOptionRow(
                    title: "Profile 7 handling",
                    systemImage: "sparkles.tv",
                    selection: $player.dolbyVision7HandlingMode
                )
                SettingsToggle(
                    title: "Map profile 7 to HEVC",
                    subtitle: "Present DV7 tracks as plain HEVC to the decoder",
                    isOn: $player.mapDolbyVision7ToHevc
                )
                SettingsToggle(
                    title: "Strip HDR10+ metadata",
                    subtitle: "Drop dynamic metadata some displays mishandle",
                    isOn: $player.stripHdr10PlusSei
                )
                SettingsToggle(
                    title: "Experimental: DV5 → DV8.1",
                    subtitle: "Convert single-layer profile 5 for wider display support",
                    isOn: $player.experimentalDv5ToDv81
                )
                SettingsToggle(
                    title: "Experimental: DV7 → DV8.1 with mapping",
                    subtitle: "Preserve the tone-mapping table during conversion",
                    isOn: $player.experimentalDv7ToDv81PreserveMapping
                )
            }
        }
    }

    // MARK: Audio

    private var audio: some View {
        @Bindable var player = player
        return VStack(alignment: .leading, spacing: NuvioTheme.components.settings.rowGap) {
            SettingsCard(
                title: "Track selection",
                footnote: "Two-letter codes, e.g. en, fr, ja. The first match wins."
            ) {
                SettingsTextFieldRow(
                    title: "Preferred audio language",
                    placeholder: "en",
                    text: $player.preferredAudioLanguage
                )
                SettingsTextFieldRow(
                    title: "Fallback audio language",
                    placeholder: "ja",
                    text: $player.secondaryPreferredAudioLanguage
                )
            }

            SettingsCard(title: "Output") {
                SettingsOptionRow(
                    title: "Channel layout",
                    subtitle: "Auto follows what the receiver reports",
                    systemImage: "hifispeaker.2.fill",
                    selection: $player.audioOutputChannels
                )
                SettingsToggle(
                    title: "Force optical passthrough",
                    subtitle: "For receivers connected over S/PDIF",
                    systemImage: "cable.connector",
                    isOn: $player.forceOpticalPassthrough
                )
            }

            SettingsCard(
                title: "Downmix",
                footnote: "Useful when surround tracks play with inaudible dialogue on stereo output."
            ) {
                SettingsToggle(
                    title: "Downmix to stereo",
                    systemImage: "waveform",
                    isOn: $player.downmixEnabled
                )
                if player.downmixEnabled {
                    SettingsToggle(
                        title: "Normalize downmix",
                        subtitle: "Even out loudness across channels",
                        isOn: $player.downmixNormalizationEnabled
                    )
                    SettingsToggle(
                        title: "Keep original track available",
                        subtitle: "Do not discard the surround track",
                        isOn: $player.maintainOriginalAudioOnDownmix
                    )
                    SettingsDecimalStepperRow(
                        title: "Centre channel boost",
                        subtitle: "Raise dialogue relative to the mix",
                        value: $player.centerMixLevelDb,
                        range: -6...12,
                        step: 0.5,
                        format: { String(format: "%+.1f dB", $0) }
                    )
                }
            }

            SettingsCard(title: "Level") {
                SettingsDecimalStepperRow(
                    title: "Amplification",
                    subtitle: "Gain applied on top of the source",
                    value: $player.audioAmplificationDb,
                    range: 0...20,
                    step: 1,
                    format: { String(format: "%+.0f dB", $0) }
                )
                SettingsToggle(
                    title: "Remember amplification",
                    subtitle: "Keep the gain across sessions",
                    isOn: $player.persistAudioAmplification
                )
                SettingsToggle(
                    title: "Skip silence",
                    subtitle: "Compress long silent stretches",
                    isOn: $player.skipSilence
                )
                SettingsToggle(
                    title: "Per-device audio delay",
                    subtitle: "Remember lip-sync offset per output device",
                    systemImage: "speaker.wave.2.bubble",
                    isOn: $player.rememberAudioDelayPerDevice
                )
            }
        }
    }

    // MARK: Subtitles

    private var subtitles: some View {
        @Bindable var player = player
        return VStack(alignment: .leading, spacing: NuvioTheme.components.settings.rowGap) {
            SettingsCard(title: "Languages") {
                SettingsTextFieldRow(
                    title: "Preferred subtitle language",
                    placeholder: "en",
                    text: $player.subtitlePreferredLanguage
                )
                SettingsTextFieldRow(
                    title: "Fallback subtitle language",
                    placeholder: "fr",
                    text: $player.subtitleSecondaryLanguage
                )
                SettingsToggle(
                    title: "Only show preferred languages",
                    subtitle: "Hide every other language in the picker",
                    isOn: $player.subtitleShowOnlyPreferredLanguages
                )
                SettingsToggle(
                    title: "Use forced subtitles",
                    subtitle: "Auto-enable forced tracks for foreign dialogue",
                    isOn: $player.subtitleUseForcedSubtitles
                )
                SettingsOptionRow(
                    title: "Group the picker by",
                    selection: $player.subtitleOrganizationMode
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

            SettingsCard(
                title: "Rendering",
                footnote: "libass renders full ASS/SSA styling; the native renderer is lighter."
            ) {
                SettingsToggle(title: "Use libass", isOn: $player.useLibass)
                if player.useLibass {
                    SettingsOptionRow(title: "Renderer", selection: $player.libassRenderType)
                }
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
                    SettingsStepperRow(
                        title: "Give up after",
                        subtitle: "Fall back to the source list if nothing resolves",
                        value: $player.streamAutoPlayTimeoutSeconds,
                        range: 3...60,
                        format: { "\($0)s" }
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
                    SettingsToggle(
                        title: "Fall back to the source list",
                        subtitle: "Show sources when the next episode cannot resolve",
                        isOn: $player.autoPlayNextEpisodeFallbackEnabled
                    )
                    SettingsToggle(
                        title: "Prefer the same release",
                        subtitle: "Use the addon's binge group to keep quality consistent",
                        isOn: $player.preferBingeGroupNextEpisode
                    )
                    SettingsToggle(
                        title: "Reuse the binge group link",
                        isOn: $player.reuseBingeGroup
                    )
                }
            }

            SettingsCard(
                title: "Link reuse",
                footnote: "Skips re-resolving a debrid link you already played recently."
            ) {
                SettingsToggle(title: "Reuse the last link", isOn: $player.reuseLastLinkEnabled)
                if player.reuseLastLinkEnabled {
                    SettingsStepperRow(
                        title: "Keep links for",
                        value: $player.reuseLastLinkCacheHours,
                        range: 1...48,
                        format: { "\($0) h" }
                    )
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
        @Bindable var player = player
        return VStack(alignment: .leading, spacing: NuvioTheme.components.settings.rowGap) {
            SettingsCard(
                title: "Buffer engine",
                footnote: """
                Managed budget lets Nuvio size buffers from available memory. Turn it off to \
                set the load-control values by hand.
                """
            ) {
                SettingsToggle(title: "Custom buffer engine", isOn: $player.bufferEngineEnabled)
                if player.bufferEngineEnabled {
                    SettingsToggle(title: "Managed budget", isOn: $player.bufferBudgetManaged)
                }
            }

            if player.bufferEngineEnabled && !player.bufferBudgetManaged {
                SettingsCard(title: "Load control") {
                    SettingsStepperRow(
                        title: "Minimum buffer",
                        value: $player.minBufferMs, range: 1_000...120_000, step: 1_000,
                        format: { "\($0 / 1000)s" }
                    )
                    SettingsStepperRow(
                        title: "Maximum buffer",
                        value: $player.maxBufferMs, range: 5_000...600_000, step: 5_000,
                        format: { "\($0 / 1000)s" }
                    )
                    SettingsStepperRow(
                        title: "Buffer before playback",
                        value: $player.bufferForPlaybackMs, range: 500...30_000, step: 500,
                        format: { String(format: "%.1fs", Double($0) / 1000) }
                    )
                    SettingsStepperRow(
                        title: "Buffer after a stall",
                        value: $player.bufferForPlaybackAfterRebufferMs,
                        range: 500...60_000, step: 500,
                        format: { String(format: "%.1fs", Double($0) / 1000) }
                    )
                    SettingsStepperRow(
                        title: "Back buffer",
                        subtitle: "How much played video to keep for instant rewind",
                        value: $player.backBufferDurationMs, range: 0...300_000, step: 5_000,
                        format: { "\($0 / 1000)s" }
                    )
                    SettingsToggle(
                        title: "Retain back buffer from keyframe",
                        isOn: $player.retainBackBufferFromKeyframe
                    )
                }
            }

            SettingsCard(title: "Memory") {
                SettingsStepperRow(
                    title: "Target buffer size",
                    value: $player.targetBufferSizeMb, range: 16...512, step: 16,
                    format: { "\($0) MB" }
                )
                SettingsToggle(
                    title: "Allow large target buffer",
                    subtitle: "Raise the ceiling on devices with spare memory",
                    isOn: $player.allowLargeTargetBuffer
                )
                SettingsToggle(
                    title: "Buffer logs",
                    subtitle: "Write buffer decisions to the system log",
                    isOn: $player.enableBufferLogs
                )
            }
        }
    }

    // MARK: Network

    private var network: some View {
        @Bindable var player = player
        return VStack(alignment: .leading, spacing: NuvioTheme.components.settings.rowGap) {
            SettingsCard(title: "Transport") {
                SettingsToggle(
                    title: "HTTP/2",
                    subtitle: "Multiplex requests where the host supports it",
                    systemImage: "network",
                    isOn: $player.enableHttp2
                )
                SettingsToggle(
                    title: "Parallel connections",
                    subtitle: "Fetch a stream over several connections at once",
                    systemImage: "arrow.triangle.branch",
                    isOn: $player.useParallelConnections
                )
                if player.useParallelConnections {
                    SettingsStepperRow(
                        title: "Connection count",
                        value: $player.parallelConnectionCount, range: 2...16
                    )
                    SettingsStepperRow(
                        title: "Chunk size",
                        value: $player.parallelChunkSizeMb, range: 1...32,
                        format: { "\($0) MB" }
                    )
                }
            }

            SettingsCard(
                title: "On-disk cache",
                footnote: "Caches already-downloaded ranges so seeking backwards is instant."
            ) {
                SettingsToggle(title: "Cache video on disk", isOn: $player.vodCacheEnabled)
                if player.vodCacheEnabled {
                    SettingsOptionRow(title: "Cache size", selection: $player.vodCacheSizeMode)
                    if player.vodCacheSizeMode == .manual {
                        SettingsStepperRow(
                            title: "Maximum cache",
                            value: $player.vodCacheSizeMb, range: 128...8_192, step: 128,
                            format: { $0 >= 1024 ? String(format: "%.1f GB", Double($0) / 1024) : "\($0) MB" }
                        )
                    }
                }
            }
        }
    }

    // MARK: Advanced

    private var advanced: some View {
        @Bindable var player = player
        return VStack(alignment: .leading, spacing: NuvioTheme.components.settings.rowGap) {
            SettingsCard(title: "Performance") {
                SettingsToggle(
                    title: "Performance mode",
                    subtitle: "Trim animations and background work during playback",
                    systemImage: "gauge.high",
                    isOn: $player.performanceModeEnabled
                )
                SettingsToggle(
                    title: "Tunneled playback",
                    subtitle: "Hand decoding straight to the display pipeline where supported",
                    isOn: $player.tunnelingEnabled
                )
                SettingsOptionRow(
                    title: "MPV hardware decoding",
                    selection: $player.mpvHardwareDecodeMode
                )
            }

            SettingsCard(title: "External player") {
                SettingsToggle(
                    title: "Forward subtitles",
                    subtitle: "Pass selected subtitle tracks to the external app",
                    isOn: $player.externalPlayerForwardSubtitles
                )
                SettingsToggle(
                    title: "Send skip segments",
                    isOn: $player.externalPlayerSendSkipSegments
                )
            }

            SettingsCard(
                title: "Diagnostics",
                footnote: "Reports are only sent when you explicitly submit one."
            ) {
                SettingsToggle(
                    title: "Playback issue reports",
                    systemImage: "ladybug",
                    isOn: $player.playbackIssueReportsEnabled
                )
            }
        }
    }
}
