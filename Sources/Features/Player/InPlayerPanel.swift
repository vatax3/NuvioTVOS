import SwiftUI

/// Shared in-playback panel chrome.
///
/// Both reference apps keep player choices in a trailing panel above the video rather than
/// navigating away or presenting a full-screen settings page.  Owning the vertical scroll view
/// here makes that rule impossible to forget for a newly added player tool.
struct InPlayerPanel<Content: View>: View {
    @Environment(\.nuvioColors) private var colors
    @FocusState private var closeFocused: Bool

    let title: String
    var subtitle: String?
    /// A common refresh affordance keeps dynamic panels (sources and episodes) on the same
    /// interaction model as Android TV/iOS instead of making a viewer leave playback to retry.
    var onReload: (() -> Void)? = nil
    /// Information-only panels have no selectable row to receive focus.  In that case the close
    /// affordance is the predictable landing point for the Siri Remote.
    var focusCloseOnAppear = false
    /// MPV owns Menu centrally so one physical key press cannot be delivered to both the side
    /// panel and the player underneath. AVPlayer has no equivalent root handler, therefore it
    /// keeps the default `true` behaviour.
    var handlesExit = true
    let onDismiss: () -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        ZStack {
            Color.black.opacity(0.42)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture(perform: onDismiss)

            HStack(spacing: 0) {
                Spacer(minLength: 0)

                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .top, spacing: NuvioTheme.spacing.md) {
                        VStack(alignment: .leading, spacing: NuvioTheme.spacing.xxs) {
                            Text(title)
                                .nuvioText(NuvioTextStyles.sectionTitle)
                                .foregroundStyle(colors.textPrimary)
                                .lineLimit(1)
                            if let subtitle = subtitle?.nilIfBlank {
                                Text(subtitle)
                                    .nuvioText(NuvioTextStyles.metadata)
                                    .foregroundStyle(colors.textSecondary)
                                    .lineLimit(1)
                            }
                        }
                        Spacer(minLength: 0)
                        if let onReload {
                            Button(action: onReload) {
                                Image(systemName: "arrow.clockwise")
                                    .font(.system(size: NuvioTheme.sizes.icons.sm, weight: .semibold))
                                    .frame(width: dp(30), height: dp(30))
                            }
                            .buttonStyle(NuvioRowButtonStyle(cornerRadius: NuvioTheme.radii.md))
                            .accessibilityLabel(L10n.text("player.reload"))
                        }
                        Button(action: onDismiss) {
                            Image(systemName: "xmark")
                                .font(.system(size: NuvioTheme.sizes.icons.sm, weight: .semibold))
                                .frame(width: dp(30), height: dp(30))
                        }
                        .buttonStyle(NuvioRowButtonStyle(cornerRadius: NuvioTheme.radii.md))
                        .focused($closeFocused)
                        .accessibilityLabel(L10n.text("player.close"))
                    }
                    .padding(.horizontal, NuvioTheme.spacing.lg)
                    .padding(.top, NuvioTheme.spacing.lg)
                    .padding(.bottom, NuvioTheme.spacing.md)

                    Divider().overlay(colors.borderMuted)

                    // Every player panel is vertically scrollable.  This is critical on tvOS:
                    // focus scrolls the list automatically as the viewer moves down tracks,
                    // sources, or picture modes with the Siri Remote.
                    ScrollView(.vertical, showsIndicators: true) {
                        LazyVStack(alignment: .leading, spacing: NuvioTheme.spacing.md) {
                            content()
                        }
                        .padding(NuvioTheme.spacing.lg)
                        .padding(.bottom, NuvioTheme.spacing.xxl)
                    }
                    .scrollClipDisabled()
                }
                // Android TV and the shared iOS/macOS UI both use a 520 dp side panel that
                // runs the full height of the screen and is flush with its trailing edge, with
                // only the leading corners rounded — it reads as a drawer the picture slid
                // under, not a floating card.  A 300 dp panel truncates full release names and
                // turns source comparison into guesswork on a television-sized display.
                .frame(width: dp(520), alignment: .top)
                .frame(maxHeight: .infinity, alignment: .top)
                .background(panelSurface)
                .clipShape(
                    .rect(
                        topLeadingRadius: NuvioTheme.radii.xl,
                        bottomLeadingRadius: NuvioTheme.radii.xl,
                        bottomTrailingRadius: 0,
                        topTrailingRadius: 0,
                        style: .continuous
                    )
                )
                .overlay {
                    UnevenRoundedRectangle(
                        topLeadingRadius: NuvioTheme.radii.xl,
                        bottomLeadingRadius: NuvioTheme.radii.xl,
                        bottomTrailingRadius: 0,
                        topTrailingRadius: 0,
                        style: .continuous
                    )
                    .strokeBorder(.white.opacity(0.16), lineWidth: NuvioTheme.strokes.hairline)
                }
                .shadow(color: .black.opacity(0.42), radius: dp(18), x: -dp(5), y: 0)
                .ignoresSafeArea()
            }
        }
        .transition(.move(edge: .trailing).combined(with: .opacity))
        // The panel owns Menu while it is visible.  Letting the player underneath receive the
        // same press makes it interpret the just-closed panel as a request to leave playback,
        // which drops the viewer back onto the stream list.
        .modifier(InPlayerPanelExitHandler(isEnabled: handlesExit, action: onDismiss))
        .onAppear {
            guard focusCloseOnAppear else { return }
            Task { @MainActor in closeFocused = true }
        }
        .focusSection()
    }

    private var panelSurface: some View {
        Rectangle()
            .fill(.ultraThinMaterial)
            .overlay {
                Rectangle()
                    .fill(
                        LinearGradient(
                            colors: [colors.glassPanelTop.opacity(0.38), colors.glassPanelBottom.opacity(0.16)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
            }
    }
}

/// Conditionally installing the command handler (rather than returning early from one) is
/// important: a no-op child handler still participates in tvOS's responder chain and can make
/// its parent see the same Menu press later.
private struct InPlayerPanelExitHandler: ViewModifier {
    let isEnabled: Bool
    let action: () -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        if isEnabled {
            content.onExitCommand(perform: action)
        } else {
            content
        }
    }
}

/// A light section treatment for a player panel.  Settings cards were designed for static
/// screens; grouping rows this way keeps the player overlay readable over moving video.
struct InPlayerPanelSection<Content: View>: View {
    @Environment(\.nuvioColors) private var colors
    let title: String?
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: NuvioTheme.spacing.xs) {
            if let title = title?.nilIfBlank {
                Text(title.uppercased())
                    .nuvioText(NuvioTextStyles.metadata)
                    .foregroundStyle(colors.textTertiary)
                    .padding(.leading, NuvioTheme.spacing.xs)
            }
            LazyVStack(spacing: NuvioTheme.strokes.hairline) {
                content()
            }
            .padding(NuvioTheme.strokes.hairline)
            .background(colors.surfaceVariant.opacity(0.40), in: RoundedRectangle(cornerRadius: NuvioTheme.radii.lg, style: .continuous))
        }
    }
}

struct InPlayerPanelRow: View {
    @Environment(\.nuvioColors) private var colors
    @FocusState private var rowFocused: Bool

    let title: String
    var subtitle: String? = nil
    var systemImage: String? = nil
    var isSelected = false
    var isLoading = false
    /// The button that represents the active value (or the first available choice) receives
    /// focus when a player tool is opened.  This makes icon presses immediately navigable.
    var requestsInitialFocus = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: NuvioTheme.spacing.md) {
                if isLoading {
                    ProgressView().tint(colors.secondary)
                } else if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: NuvioTheme.sizes.icons.sm, weight: .medium))
                        .foregroundStyle(isSelected ? colors.secondary : colors.textSecondary)
                        .frame(width: dp(24))
                }
                VStack(alignment: .leading, spacing: NuvioTheme.spacing.xxs) {
                    Text(title)
                        .nuvioText(NuvioTextStyles.bodyCompact)
                        .foregroundStyle(colors.textPrimary)
                        .lineLimit(2)
                    if let subtitle = subtitle?.nilIfBlank {
                        Text(subtitle)
                            .nuvioText(NuvioTextStyles.metadata)
                            .foregroundStyle(colors.textSecondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(colors.secondary)
                }
            }
            .padding(.horizontal, NuvioTheme.spacing.md)
            .padding(.vertical, NuvioTheme.spacing.sm)
            .frame(maxWidth: .infinity, minHeight: dp(42), alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(NuvioRowButtonStyle(cornerRadius: NuvioTheme.radii.md))
        .focused($rowFocused)
        .onAppear {
            guard requestsInitialFocus else { return }
            Task { @MainActor in rowFocused = true }
        }
    }
}

struct InPlayerInfoRow: View {
    @Environment(\.nuvioColors) private var colors
    let title: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: NuvioTheme.spacing.md) {
            Text(title)
                .nuvioText(NuvioTextStyles.metadata)
                .foregroundStyle(colors.textSecondary)
            Spacer(minLength: 0)
            Text(value)
                .nuvioText(NuvioTextStyles.metadata)
                .foregroundStyle(colors.textPrimary)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
        }
        .padding(.horizontal, NuvioTheme.spacing.md)
        .padding(.vertical, NuvioTheme.spacing.sm)
    }
}

/// Dense source card shared by the in-playback chooser.  The source title is never enough on
/// its own: release, quality, HDR/audio flags and size are the information viewers use to make
/// a choice.  It intentionally does not consult the source-list display preferences, because a
/// player chooser must always be able to explain what each stream is.
private struct InPlayerSourceRow: View {
    @Environment(\.nuvioColors) private var colors
    @FocusState private var focused: Bool

    let stream: Stream
    let attributes: ParsedStreamAttributes?
    let cache: DebridCacheResult?
    let isCurrent: Bool
    let isLoading: Bool
    let requestsInitialFocus: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: NuvioTheme.spacing.sm) {
                VStack(alignment: .leading, spacing: NuvioTheme.spacing.xs) {
                    Text(stream.displayName)
                        .nuvioText(NuvioTextStyles.bodyCompact)
                        .foregroundStyle(colors.textPrimary)
                        .lineLimit(2)

                    if let detail = stream.displayDescription?.nilIfBlank,
                       detail != stream.displayName {
                        Text(detail)
                            .nuvioText(NuvioTextStyles.metadata)
                            .foregroundStyle(colors.textSecondary)
                            .lineLimit(3)
                    }

                    sourceFacts
                }

                Spacer(minLength: 0)

                if isLoading {
                    ProgressView().tint(colors.secondary)
                } else if isCurrent {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(colors.secondary)
                } else {
                    Image(systemName: "play.circle.fill")
                        .foregroundStyle(colors.textSecondary)
                }
            }
            .padding(NuvioTheme.spacing.md)
            .frame(maxWidth: .infinity, minHeight: dp(76), alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(NuvioRowButtonStyle(cornerRadius: NuvioTheme.radii.lg, scaleOnFocus: false))
        .background {
            RoundedRectangle(cornerRadius: NuvioTheme.radii.lg, style: .continuous)
                .fill(isCurrent ? colors.secondary.opacity(0.18) : colors.backgroundCard.opacity(0.72))
        }
        .overlay {
            RoundedRectangle(cornerRadius: NuvioTheme.radii.lg, style: .continuous)
                .strokeBorder(isCurrent ? colors.secondary.opacity(0.75) : .white.opacity(0.08), lineWidth: NuvioTheme.strokes.hairline)
        }
        .focused($focused)
        .disabled(isLoading)
        .onAppear {
            guard requestsInitialFocus else { return }
            Task { @MainActor in focused = true }
        }
    }

    @ViewBuilder
    private var sourceFacts: some View {
        HStack(spacing: NuvioTheme.spacing.xs) {
            if let resolution = attributes?.resolution, resolution != .unknown {
                NuvioBadge(text: resolution.displayName, tint: colors.secondary, filled: true)
            }
            if let quality = attributes?.quality, quality != .unknown {
                NuvioBadge(text: quality.displayName)
            }
            ForEach((attributes?.visualTags ?? []).filter { $0 != .unknown }.prefix(2), id: \.self) { tag in
                NuvioBadge(text: tag.displayName, tint: colors.premium)
            }
            ForEach((attributes?.audioTags ?? []).filter { $0 != .unknown }.prefix(1), id: \.self) { tag in
                NuvioBadge(text: tag.displayName)
            }
            if let size = attributes?.sizeGb {
                Text(String(format: "%.2f GB", size))
                    .nuvioText(NuvioTextStyles.metadata)
                    .foregroundStyle(colors.textTertiary)
            }
            if let cache, cache.state == .cached {
                Image(systemName: "bolt.fill")
                    .font(.system(size: NuvioTheme.sizes.icons.xs, weight: .semibold))
                    .foregroundStyle(colors.cached)
                    .accessibilityLabel("Cached")
            }
        }
        .lineLimit(1)
    }
}

/// Source selection stays inside playback.  It deliberately uses the same resolver and filter
/// engine as the regular Sources screen; choosing a row replaces the full-screen player request
/// in place instead of pushing a route and making the video disappear.
struct InPlayerSourcesPanel: View {
    @Environment(\.nuvioColors) private var colors
    @Environment(AddonStore.self) private var addons
    @Environment(PluginStore.self) private var plugins
    @Environment(AppSettings.self) private var settings
    @Environment(LibraryStore.self) private var library
    @Environment(Router.self) private var router

    let request: PlaybackRequest
    let onDismiss: () -> Void
    var handlesExit = true

    @State private var model = StreamsViewModel()
    @State private var selectedAddon: String?

    private var sourceRequest: StreamRequest? { request.sourceRequest }
    private var displayedGroups: [AddonStreams] {
        guard let selectedAddon else { return model.groups }
        return model.groups.filter { $0.addonName == selectedAddon }
    }
    private var hasCurrentSource: Bool {
        displayedGroups.contains { group in
            group.streams.contains { PlaybackSourceIdentity.matches($0, playback: request) }
        }
    }

    var body: some View {
        InPlayerPanel(
            title: L10n.text("player.sources"),
            subtitle: [request.subtitleLine, "\(model.totalCount) available"].compactMap { $0?.nilIfBlank }.joined(separator: " · "),
            onReload: { Task { await load() } },
            handlesExit: handlesExit,
            onDismiss: onDismiss
        ) {
            if !model.groups.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: NuvioTheme.spacing.xs) {
                        sourceFilter(L10n.text("player.all_sources"), isSelected: selectedAddon == nil) { selectedAddon = nil }
                        ForEach(model.groups) { group in
                            sourceFilter(group.addonName, isSelected: selectedAddon == group.addonName) {
                                selectedAddon = group.addonName
                            }
                        }
                    }
                    .padding(.horizontal, NuvioTheme.spacing.xs)
                }
            }

            if model.isLoading && model.groups.isEmpty {
                ProgressView("Searching sources…")
                    .tint(colors.secondary)
                    .frame(maxWidth: .infinity, minHeight: dp(180))
            } else if let error = model.resolveError?.nilIfBlank {
                InPlayerPanelSection(title: "Could not open source") {
                    InPlayerInfoRow(title: "Error", value: error)
                }
            } else if displayedGroups.isEmpty {
                InPlayerPanelSection(title: nil) {
                    InPlayerInfoRow(title: L10n.text("player.sources"), value: L10n.text("player.no_playable_source"))
                }
            } else {
                ForEach(Array(displayedGroups.enumerated()), id: \.element.id) { groupIndex, group in
                    InPlayerPanelSection(title: group.addonName) {
                        ForEach(Array(group.streams.enumerated()), id: \.element.id) { streamIndex, stream in
                            InPlayerSourceRow(
                                stream: stream,
                                attributes: model.attributes[stream.stableKey],
                                cache: model.cacheState(for: stream),
                                isCurrent: isCurrent(stream),
                                isLoading: model.resolvingKey == stream.stableKey,
                                requestsInitialFocus: isCurrent(stream)
                                    || (!hasCurrentSource && groupIndex == 0 && streamIndex == 0)
                            ) {
                                Task { await select(stream) }
                            }
                        }
                    }
                }
            }
        }
        .task { await load() }
    }

    private func sourceFilter(_ title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .nuvioText(NuvioTextStyles.metadata)
                .foregroundStyle(isSelected ? colors.textPrimary : colors.textSecondary)
                .lineLimit(1)
                .padding(.horizontal, NuvioTheme.spacing.md)
                .padding(.vertical, NuvioTheme.spacing.sm)
                .background(isSelected ? colors.secondary.opacity(0.28) : colors.surfaceVariant.opacity(0.50), in: Capsule())
        }
        .buttonStyle(NuvioRowButtonStyle(cornerRadius: NuvioTheme.radii.xl))
    }

    private func load() async {
        guard let sourceRequest else { return }
        if settings.player.pluginsEnabled {
            model.pluginScrapers = plugins.enabledScrapers
            model.groupPluginsByRepository = settings.player.groupPluginStreamsByRepository
            model.pluginRepositoryNames = Dictionary(
                plugins.repositories.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first }
            )
        }
        await model.load(request: sourceRequest, addonStore: addons, settings: settings)
    }

    private func select(_ stream: Stream) async {
        guard let sourceRequest, case .success(let url) = await model.playableURL(for: stream, settings: settings) else {
            return
        }
        router.play(
            PlaybackRequest(
                streamURL: url,
                title: sourceRequest.title,
                subtitleLine: [sourceRequest.episodeLabel, sourceRequest.episodeName]
                    .compactMap { $0 }.joined(separator: " · ").nilIfBlank,
                streamName: stream.displayName,
                filename: stream.behaviorHints?.filename,
                headers: stream.behaviorHints?.proxyHeaders?.request ?? [:],
                contentId: sourceRequest.contentId,
                contentType: sourceRequest.contentType,
                videoId: sourceRequest.videoId,
                season: sourceRequest.season,
                episode: sourceRequest.episode,
                poster: sourceRequest.poster,
                backdrop: sourceRequest.backdrop,
                logo: sourceRequest.logo,
                startFromBeginning: false,
                preview: library.cachedPreview(contentType: sourceRequest.contentType, contentId: sourceRequest.contentId),
                nextUp: nextUpRequest,
                imdbId: sourceRequest.imdbId,
                subtitles: model.subtitles,
                sourceRequest: sourceRequest,
                sourceAddonName: stream.addonName,
                sourceAddonLogo: stream.addonLogo,
                sourceDescription: stream.displayDescription,
                sourceHints: stream.sources ?? [],
                sourceStableKey: stream.stableKey
            )
        )
        onDismiss()
    }

    private func isCurrent(_ stream: Stream) -> Bool {
        PlaybackSourceIdentity.matches(stream, playback: request)
    }

    private var nextUpRequest: StreamRequest? {
        guard let sourceRequest, let nextId = sourceRequest.nextUpVideoId else { return nil }
        var next = sourceRequest
        next.videoId = nextId
        next.nextUpVideoId = nil
        next.episodeName = nil
        let parts = nextId.split(separator: ":")
        if parts.count >= 3 {
            next.season = Int(parts[parts.count - 2])
            next.episode = Int(parts[parts.count - 1])
        }
        return next
    }
}
