import SwiftUI
import Observation

/// Port of `StreamScreenViewModel` — fans out to every addon exposing `stream` for this id,
/// applies the debrid preference matrix, checks instant availability, and resolves torrent
/// sources into playable links.
@Observable
@MainActor
final class StreamsViewModel {
    private(set) var groups: [AddonStreams] = []
    private(set) var isLoading = true
    private(set) var failedAddons: [String] = []
    private(set) var cacheStates: [String: DebridCacheResult] = [:]
    private(set) var attributes: [String: ParsedStreamAttributes] = [:]
    private(set) var resolvingKey: String?
    private(set) var resolveError: String?
    private(set) var filteredOutCount = 0
    /// External subtitle tracks, fetched alongside the streams and handed to the player.
    private(set) var subtitles: [Subtitle] = []

    private let client: StremioClient

    init(client: StremioClient = .shared) {
        self.client = client
    }

    var totalCount: Int { groups.reduce(0) { $0 + $1.streams.count } }

    private func loadSubtitles(request: StreamRequest, addonStore: AddonStore) async {
        let providers = addonStore.addonsProviding(
            resource: "subtitles", type: request.contentType, id: request.videoId
        )
        guard !providers.isEmpty else { return }

        var collected: [Subtitle] = []
        await withTaskGroup(of: [Subtitle].self) { group in
            for addon in providers {
                group.addTask { [client] in
                    (try? await client.fetchSubtitles(
                        addon: addon, type: request.contentType, videoId: request.videoId
                    )) ?? []
                }
            }
            for await tracks in group { collected.append(contentsOf: tracks) }
        }
        // The same file often shows up through several addons; the URL is the real identity.
        var seen = Set<String>()
        subtitles = collected.filter { seen.insert($0.url).inserted }
    }

    /// Flat list in display order — used for auto-play selection.
    var orderedStreams: [Stream] { groups.flatMap(\.streams) }

    func load(request: StreamRequest, addonStore: AddonStore, settings: AppSettings) async {
        isLoading = true
        groups = []
        failedAddons = []
        cacheStates = [:]
        attributes = [:]
        filteredOutCount = 0
        defer { isLoading = false }

        // Subtitles come from a different resource and different addons, so they load in
        // parallel with the streams rather than delaying the list.
        Task { await loadSubtitles(request: request, addonStore: addonStore) }

        let providers = addonStore.addonsProviding(
            resource: "stream", type: request.contentType, id: request.videoId
        )
        guard !providers.isEmpty else { return }

        var collected: [(Addon, [Stream])] = []
        await withTaskGroup(of: (Addon, [Stream]?).self) { group in
            for addon in providers {
                group.addTask { [client] in
                    let streams = try? await client.fetchStreams(
                        addon: addon, type: request.contentType, videoId: request.videoId
                    )
                    return (addon, streams)
                }
            }
            for await (addon, streams) in group {
                guard let streams else {
                    failedAddons.append(addon.displayName)
                    continue
                }
                guard !streams.isEmpty else { continue }
                collected.append((addon, streams))
            }
        }

        // Parse once; both filtering and the row chips read from this.
        var parsed: [String: ParsedStreamAttributes] = [:]
        for (_, streams) in collected {
            for stream in streams { parsed[stream.stableKey] = StreamAttributeParser.parse(stream) }
        }
        attributes = parsed

        let filterInput = settings.streamFilterInput
        var rendered: [AddonStreams] = []
        var removed = 0
        for (addon, streams) in collected {
            let kept = StreamFilterEngine.apply(to: streams, attributes: parsed, input: filterInput)
            removed += streams.count - kept.count
            guard !kept.isEmpty else { continue }
            rendered.append(AddonStreams(
                addonName: addon.displayName, addonLogo: addon.logo, streams: kept
            ))
        }
        filteredOutCount = removed
        groups = rendered.sorted {
            $0.addonName.localizedCaseInsensitiveCompare($1.addonName) == .orderedAscending
        }

        await refreshCacheStates(settings: settings)
    }

    /// Batch instant-availability lookup for the torrent sources on screen.
    private func refreshCacheStates(settings: AppSettings) async {
        let credentials = settings.debrid.cacheCheckCredentials
        guard !credentials.isEmpty else { return }

        let hashes = Array(Set(orderedStreams.compactMap { $0.effectiveInfoHash?.lowercased() }))
        guard !hashes.isEmpty else { return }

        cacheStates = await DebridClient.shared.checkCache(
            infoHashes: hashes, credentials: credentials
        )
    }

    func cacheState(for stream: Stream) -> DebridCacheResult? {
        guard let hash = stream.effectiveInfoHash?.lowercased() else { return nil }
        return cacheStates[hash]
    }

    /// Returns a directly playable URL, resolving through debrid when the source is a torrent.
    func playableURL(for stream: Stream, settings: AppSettings) async -> Result<String, Error> {
        if let direct = stream.streamURL() {
            return .success(direct)
        }
        guard settings.debrid.enabled, let credential = settings.debrid.activeResolver else {
            return .failure(DebridError.notConfigured)
        }
        guard let infoHash = stream.effectiveInfoHash else {
            return .failure(DebridError.noPlayableFile)
        }

        resolvingKey = stream.stableKey
        resolveError = nil
        defer { resolvingKey = nil }

        do {
            let url = try await DebridClient.shared.resolvePlayableLink(
                infoHash: infoHash,
                magnetURI: stream.torrentMagnetURI(),
                fileIndex: stream.fileIdx,
                preferredFileName: stream.behaviorHints?.filename,
                credential: credential
            )
            return .success(url)
        } catch {
            resolveError = error.localizedDescription
            return .failure(error)
        }
    }
}

struct StreamsView: View {
    @Environment(\.nuvioColors) private var colors
    @Environment(AddonStore.self) private var addons
    @Environment(LibraryStore.self) private var library
    @Environment(AppSettings.self) private var settings
    @Environment(Router.self) private var router

    let request: StreamRequest

    @State private var model = StreamsViewModel()
    @State private var didAutoPlay = false

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: NuvioTheme.spacing.xl) {
                header

                if let error = model.resolveError {
                    banner(error, tint: colors.error)
                }
                if !settings.debrid.enabled, hasTorrentOnlySources {
                    banner(
                        "Torrent-only sources need a debrid service. Add one in Settings → Debrid.",
                        tint: colors.warning
                    )
                }

                if model.isLoading && model.groups.isEmpty {
                    NuvioLoadingView(message: "Searching your addons for sources…")
                        .frame(height: dp(320))
                } else if model.groups.isEmpty {
                    EmptyStateView(
                        systemImage: "antenna.radiowaves.left.and.right.slash",
                        title: "No sources found",
                        message: emptyMessage
                    )
                    .frame(height: dp(320))
                } else {
                    ForEach(model.groups) { group in
                        StreamGroupSection(
                            group: group,
                            model: model,
                            onSelect: { stream in Task { await play(stream) } }
                        )
                    }
                }
            }
            .padding(.top, NuvioTheme.layout.tvSafeVertical)
            .padding(.bottom, NuvioTheme.spacing.rail.tailPadding)
        }
        .scrollClipDisabled()
        .background(colors.background)
        .task {
            await model.load(request: request, addonStore: addons, settings: settings)
            await autoPlayIfConfigured()
        }
    }

    private var hasTorrentOnlySources: Bool {
        model.orderedStreams.contains { $0.streamURL() == nil && $0.isTorrent }
    }

    private var emptyMessage: String {
        if model.filteredOutCount > 0 {
            return "\(model.filteredOutCount) source\(model.filteredOutCount == 1 ? "" : "s") were hidden by your debrid filters. Loosen them in Settings → Debrid."
        }
        if model.failedAddons.isEmpty {
            return "None of your installed addons returned a stream for this title."
        }
        return "No sources returned. These addons failed: \(model.failedAddons.joined(separator: ", "))."
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: NuvioTheme.spacing.xs) {
            Text(request.title)
                .nuvioText(NuvioTextStyles.display)
                .foregroundStyle(colors.textPrimary)
                .lineLimit(1)

            HStack(spacing: NuvioTheme.spacing.md) {
                if let label = request.episodeLabel {
                    NuvioBadge(text: label, tint: colors.secondary)
                }
                if let name = request.episodeName?.nilIfBlank {
                    Text(name)
                        .nuvioText(NuvioTextStyles.bodyCompact)
                        .foregroundStyle(colors.textSecondary)
                        .lineLimit(1)
                }
                if model.totalCount > 0 {
                    Text("\(model.totalCount) sources")
                        .nuvioText(NuvioTextStyles.metadata)
                        .foregroundStyle(colors.textTertiary)
                }
                if model.filteredOutCount > 0 {
                    Text("\(model.filteredOutCount) filtered")
                        .nuvioText(NuvioTextStyles.metadata)
                        .foregroundStyle(colors.textTertiary)
                }
            }
        }
        .padding(.horizontal, NuvioTheme.components.row.horizontalPadding)
    }

    private func banner(_ text: String, tint: Color) -> some View {
        HStack(spacing: NuvioTheme.spacing.md) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(tint)
            Text(text)
                .nuvioText(NuvioTextStyles.bodyCompact)
                .foregroundStyle(colors.textSecondary)
            Spacer(minLength: 0)
        }
        .padding(NuvioTheme.spacing.lg)
        .background {
            RoundedRectangle(cornerRadius: NuvioTheme.radii.lg, style: .continuous)
                .fill(tint.opacity(0.12))
        }
        .padding(.horizontal, NuvioTheme.components.row.horizontalPadding)
    }

    // MARK: Actions

    private func autoPlayIfConfigured() async {
        guard !didAutoPlay, settings.player.streamAutoPlayMode != .off else { return }
        guard let candidate = StreamFilterEngine.autoPlayCandidate(
            from: model.orderedStreams,
            attributes: model.attributes,
            mode: settings.player.streamAutoPlayMode,
            source: settings.player.streamAutoPlaySource,
            regex: settings.player.streamAutoPlayRegex,
            preferredQuality: settings.player.autoPlayPreferredQuality,
            cacheStates: model.cacheStates
        ) else { return }
        didAutoPlay = true
        await play(candidate)
    }

    /// The follow-on episode, rebuilt from the current request so the player can chain.
    private var nextUpRequest: StreamRequest? {
        guard let nextId = request.nextUpVideoId else { return nil }
        var next = request
        next.videoId = nextId
        next.nextUpVideoId = nil
        next.episodeName = nil
        // Stremio episode ids are `<series>:<season>:<episode>`.
        let parts = nextId.split(separator: ":")
        if parts.count >= 3 {
            next.season = Int(parts[parts.count - 2])
            next.episode = Int(parts[parts.count - 1])
        }
        return next
    }

    private func play(_ stream: Stream) async {
        let result = await model.playableURL(for: stream, settings: settings)
        guard case .success(let url) = result else { return }

        let preview = library.cachedPreview(contentType: request.contentType, contentId: request.contentId)
        router.play(PlaybackRequest(
            streamURL: url,
            title: request.title,
            subtitleLine: [request.episodeLabel, request.episodeName]
                .compactMap { $0 }.joined(separator: " · ").nilIfBlank,
            streamName: stream.displayName,
            headers: stream.behaviorHints?.proxyHeaders?.request ?? [:],
            contentId: request.contentId,
            contentType: request.contentType,
            videoId: request.videoId,
            season: request.season,
            episode: request.episode,
            poster: request.poster,
            backdrop: request.backdrop,
            logo: request.logo,
            startFromBeginning: false,
            preview: preview,
            nextUp: nextUpRequest,
            imdbId: request.imdbId,
            subtitles: model.subtitles
        ))
    }
}

// MARK: - Group

private struct StreamGroupSection: View {
    @Environment(\.nuvioColors) private var colors
    @Environment(AppSettings.self) private var settings

    let group: AddonStreams
    let model: StreamsViewModel
    let onSelect: (Stream) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: NuvioTheme.spacing.md) {
            HStack(spacing: NuvioTheme.spacing.sm) {
                if settings.streamBadges.showAddonLogo, let logo = group.addonLogo?.nilIfBlank {
                    RemoteImage(url: logo, contentMode: .fit) { Color.clear }
                        .frame(width: NuvioTheme.sizes.icons.lg, height: NuvioTheme.sizes.icons.lg)
                        .clipShape(RoundedRectangle(cornerRadius: NuvioTheme.radii.xs))
                }
                Text(group.addonName)
                    .nuvioText(NuvioTextStyles.sectionTitle)
                    .foregroundStyle(colors.textPrimary)
                Text("\(group.streams.count)")
                    .nuvioText(NuvioTextStyles.metadata)
                    .foregroundStyle(colors.textTertiary)
            }
            .padding(.horizontal, NuvioTheme.components.row.horizontalPadding)

            VStack(spacing: NuvioTheme.spacing.sm) {
                ForEach(group.streams) { stream in
                    StreamRow(
                        stream: stream,
                        attributes: model.attributes[stream.stableKey],
                        cache: model.cacheState(for: stream),
                        isResolving: model.resolvingKey == stream.stableKey,
                        action: { onSelect(stream) }
                    )
                }
            }
            .padding(.horizontal, NuvioTheme.components.row.horizontalPadding)
        }
        .focusSection()
    }
}

// MARK: - Row (port of StreamComponents / StreamBadgeChips)

private struct StreamRow: View {
    @Environment(\.nuvioColors) private var colors
    @Environment(AppSettings.self) private var settings

    let stream: Stream
    let attributes: ParsedStreamAttributes?
    let cache: DebridCacheResult?
    let isResolving: Bool
    let action: () -> Void

    /// A torrent is actionable when debrid can resolve it, or when it already has an HTTP URL.
    private var isPlayable: Bool {
        if stream.streamURL() != nil { return true }
        return settings.debrid.canResolvePlayableLinks && stream.effectiveInfoHash != nil
    }

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: NuvioTheme.spacing.lg) {
                VStack(alignment: .leading, spacing: NuvioTheme.spacing.xs) {
                    Text(stream.displayName)
                        .nuvioText(NuvioTextStyles.cardTitle)
                        .foregroundStyle(colors.textPrimary)
                        .lineLimit(1)
                        .multilineTextAlignment(.leading)

                    if let detail = stream.displayDescription?.nilIfBlank, detail != stream.displayName {
                        Text(detail)
                            .nuvioText(NuvioTextStyles.metadata)
                            .foregroundStyle(colors.textSecondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }

                    if settings.streamBadges.placement != .hidden {
                        badges
                    }
                }

                Spacer(minLength: 0)

                trailingIcon
            }
            .padding(.horizontal, NuvioTheme.spacing.xl)
            .padding(.vertical, NuvioTheme.spacing.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(NuvioRowButtonStyle(cornerRadius: NuvioTheme.radii.lg, scaleOnFocus: false))
        .background {
            RoundedRectangle(cornerRadius: NuvioTheme.radii.lg, style: .continuous)
                .fill(colors.backgroundCard.opacity(0.55))
        }
        .disabled(!isPlayable)
        .opacity(isPlayable ? 1 : NuvioTheme.effects.disabledAlpha)
    }

    @ViewBuilder
    private var badges: some View {
        let a = attributes
        HStack(spacing: NuvioTheme.spacing.sm) {
            if let resolution = a?.resolution, resolution != .unknown {
                NuvioBadge(text: resolution.displayName, tint: colors.secondary, filled: true)
            }
            if let quality = a?.quality, quality != .unknown {
                NuvioBadge(text: quality.displayName)
            }
            ForEach((a?.visualTags ?? []).filter { $0 != .unknown }.prefix(2), id: \.self) { tag in
                NuvioBadge(text: tag.displayName, tint: colors.premium)
            }
            ForEach((a?.audioTags ?? []).filter { $0 != .unknown }.prefix(2), id: \.self) { tag in
                NuvioBadge(text: tag.displayName)
            }
            if let encode = a?.encode, encode != .unknown {
                NuvioBadge(text: encode.displayName)
            }

            if settings.streamBadges.showFileSizeBadges, let size = a?.sizeGb {
                Text(String(format: "%.2f GB", size))
                    .nuvioText(NuvioTextStyles.metadata)
                    .foregroundStyle(colors.textTertiary)
            }
            if settings.streamBadges.showSeederBadges, let seeders = a?.seeders {
                HStack(spacing: dp(3)) {
                    Image(systemName: "person.2.fill")
                        .font(.system(size: NuvioTheme.sizes.icons.xs))
                    Text("\(seeders)")
                        .nuvioText(NuvioTextStyles.metadata)
                }
                .foregroundStyle(colors.success)
            }
            if settings.streamBadges.showCacheBadges, let cache, cache.state != .unknown {
                NuvioBadge(
                    text: cache.state == .cached ? "Cached" : "Not cached",
                    tint: cache.state == .cached ? colors.cached : colors.textTertiary,
                    filled: cache.state == .cached
                )
            }
            if stream.isTorrent {
                NuvioBadge(text: "Torrent", tint: colors.torrent)
            }
        }
    }

    @ViewBuilder
    private var trailingIcon: some View {
        if isResolving {
            ProgressView()
                .progressViewStyle(.circular)
                .tint(colors.secondary)
        } else {
            Image(systemName: isPlayable ? "play.circle.fill" : "exclamationmark.circle")
                .font(.system(size: NuvioTheme.sizes.icons.lg))
                .foregroundStyle(isPlayable ? colors.textSecondary : colors.warning)
        }
    }
}
