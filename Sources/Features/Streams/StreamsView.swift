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
    /// How many enabled addons were actually asked. Zero means the id or the type matched
    /// nothing installed, which is a very different failure from "asked, got nothing back".
    private(set) var queriedAddonCount = 0
    /// Enabled addons that advertise `stream` but were skipped because their `idPrefixes` do
    /// not cover this id — the usual cause when a catalog hands out `tmdb:` ids.
    private(set) var skippedForIdPrefix: [String] = []
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
        queriedAddonCount = 0
        skippedForIdPrefix = []
        defer { isLoading = false }

        // Subtitles come from a different resource and different addons, so they load in
        // parallel with the streams rather than delaying the list.
        Task { await loadSubtitles(request: request, addonStore: addonStore) }

        // Addons are asked with the id form they declare support for. A catalog that hands out
        // `tmdb:` ids would otherwise reach no torrent addon at all, since those all declare
        // `tt` prefixes — so the IMDb id resolved from the meta is offered as an alternative.
        let candidates = request.streamIdCandidates
        var providers: [(addon: Addon, videoId: String)] = []
        for addon in addonStore.enabledAddons where addon.supports(
            resource: "stream", type: request.contentType
        ) {
            if let id = candidates.first(where: {
                addon.handles(id: $0, resource: "stream", type: request.contentType)
            }) {
                providers.append((addon, id))
            } else {
                skippedForIdPrefix.append(addon.displayName)
            }
        }
        queriedAddonCount = providers.count
        guard !providers.isEmpty || !pluginScrapers.isEmpty else { return }

        var collected: [(Addon, [Stream])] = []
        await withTaskGroup(of: (Addon, [Stream]?).self) { group in
            for (addon, videoId) in providers {
                group.addTask { [client] in
                    guard let streams = try? await client.fetchStreams(
                        addon: addon, type: request.contentType, videoId: videoId
                    ) else { return (addon, nil) }
                    // An empty answer is not necessarily a miss: some addons publish their links
                    // inline on the meta entry instead of implementing `/stream`.
                    //
                    // Only worth a second request when the addon actually serves meta. Firing it
                    // blindly means every addon that legitimately has nothing costs a second
                    // round trip — and a full series meta is a large document — which is what
                    // made the source list sit and spin.
                    guard streams.isEmpty,
                          addon.supports(resource: "meta", type: request.contentType)
                    else { return (addon, streams) }
                    let inline = try? await client.fetchInlineStreams(
                        addon: addon, type: request.contentType, videoId: videoId
                    )
                    return (addon, inline ?? [])
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

        var pluginGroups = await runPluginScrapers(request: request, settings: settings)

        // Parse once; both filtering and the row chips read from this.
        var parsed: [String: ParsedStreamAttributes] = [:]
        for (_, streams) in collected {
            for stream in streams { parsed[stream.stableKey] = StreamAttributeParser.parse(stream) }
        }
        for group in pluginGroups {
            for stream in group.streams { parsed[stream.stableKey] = StreamAttributeParser.parse(stream) }
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
        // Plugin results go through the same filters as addon streams.
        for index in pluginGroups.indices {
            let kept = StreamFilterEngine.apply(
                to: pluginGroups[index].streams, attributes: parsed, input: filterInput
            )
            removed += pluginGroups[index].streams.count - kept.count
            pluginGroups[index].streams = kept
        }
        filteredOutCount = removed
        groups = rendered.sorted {
            $0.addonName.localizedCaseInsensitiveCompare($1.addonName) == .orderedAscending
        } + pluginGroups.filter { !$0.streams.isEmpty }

        await refreshCacheStates(settings: settings)
    }

    // MARK: Plugins

    /// Scrapers to run for this request; set by the view before `load`.
    var pluginScrapers: [InstalledScraper] = []
    /// Grouping preference, also supplied by the view.
    var groupPluginsByRepository = false
    /// Repository names, so a grouped section can be labelled.
    var pluginRepositoryNames: [String: String] = [:]

    /// Scrapers are keyed on TMDB ids, not IMDb, so the id has to be translated first.
    private(set) var pluginTmdbId: String?

    private func runPluginScrapers(
        request: StreamRequest,
        settings: AppSettings
    ) async -> [AddonStreams] {
        guard !pluginScrapers.isEmpty else { return [] }

        let mediaType = ContentType.from(request.contentType) == .series ? "tv" : "movie"
        let eligible = pluginScrapers.filter { $0.supports(type: request.contentType) }
        guard !eligible.isEmpty else { return [] }

        guard let tmdbId = await resolveTmdbId(request: request, settings: settings) else {
            failedAddons.append("Plugins (no TMDB id)")
            return []
        }
        pluginTmdbId = tmdbId

        var byScraper: [(InstalledScraper, [LocalScraperResult])] = []
        await withTaskGroup(of: (InstalledScraper, [LocalScraperResult]).self) { group in
            for scraper in eligible {
                group.addTask {
                    let results = await PluginRuntime.shared.execute(
                        code: scraper.code,
                        tmdbId: tmdbId,
                        mediaType: mediaType,
                        season: request.season,
                        episode: request.episode,
                        scraperId: scraper.id,
                        tmdbApiKey: settings.tmdb.apiKey
                    )
                    return (scraper, results)
                }
            }
            for await entry in group where !entry.1.isEmpty {
                byScraper.append(entry)
            }
        }

        // One section per scraper, or one per repository when the viewer asked for that.
        var sections: [String: (logo: String?, streams: [Stream])] = [:]
        for (scraper, results) in byScraper {
            let label = groupPluginsByRepository
                ? (pluginRepositoryNames[scraper.repositoryId] ?? scraper.name)
                : scraper.name
            var bucket = sections[label] ?? (scraper.logo, [])
            for (index, result) in results.enumerated() {
                bucket.streams.append(result.asStream(sourceName: label, occurrence: index))
            }
            sections[label] = bucket
        }

        return sections
            .sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }
            .map { AddonStreams(addonName: $0.key, addonLogo: $0.value.logo, streams: $0.value.streams) }
    }

    /// The request carries an IMDb id; TMDB's `find` endpoint converts it.
    private func resolveTmdbId(request: StreamRequest, settings: AppSettings) async -> String? {
        guard let imdbId = request.imdbId?.nilIfBlank
            ?? (request.contentId.hasPrefix("tt") ? request.contentId : nil) else { return nil }
        guard !settings.tmdb.apiKey.isEmpty else { return nil }
        let enrichment = await TMDBClient.shared.enrich(
            imdbId: imdbId,
            type: ContentType.from(request.contentType),
            apiKey: settings.tmdb.apiKey,
            language: settings.tmdb.language,
            // Only the id is needed; skip every optional append so this is one cheap call.
            options: TMDBClient.TMDBOptions(
                useArtwork: false, useBasicInfo: false, useCredits: false, useDetails: false,
                useTrailers: false, useNetworks: false, useProductions: false,
                useReleaseDates: false, useMoreLikeThis: false
            )
        )
        return enrichment?.tmdbId.map(String.init)
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
    @Environment(PluginStore.self) private var plugins
    @Environment(AppSettings.self) private var settings
    @Environment(Router.self) private var router

    let request: StreamRequest

    @State private var model = StreamsViewModel()
    @State private var didAutoPlay = false
    /// The reference apps keep the provider filter local to the source picker.  Keeping it in
    /// the view (rather than mutating the resolver's results) makes changing filters instant
    /// and preserves the complete list for auto-play.
    @State private var selectedAddon: String?
    /// Set when the viewer has to choose where a resolved stream opens.
    @State private var handOff: HandOffRequest?

    private var displayedGroups: [AddonStreams] {
        guard let selectedAddon else { return model.groups }
        return model.groups.filter { $0.addonName == selectedAddon }
    }

    var body: some View {
        ZStack {
            sourceBackdrop
            GeometryReader { proxy in
                HStack(spacing: 0) {
                    sourceContext
                        .frame(width: proxy.size.width * 0.40)

                    sourcePicker
                        .frame(width: proxy.size.width * 0.60)
                        .padding(.top, NuvioTheme.layout.tvSafeVertical)
                        .padding(.trailing, NuvioTheme.layout.tvSafeHorizontal)
                        .padding(.bottom, NuvioTheme.layout.tvSafeVertical)
                }
            }
        }
        .ignoresSafeArea()
        .sheet(item: $handOff) { pending in
            ExternalPlayerPicker(playback: pending.playback) {
                handOff = nil
                router.play(pending.playback)
            }
        }
        .task {
            // Handed in rather than read inside the model: the store is main-actor state and
            // the model runs the scrapers off it.
            if settings.player.pluginsEnabled {
                model.pluginScrapers = plugins.enabledScrapers
                model.groupPluginsByRepository = settings.player.groupPluginStreamsByRepository
                model.pluginRepositoryNames = Dictionary(
                    plugins.repositories.map { ($0.id, $0.name) },
                    uniquingKeysWith: { first, _ in first }
                )
            }
            await model.load(request: request, addonStore: addons, settings: settings)
            await autoPlayIfConfigured()
        }
    }

    /// The artwork carries the screen. It used to be held at 42% behind a blur and a
    /// full-frame gradient, which is a lot of machinery for something the viewer then cannot
    /// see — and the panel in front of it needs contrast in one place, not everywhere.
    private var sourceBackdrop: some View {
        ZStack {
            RemoteImage(url: request.backdrop ?? request.poster, contentMode: .fill) {
                colors.background
            }

            // Weighted to the leading edge, where the logo and episode line sit; the trailing
            // side keeps enough of a wash to seat the panel without hiding what is behind it.
            LinearGradient(
                stops: [
                    .init(color: colors.background.opacity(0.94), location: 0),
                    .init(color: colors.background.opacity(0.72), location: 0.28),
                    .init(color: colors.background.opacity(0.34), location: 0.55),
                    .init(color: colors.background.opacity(0.24), location: 1)
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
        }
        .ignoresSafeArea()
    }

    private var hasTorrentOnlySources: Bool {
        model.orderedStreams.contains { $0.streamURL() == nil && $0.isTorrent }
    }

    private var emptyMessage: String {
        if model.filteredOutCount > 0 {
            return "\(model.filteredOutCount) source\(model.filteredOutCount == 1 ? "" : "s") were hidden by your debrid filters. Loosen them in Settings → Debrid."
        }
        // Nothing was even asked: say which of the two reasons it was, because the fix differs.
        if model.queriedAddonCount == 0 {
            if model.skippedForIdPrefix.isEmpty {
                return """
                None of your addons provide streams. Cinemeta and OpenSubtitles only supply \
                metadata — add a source addon in Settings → Addons, or a scraper in \
                Settings → Plugins.
                """
            }
            return """
            These addons provide streams but not for this title's id: \
            \(model.skippedForIdPrefix.joined(separator: ", ")). It has no IMDb id, which is \
            what they expect.
            """
        }
        if model.failedAddons.isEmpty {
            return "None of your \(model.queriedAddonCount) source addons returned a stream for this title."
        }
        return "No sources returned. These addons failed: \(model.failedAddons.joined(separator: ", "))."
    }

    /// The iOS/tablet implementation uses the artwork side for identity and reserves the
    /// glass panel for source comparison.  This deliberately avoids repeating a giant title
    /// above every list, which was the main difference from the official picker.
    private var sourceContext: some View {
        VStack(alignment: .center, spacing: NuvioTheme.spacing.lg) {
            // The logo is the title, set in the film's own lettering. Printing the name under
            // it says the same thing twice and costs the panel a third of its height.
            if let logo = request.logo?.nilIfBlank {
                RemoteImage(url: logo, contentMode: .fit) { Color.clear }
                    .frame(maxWidth: dp(420), maxHeight: dp(150))
                    .accessibilityLabel(request.title)
            } else {
                Text(request.title)
                    .nuvioText(NuvioTextStyles.display)
                    .foregroundStyle(colors.textPrimary)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .shadow(color: .black.opacity(0.82), radius: dp(5), y: dp(2))
            }

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
            }

            if model.totalCount > 0 {
                Text("\(model.totalCount) sources\(model.filteredOutCount > 0 ? " · \(model.filteredOutCount) filtered" : "")")
                    .nuvioText(NuvioTextStyles.metadata)
                    .foregroundStyle(colors.textTertiary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, NuvioTheme.layout.tvSafeHorizontal)
        .padding(.vertical, NuvioTheme.layout.tvSafeVertical)
    }

    private var sourcePicker: some View {
        VStack(alignment: .leading, spacing: 0) {
            sourceToolbar
                .padding(.horizontal, NuvioTheme.spacing.lg)
                .padding(.vertical, NuvioTheme.spacing.md)

            Divider().overlay(colors.borderMuted)

            ScrollView(.vertical, showsIndicators: true) {
                LazyVStack(alignment: .leading, spacing: NuvioTheme.spacing.xl) {
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
                            .frame(maxWidth: .infinity, minHeight: dp(320))
                    } else if model.groups.isEmpty {
                        EmptyStateView(
                            systemImage: "antenna.radiowaves.left.and.right.slash",
                            title: "No sources found",
                            message: emptyMessage
                        )
                        .frame(maxWidth: .infinity, minHeight: dp(320))
                    } else {
                        ForEach(displayedGroups) { group in
                            StreamGroupSection(
                                group: group,
                                model: model,
                                showsHeader: selectedAddon == nil,
                                onSelect: { stream in Task { await play(stream) } }
                            )
                        }
                    }
                }
                .padding(.vertical, NuvioTheme.spacing.lg)
                .padding(.bottom, NuvioTheme.spacing.rail.tailPadding)
            }
            .scrollClipDisabled()
        }
        .background(sourcePickerSurface)
        .clipShape(RoundedRectangle(cornerRadius: NuvioTheme.radii.xl, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: NuvioTheme.radii.xl, style: .continuous)
                .strokeBorder(.white.opacity(0.16), lineWidth: NuvioTheme.strokes.hairline)
        }
        .shadow(color: .black.opacity(0.36), radius: dp(28), x: -dp(6), y: dp(10))
    }

    private var sourceToolbar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: NuvioTheme.spacing.sm) {
                Button { Task { await reload() } } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: NuvioTheme.sizes.icons.sm, weight: .semibold))
                        .frame(width: dp(38), height: dp(38))
                }
                .buttonStyle(NuvioPillButtonStyle(emphasis: .ghost))
                .accessibilityLabel(L10n.text("player.reload"))

                sourceFilter("All", isSelected: selectedAddon == nil) {
                    selectedAddon = nil
                }
                ForEach(model.groups) { group in
                    sourceFilter(group.addonName, isSelected: selectedAddon == group.addonName) {
                        selectedAddon = group.addonName
                    }
                }
            }
            .padding(.horizontal, NuvioTheme.spacing.xxs)
        }
        .focusSection()
    }

    private func sourceFilter(_ title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .nuvioText(NuvioTextStyles.metadata)
                .lineLimit(1)
                .padding(.horizontal, NuvioTheme.spacing.md)
                .frame(height: dp(38))
        }
        .buttonStyle(NuvioPillButtonStyle(emphasis: .secondary, selected: isSelected))
    }

    /// Now that the backdrop is actually visible, the panel has to earn its own contrast: a
    /// blur alone tracks whatever is behind it, and over a bright frame that leaves the rows
    /// competing with the picture. The base coat is what keeps six lines of metadata readable
    /// while the artwork still shows around the panel's edges.
    private var sourcePickerSurface: some View {
        let shape = RoundedRectangle(cornerRadius: NuvioTheme.radii.xl, style: .continuous)
        return ZStack {
            shape.fill(.ultraThinMaterial)
            shape.fill(colors.background.opacity(0.58))
            shape.fill(
                LinearGradient(
                    colors: [colors.glassPanelTop.opacity(0.34), colors.glassPanelBottom.opacity(0.16)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
        }
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

    private func reload() async {
        selectedAddon = nil
        await model.load(request: request, addonStore: addons, settings: settings)
        await autoPlayIfConfigured()
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

        let playback = makePlaybackRequest(stream: stream, url: url)
        let installed = ExternalPlayerLauncher.installed

        // Where the stream opens: internally, in a chosen external app, or ask each time.
        switch settings.player.playerPreference {
        case .internalPlayer:
            router.play(playback)

        case .externalPlayer:
            let preferred = ExternalPlayer(rawValue: settings.player.preferredExternalPlayer)
            if let preferred, installed.contains(preferred) {
                ExternalPlayerLauncher.open(preferred, stream: url, title: request.title)
            } else if !installed.isEmpty {
                // Set to external but no usable choice recorded — ask rather than guess.
                handOff = HandOffRequest(playback: playback)
            } else {
                // Nothing installed: falling back beats refusing to play.
                router.play(playback)
            }

        case .askEveryTime:
            if installed.isEmpty {
                router.play(playback)
            } else {
                handOff = HandOffRequest(playback: playback)
            }
        }
    }

    private func makePlaybackRequest(stream: Stream, url: String) -> PlaybackRequest {
        let preview = library.cachedPreview(contentType: request.contentType, contentId: request.contentId)
        return PlaybackRequest(
            streamURL: url,
            title: request.title,
            subtitleLine: [request.episodeLabel, request.episodeName]
                .compactMap { $0 }.joined(separator: " · ").nilIfBlank,
            streamName: stream.displayName,
            filename: stream.behaviorHints?.filename,
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
            subtitles: model.subtitles,
            sourceRequest: request,
            sourceAddonName: stream.addonName,
            sourceAddonLogo: stream.addonLogo,
            sourceDescription: stream.displayDescription,
            sourceHints: stream.sources ?? [],
            sourceStableKey: stream.stableKey
        )
    }
}

// MARK: - Group

private struct StreamGroupSection: View {
    @Environment(\.nuvioColors) private var colors
    @Environment(AppSettings.self) private var settings

    let group: AddonStreams
    let model: StreamsViewModel
    let showsHeader: Bool
    let onSelect: (Stream) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: NuvioTheme.spacing.md) {
            if showsHeader {
                HStack(spacing: NuvioTheme.spacing.sm) {
                    if settings.streamBadges.showAddonLogo, let logo = group.addonLogo?.nilIfBlank {
                        RemoteImage(url: logo, contentMode: .fit) { Color.clear }
                            .frame(width: NuvioTheme.sizes.icons.md, height: NuvioTheme.sizes.icons.md)
                            .clipShape(RoundedRectangle(cornerRadius: NuvioTheme.radii.xs))
                    }
                    Text(group.addonName)
                        .nuvioText(NuvioTextStyles.cardTitle)
                        .foregroundStyle(colors.textPrimary)
                    Text("\(group.streams.count)")
                        .nuvioText(NuvioTextStyles.metadata)
                        .foregroundStyle(colors.textTertiary)
                }
                .padding(.horizontal, NuvioTheme.components.row.horizontalPadding)
            }

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
    @FocusState private var rowFocused: Bool

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
        // A SwiftUI `Button` in tvOS 26 still gets the platform's opaque light focus plate,
        // even with `.buttonStyle(.plain)`.  That plate is applied *after* our view tree, so
        // it makes the light metadata illegible.  A focusable semantic row keeps Select on the
        // Siri Remote while letting this view own every pixel of its focus treatment.
        HStack(alignment: .top, spacing: NuvioTheme.spacing.md) {
            VStack(alignment: .leading, spacing: dp(3)) {
                HStack(alignment: .firstTextBaseline, spacing: NuvioTheme.spacing.sm) {
                    Text(stream.displayName)
                        .nuvioText(NuvioTextStyles.cardTitle)
                        .foregroundStyle(colors.textPrimary)
                        .lineLimit(1)
                        .multilineTextAlignment(.leading)

                    Spacer(minLength: 0)

                    if let size = sizeLabel {
                        Text(size)
                            .nuvioText(NuvioTextStyles.metadata)
                            .foregroundStyle(colors.textSecondary)
                            .monospacedDigit()
                            .lineLimit(1)
                            .fixedSize()
                    }
                }

                // Whatever the addon chose to say, in full. This is the line that carries the
                // codec, the audio layout, the running time, the seeders and the indexer —
                // clipping it to three lines threw away most of what a viewer compares on.
                if let detail = stream.displayDescription?.nilIfBlank, detail != stream.displayName {
                    Text(detail)
                        .nuvioText(NuvioTextStyles.metadata)
                        .foregroundStyle(colors.textSecondary)
                        .lineLimit(6)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                }

                // The release itself. Two files from one addon can describe themselves
                // identically and still be different cuts; the name is where that shows.
                if let filename = distinctFilename {
                    Label(filename, systemImage: "doc")
                        .nuvioText(NuvioTextStyles.metadata)
                        .foregroundStyle(colors.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                if !undescribedSources.isEmpty {
                    Text(undescribedSources.joined(separator: " · "))
                        .nuvioText(NuvioTextStyles.metadata)
                        .foregroundStyle(colors.textTertiary)
                        .lineLimit(1)
                }

                if settings.streamBadges.placement != .hidden, !visibleBadges.isEmpty {
                    badges
                }
            }

            trailingIcon
        }
        .padding(.horizontal, NuvioTheme.spacing.lg)
        .padding(.vertical, NuvioTheme.spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .focusEffectDisabled()
        .background {
            RoundedRectangle(cornerRadius: NuvioTheme.radii.lg, style: .continuous)
                .fill(rowFocused ? colors.focusBackground.opacity(0.96) : colors.backgroundCard.opacity(0.78))
        }
        .overlay {
            RoundedRectangle(cornerRadius: NuvioTheme.radii.lg, style: .continuous)
                .strokeBorder(
                    rowFocused ? colors.focusRing : .white.opacity(0.10),
                    lineWidth: rowFocused ? NuvioTheme.strokes.focus : NuvioTheme.strokes.hairline
                )
        }
        .scaleEffect(rowFocused ? 1.012 : 1)
        .shadow(color: .black.opacity(rowFocused ? 0.42 : 0.12), radius: rowFocused ? dp(14) : dp(4), y: dp(5))
        .animation(NuvioMotion.focusTween, value: rowFocused)
        .focusable(isPlayable)
        .focused($rowFocused)
        .onTapGesture {
            guard isPlayable else { return }
            action()
        }
        .accessibilityAddTraits(.isButton)
        .opacity(isPlayable ? 1 : NuvioTheme.effects.disabledAlpha)
    }

    // MARK: Size, filename, badges

    /// The number a viewer actually compares between two sources, kept at the trailing edge of
    /// the title so the eye can run down it.
    private var sizeLabel: String? {
        guard settings.streamBadges.showFileSizeBadges, let gb = attributes?.sizeGb,
              !describesSize
        else { return nil }
        return gb >= 1
            ? String(format: "%.1f GB", gb)
            : String(format: "%.0f MB", gb * 1024)
    }

    /// Most addons write the size into their own text, and this column is parsed back out of
    /// exactly that text — printing it twice on one row is noise, not information.
    private var describesSize: Bool {
        let text = (stream.displayDescription ?? "").lowercased()
        return text.contains("gb") || text.contains("mb") || text.contains(" go") || text.contains("gib")
    }

    /// The release name, shown only when it says something the description has not. Two files
    /// from one addon can describe themselves identically and still be different cuts.
    private var distinctFilename: String? {
        guard let filename = stream.behaviorHints?.filename?.nilIfBlank,
              filename != stream.displayName,
              !(stream.displayDescription ?? "").contains(filename)
        else { return nil }
        return filename
    }

    /// Everything the addon already wrote out in words, ready to be matched against.
    /// Trackers the addon has not already named in its own text — the description usually ends
    /// with the indexer it came from, and repeating it underneath says nothing new.
    private var undescribedSources: [String] {
        (stream.sources ?? [])
            .filter { !$0.isEmpty && !isDescribed($0) }
            .prefix(4)
            .map { $0 }
    }

    private var describedText: String {
        [stream.displayName, stream.displayDescription, stream.behaviorHints?.filename]
            .compactMap { $0 }
            .joined(separator: " ")
            .lowercased()
            // Letters and digits only: "2160p" has to survive, "🎧 |" must not get in the way.
            .filter { $0.isLetter || $0.isNumber }
    }

    /// A chip is worth its line only when it tells the viewer something the description did
    /// not. Most addons write "BluRay REMUX · HDR10+ · TrueHD 7.1" into the text themselves,
    /// and repeating each of those as a chip underneath was most of what made a row so tall.
    /// Addons that return a bare name still get the full set, which is where chips earn their
    /// place.
    private func isDescribed(_ text: String) -> Bool {
        // Compound chips are matched part by part. "HDR+DV" never appears verbatim in a
        // description that reads "HDR10+ | DV", yet it tells the viewer nothing new — and it
        // is the last chip that would otherwise survive on a well-described row.
        let parts = text.lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { $0.count >= 2 }
        // A chip made only of two-letter fragments is too weak to rule on.
        guard parts.contains(where: { $0.count >= 3 }) else { return false }
        return parts.allSatisfy { describedText.contains($0) }
    }

    private var attributeBadges: [RowBadge] {
        guard let a = attributes else { return [] }
        var badges: [RowBadge] = []
        if a.resolution != .unknown {
            badges.append(RowBadge(text: a.resolution.displayName, tint: colors.secondary, filled: true))
        }
        if a.quality != .unknown {
            badges.append(RowBadge(text: a.quality.displayName))
        }
        badges += a.visualTags.filter { $0 != .unknown }.prefix(2)
            .map { RowBadge(text: $0.displayName, tint: colors.premium) }
        badges += a.audioTags.filter { $0 != .unknown }.prefix(2)
            .map { RowBadge(text: $0.displayName) }
        if a.encode != .unknown {
            badges.append(RowBadge(text: a.encode.displayName))
        }
        return badges.filter { !isDescribed($0.text) }
    }

    /// The debrid state and the seeder count are not the addon's to describe: one comes from
    /// the debrid account, the other only sometimes appears in the text.
    private var visibleBadges: [RowBadge] {
        var badges = attributeBadges
        if settings.streamBadges.showCacheBadges, let cache, cache.state != .unknown {
            badges.append(RowBadge(
                text: cache.state == .cached ? "Cached" : "Not cached",
                tint: cache.state == .cached ? colors.cached : colors.textTertiary,
                filled: cache.state == .cached
            ))
        }
        if stream.isTorrent {
            badges.append(RowBadge(text: "Torrent", tint: colors.torrent))
        }
        return badges
    }

    private var seederCount: Int? {
        guard settings.streamBadges.showSeederBadges, let seeders = attributes?.seeders,
              !describedSeeders(seeders) else { return nil }
        return seeders
    }

    private func describedSeeders(_ count: Int) -> Bool {
        (stream.displayDescription ?? "").contains("\(count)")
    }

    @ViewBuilder
    private var badges: some View {
        HStack(spacing: NuvioTheme.spacing.sm) {
            ForEach(visibleBadges) { badge in
                NuvioBadge(text: badge.text, tint: badge.tint, filled: badge.filled)
            }
            if let seederCount {
                HStack(spacing: dp(3)) {
                    Image(systemName: "person.2.fill")
                        .font(.system(size: NuvioTheme.sizes.icons.xs))
                    Text("\(seederCount)")
                        .nuvioText(NuvioTextStyles.metadata)
                }
                .foregroundStyle(colors.success)
            }
        }
        .padding(.top, dp(2))
    }

    /// Only the two states a viewer cannot infer: this one is being resolved, or it cannot be
    /// played at all. The play disc that used to sit here said nothing the focus ring does not
    /// already say, on every row, at forty points a time.
    @ViewBuilder
    private var trailingIcon: some View {
        if isResolving {
            ProgressView()
                .progressViewStyle(.circular)
                .tint(colors.secondary)
                .frame(width: dp(28), height: dp(28))
        } else if !isPlayable {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: NuvioTheme.sizes.icons.sm))
                .foregroundStyle(colors.warning)
                .frame(width: dp(28), height: dp(28))
        }
    }
}

/// One chip in a stream row.
private struct RowBadge: Identifiable {
    let text: String
    var tint: Color?
    var filled: Bool = false
    var id: String { text }
}

// MARK: - External player hand-off

/// A resolved stream waiting on the viewer to say where it opens.
struct HandOffRequest: Identifiable {
    let playback: PlaybackRequest
    var id: String { playback.id }
}

/// Port of the Android "play with" chooser. Lists only players that are actually installed, and
/// says plainly when a hand-off would drop request headers the source needs.
struct ExternalPlayerPicker: View {
    @Environment(\.nuvioColors) private var colors
    @Environment(\.dismiss) private var dismiss

    let playback: PlaybackRequest
    let onInternal: () -> Void

    private var installed: [ExternalPlayer] { ExternalPlayerLauncher.installed }
    private var losesHeaders: Bool { !playback.headers.isEmpty }

    var body: some View {
        NuvioScreenBackground {
            VStack(alignment: .leading, spacing: NuvioTheme.components.settings.rowGap) {
                Text("Play with")
                    .nuvioText(NuvioTextStyles.display)
                    .foregroundStyle(colors.textPrimary)

                Text(playback.title)
                    .nuvioText(NuvioTextStyles.bodyCompact)
                    .foregroundStyle(colors.textSecondary)

                SettingsCard(
                    title: "This device",
                    footnote: "AVFoundation covers H.264 and HEVC in MP4 and HLS. It cannot open MKV — use an external player for those."
                ) {
                    SettingsRow(
                        title: "Nuvio player",
                        subtitle: "Resume, progress tracking, addon subtitles and auto-play all work here",
                        systemImage: "play.rectangle.fill",
                        action: onInternal
                    )
                }

                SettingsCard(
                    title: "External players",
                    footnote: losesHeaders
                        ? "This source needs request headers that a hand-off cannot carry, so it will probably fail outside Nuvio. Progress and auto-play also stop at the hand-off."
                        : "Nuvio stops tracking progress once playback moves to another app."
                ) {
                    ForEach(installed) { player in
                        SettingsRow(
                            title: player.displayName,
                            subtitle: player.summary,
                            systemImage: "arrow.up.forward.app",
                            action: {
                                ExternalPlayerLauncher.open(
                                    player, stream: playback.streamURL, title: playback.title
                                )
                                dismiss()
                            }
                        )
                    }
                }

                Button(action: { dismiss() }) {
                    Text("Cancel")
                        .nuvioText(NuvioTextStyles.button)
                        .padding(.horizontal, NuvioTheme.spacing.xl)
                        .frame(height: NuvioTheme.components.buttonHeight)
                }
                .buttonStyle(NuvioPillButtonStyle(emphasis: .secondary))
            }
        }
    }
}
