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
    /// Badges earned from the viewer's imported rules, keyed like `attributes`.
    ///
    /// Matched here rather than in the row because the rules are user-authored regular
    /// expressions and a source list is a hundred rows: compiling and matching per row would
    /// redo the same work on every redraw, including the ones focus changes cause.
    private(set) var ruleBadges: [String: [StreamBadge]] = [:]
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
    /// Debrid links resolved ahead of the viewer choosing, keyed by `Stream.stableKey`.
    private(set) var preparedURLs: [String: String] = [:]

    private let client: StremioClient

    init(client: StremioClient = .shared) {
        self.client = client
    }

    var totalCount: Int { groups.reduce(0) { $0 + $1.streams.count } }

    /// One chip per source asked, with upstream's loading / success / error status.
    private(set) var sourceChips: [SourceChip] = []
    /// Upstream's `isStillFetching`: what spins the refresh chip.
    var isStillFetching: Bool { sourceChips.contains { $0.status == .loading } }
    /// The bounded auto-play wait, counted from the start of the search, has run out. Instant
    /// and unlimited waits are over from the start.
    private(set) var autoPlayWindowElapsed = false
    /// New hashes are out for a debrid cache check. A "nothing suitable" auto-play verdict waits
    /// for the answer, as upstream waits for its `CHECKING` sources.
    var isCheckingCache: Bool { cacheCheckTask != nil }

    /// What every arrival of one load is processed with, fixed when the load starts.
    private struct LoadContext {
        var generation: Int
        var languageTitle: String
        var filterInput: StreamFilterEngine.Input
        /// Compiling is the expensive half of the viewer's badge rules — a pack is up to a few
        /// hundred user-authored regular expressions — so it happens once per load, not per row.
        var badgeFilters: [CompiledStreamBadgeFilter]
        var cacheCredentials: [DebridCredential]
        var installedOrder: [String]
        var settings: AppSettings
    }

    private enum Arrival {
        case addon(Addon, [Stream]?)
        case tmdbId(String?)
        case scraper(InstalledScraper, [LocalScraperResult])
        case autoPlayWindow
        case hardTimeout
        case cancelled
    }

    @ObservationIgnored private var context: LoadContext?
    @ObservationIgnored private var loadGeneration = 0
    @ObservationIgnored private var onEvent: (StreamAutoPlayPolicy.Moment) -> Void = { _ in }
    @ObservationIgnored private var removedBySection: [String: Int] = [:]
    /// Plugin sections in the order they answered, which is the order they list in.
    @ObservationIgnored private var pluginOrder: [String] = []
    @ObservationIgnored private var pluginBuckets: [String: (logo: String?, streams: [Stream])] = [:]
    @ObservationIgnored private var requestedCacheHashes: Set<String> = []
    @ObservationIgnored private var cacheCheckDirty = false
    /// Upstream's `debridPreparationLaunched`: preparation starts once per load, on the first
    /// sources ready for it.
    @ObservationIgnored private var preparationLaunched = false
    @ObservationIgnored private var chipDismissTask: Task<Void, Never>?
    private var cacheCheckTask: Task<Void, Never>?

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

    /// Every source is published the moment it answers, as upstream's repository emits.
    ///
    /// The list used to be held until the slowest addon had answered — or given up, which is
    /// the request's 45-second ceiling — so one addon with nothing for this title kept every
    /// other addon's sources off screen. Scrapers waited for the addons on top of that.
    ///
    /// A refresh starts from an empty list, as upstream's `OnRefresh` does: the list shows the
    /// loading state again until the first source answers. `onEvent` reports each arrival and
    /// each auto-play deadline; `stopsAtHardTimeout` says whether the hard limit should end the
    /// search, which upstream does only while its auto-play overlay is still waiting.
    func load(
        request: StreamRequest,
        addonStore: AddonStore,
        settings: AppSettings,
        forceRefresh: Bool = false,
        autoPlayWindow: Duration? = nil,
        hardTimeout: Duration? = nil,
        stopsAtHardTimeout: @escaping () -> Bool = { false },
        onEvent: @escaping (StreamAutoPlayPolicy.Moment) -> Void = { _ in }
    ) async {
        loadGeneration += 1
        let generation = loadGeneration
        isLoading = true
        autoPlayWindowElapsed = autoPlayWindow == nil
        self.onEvent = onEvent
        groups = []
        cacheStates = [:]
        attributes = [:]
        ruleBadges = [:]
        failedAddons = []
        skippedForIdPrefix = []
        filteredOutCount = 0
        queriedAddonCount = 0
        removedBySection = [:]
        pluginOrder = []
        pluginBuckets = [:]
        requestedCacheHashes = []
        preparationLaunched = false
        chipDismissTask?.cancel()
        let badgeFilters = StreamBadgeMatcher.compile(settings.streamBadges.rules)
        context = LoadContext(
            generation: generation,
            // The show's name rather than the episode's: it is what a release name starts with.
            languageTitle: request.contentName?.nilIfBlank ?? request.title,
            filterInput: settings.streamFilterInput,
            badgeFilters: badgeFilters,
            cacheCredentials: settings.debrid.cacheCheckCredentials,
            installedOrder: addonStore.enabledAddons.map(\.displayName),
            settings: settings
        )
        defer {
            // A newer load owns this now.
            if generation == loadGeneration { isLoading = false }
        }

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
        let scrapers = pluginScrapers.filter { $0.supports(type: request.contentType) }
        // `updateSourceChipsForFetchStart`: addons, then plugin sections under the name they
        // will list with.
        sourceChips = SourceChips.fetchStart(
            names: providers.map(\.addon.displayName) + scrapers.map(pluginLabel(for:))
        )
        guard !providers.isEmpty || !scrapers.isEmpty else { return }

        let allowingCache = !forceRefresh
        let mediaType = ContentType.from(request.contentType) == .series ? "tv" : "movie"
        let tmdbApiKey = settings.tmdb.apiKey
        var answered = 0
        let expected = providers.count + (scrapers.isEmpty ? 0 : 1)
        var scrapersOutstanding = 0

        await withTaskGroup(of: Arrival.self) { group in
            for (addon, videoId) in providers {
                group.addTask { [client] in
                    .addon(addon, await Self.fetchStreams(
                        client: client, addon: addon, request: request, videoId: videoId,
                        allowingCache: allowingCache
                    ))
                }
            }
            // Scrapers are keyed on TMDB ids, not IMDb, so the id has to be translated first.
            if !scrapers.isEmpty {
                group.addTask { .tmdbId(await self.resolveTmdbId(request: request, settings: settings)) }
            }
            if let autoPlayWindow {
                group.addTask { await Self.sleep(autoPlayWindow, then: .autoPlayWindow) }
            }
            if let hardTimeout {
                group.addTask { await Self.sleep(hardTimeout, then: .hardTimeout) }
            }

            for await arrival in group {
                // Superseded, or the screen is gone: what drains from here must not reach
                // auto-play, or leaving mid-search could still start playback.
                guard generation == loadGeneration, !Task.isCancelled else {
                    group.cancelAll()
                    continue
                }
                switch arrival {
                case .addon(let addon, let streams):
                    answered += 1
                    if let streams {
                        absorb(section: addon.displayName, logo: addon.logo, streams: streams)
                    } else {
                        failedAddons.append(addon.displayName)
                    }
                    onEvent(.arrival)
                case .tmdbId(nil):
                    answered += 1
                    failedAddons.append("Plugins (no TMDB id)")
                    onEvent(.arrival)
                case .tmdbId(let tmdbId?):
                    pluginTmdbId = tmdbId
                    scrapersOutstanding = scrapers.count
                    for scraper in scrapers {
                        group.addTask {
                            .scraper(scraper, await PluginRuntime.shared.execute(
                                code: scraper.code,
                                tmdbId: tmdbId,
                                mediaType: mediaType,
                                season: request.season,
                                episode: request.episode,
                                scraperId: scraper.id,
                                tmdbApiKey: tmdbApiKey,
                                allowingCache: allowingCache
                            ))
                        }
                    }
                case .scraper(let scraper, let results):
                    scrapersOutstanding -= 1
                    if scrapersOutstanding == 0 { answered += 1 }
                    absorbPlugin(scraper, results: results)
                    onEvent(.arrival)
                case .autoPlayWindow:
                    autoPlayWindowElapsed = true
                    onEvent(.windowElapsed)
                case .hardTimeout:
                    // Asked before the event, which is what ends auto-play. Upstream cancels the
                    // search here, and leaves the rest marked failed.
                    if stopsAtHardTimeout() { group.cancelAll() }
                    onEvent(.hardTimeout)
                case .cancelled:
                    break
                }
                // Nothing left but the timers, which have no reason to outlive the search.
                if answered == expected { group.cancelAll() }
            }
        }

        guard generation == loadGeneration else { return }
        // The cache check outlives this call; with the screen gone it has no one to tell.
        guard !Task.isCancelled else {
            self.onEvent = { _ in }
            return
        }
        requestCacheCheck()
        await cacheCheckTask?.value
        sourceChips = SourceChips.markingRemainingAsError(sourceChips)
        scheduleErrorChipRemoval()
    }

    nonisolated private static func sleep(_ duration: Duration, then arrival: Arrival) async -> Arrival {
        do {
            try await Task.sleep(for: duration)
            return arrival
        } catch {
            return .cancelled
        }
    }

    /// `scheduleErrorChipRemoval`.
    private func scheduleErrorChipRemoval() {
        guard sourceChips.contains(where: { $0.status == .error }) else { return }
        chipDismissTask?.cancel()
        chipDismissTask = Task { [weak self] in
            try? await Task.sleep(for: SourceChips.errorDismissDelay)
            guard !Task.isCancelled, let self else { return }
            sourceChips = SourceChips.removingErrors(sourceChips)
        }
    }

    /// One addon's answer, or nil when the request failed.
    nonisolated private static func fetchStreams(
        client: StremioClient,
        addon: Addon,
        request: StreamRequest,
        videoId: String,
        allowingCache: Bool
    ) async -> [Stream]? {
        // A refresh bypasses the cache: someone who asked for the list again is asking for
        // *this* list again, and answering from memory is the one response that cannot be what
        // they meant.
        guard let streams = try? await client.fetchStreams(
            addon: addon, type: request.contentType, videoId: videoId,
            allowingCache: allowingCache
        ) else { return nil }
        // An empty answer is not necessarily a miss: some addons publish their links inline on
        // the meta entry instead of implementing `/stream`.
        //
        // Only worth a second request when the addon actually serves meta. Firing it blindly
        // means every addon that legitimately has nothing costs a second round trip — and a full
        // series meta is a large document — which is what made the source list sit and spin.
        guard streams.isEmpty,
              addon.supports(resource: "meta", type: request.contentType)
        else { return streams }
        let inline = try? await client.fetchInlineStreams(
            addon: addon, type: request.contentType, videoId: videoId
        )
        return inline ?? []
    }

    /// Parses, badges and filters one section, then puts it in its place in the list.
    private func absorb(section name: String, logo: String?, streams: [Stream]) {
        guard let context else { return }
        var parsed = attributes
        for stream in streams {
            parsed[stream.stableKey] = StreamAttributeParser.parse(stream, title: context.languageTitle)
        }
        attributes = parsed

        if !context.badgeFilters.isEmpty {
            var matched = ruleBadges
            for stream in streams {
                let badges = StreamBadgeMatcher.badges(
                    for: stream, attributes: parsed[stream.stableKey], filters: context.badgeFilters
                )
                matched[stream.stableKey] = badges.isEmpty ? nil : badges
            }
            ruleBadges = matched
        }

        let kept = StreamFilterEngine.apply(to: streams, attributes: parsed, input: context.filterInput)
        removedBySection[name] = streams.count - kept.count
        filteredOutCount = removedBySection.values.reduce(0, +)
        groups = StreamGroupOrdering.merging(
            AddonStreams(addonName: name, addonLogo: logo, streams: kept),
            into: groups,
            installedOrder: context.installedOrder,
            pluginOrder: pluginOrder
        )
        // Only a source with something on screen succeeds; an empty one stays loading until
        // the search ends, as upstream's never reaches `mergeSourceChipStatuses`.
        if !kept.isEmpty {
            sourceChips = SourceChips.marking(succeeded: [name], in: sourceChips)
        }
        requestCacheCheck()
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

    private func pluginLabel(for scraper: InstalledScraper) -> String {
        groupPluginsByRepository
            ? (pluginRepositoryNames[scraper.repositoryId]?.nilIfBlank ?? scraper.name)
            : scraper.name
    }

    /// One section per scraper, or one per repository when the viewer asked for that — in which
    /// case the section grows as its scrapers answer.
    private func absorbPlugin(_ scraper: InstalledScraper, results: [LocalScraperResult]) {
        guard !results.isEmpty else { return }
        let label = pluginLabel(for: scraper)
        var bucket = pluginBuckets[label] ?? (scraper.logo, [])
        for (index, result) in results.enumerated() {
            bucket.streams.append(result.asStream(
                sourceName: label,
                scraperId: scraper.id,
                // Named only when the section is a repository, for the heading over its rows.
                scraperName: label == scraper.name ? nil : scraper.name,
                occurrence: index
            ))
        }
        pluginBuckets[label] = bucket
        if !pluginOrder.contains(label) { pluginOrder.append(label) }
        // Plugin results go through the same filters as addon streams.
        absorb(section: label, logo: bucket.logo, streams: PluginProviderHeading.grouped(bucket.streams))
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

    /// Instant availability for the torrent sources on screen, asked as they arrive.
    ///
    /// Arrivals come in bursts, so a request already out is not doubled: it goes round again
    /// for whatever arrived meanwhile, and only hashes not yet asked are sent.
    private func requestCacheCheck() {
        guard let credentials = context?.cacheCredentials, !credentials.isEmpty else { return }
        cacheCheckDirty = true
        guard cacheCheckTask == nil else { return }
        cacheCheckTask = Task { [weak self] in
            while let self, self.cacheCheckDirty {
                self.cacheCheckDirty = false
                await self.checkNewHashes(credentials: credentials)
            }
            self?.cacheCheckTask = nil
            self?.launchPreparationIfReady()
            self?.onEvent(.arrival)
        }
    }

    private func checkNewHashes(credentials: [DebridCredential]) async {
        let hashes = Set(orderedStreams.compactMap { $0.effectiveInfoHash?.lowercased() })
            .subtracting(requestedCacheHashes)
        guard !hashes.isEmpty else { return }
        requestedCacheHashes.formUnion(hashes)
        let results = await DebridClient.shared.checkCache(
            infoHashes: Array(hashes), credentials: credentials
        )
        cacheStates.merge(results) { _, new in new }
    }

    /// Upstream's `launchDirectDebridPreparationIfNeeded`: the first time sources ready for it
    /// are on screen — a cached torrent, here — preparation starts, once, alongside the search.
    private func launchPreparationIfReady() {
        guard !preparationLaunched, let settings = context?.settings else { return }
        let ready = orderedStreams.contains {
            $0.streamURL() == nil && $0.isTorrent && cacheState(for: $0)?.state == .cached
        }
        guard ready else { return }
        preparationLaunched = true
        Task { await prepareInstantPlayback(settings: settings) }
    }

    func cacheState(for stream: Stream) -> DebridCacheResult? {
        guard let hash = stream.effectiveInfoHash?.lowercased() else { return nil }
        return cacheStates[hash]
    }

    /// Resolves the first few cached torrents through debrid before the viewer picks one, so the
    /// gap between pressing Play and the picture starting is spent here instead.
    ///
    /// The reader for `instant_playback_preparation_limit`, a stepper in Debrid settings that
    /// nothing consumed. Only **cached** sources are prepared: asking debrid for an uncached
    /// torrent starts a download on the account, which is not something to do speculatively on
    /// the viewer's behalf.
    func prepareInstantPlayback(settings: AppSettings) async {
        let limit = settings.debrid.instantPlaybackPreparationLimit
        guard limit > 0, settings.debrid.enabled,
              let credential = settings.debrid.activeResolver
        else { return }

        let candidates = orderedStreams
            .filter { $0.streamURL() == nil && $0.isTorrent }
            .filter { cacheState(for: $0)?.state == .cached }
            .filter { preparedURLs[$0.stableKey] == nil }
            .prefix(limit)
        guard !candidates.isEmpty else { return }

        await withTaskGroup(of: (String, String?).self) { group in
            for stream in candidates {
                guard let infoHash = stream.effectiveInfoHash else { continue }
                let key = stream.stableKey
                let magnet = stream.torrentMagnetURI()
                let fileIndex = stream.fileIdx
                let filename = stream.behaviorHints?.filename
                group.addTask {
                    let url = try? await DebridClient.shared.resolvePlayableLink(
                        infoHash: infoHash,
                        magnetURI: magnet,
                        fileIndex: fileIndex,
                        preferredFileName: filename,
                        credential: credential
                    )
                    return (key, url)
                }
            }
            for await (key, url) in group {
                guard let url else { continue }
                preparedURLs[key] = url
            }
        }
    }

    /// Returns a directly playable URL, resolving through debrid when the source is a torrent.
    func playableURL(for stream: Stream, settings: AppSettings) async -> Result<String, Error> {
        if let direct = stream.streamURL() {
            return .success(direct)
        }
        if let prepared = preparedURLs[stream.stableKey] {
            return .success(prepared)
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
    @Environment(PartyStore.self) private var party

    let request: StreamRequest

    @State private var model = StreamsViewModel()
    /// Set by any start of playback, the viewer's own included: a source picked by hand while
    /// the search runs must not be followed by auto-play's pick.
    @State private var didAutoPlay = false
    @State private var autoPlayRelease: NextEpisodeSourceMatch.Release?
    /// Upstream's direct auto-play flow: while auto-play may still pick, the screen shows its
    /// loading cover instead of the list, and the list appears only when auto-play gives up.
    @State private var autoPlayFlowActive = false
    /// `directAutoPlayModeInitializedForSession`: the flow is decided once per screen.
    @State private var autoPlayFlowDecided = false
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
            if autoPlayFlowActive {
                PlayerLoadingOverlay(
                    title: request.title,
                    backdrop: request.backdrop ?? request.poster,
                    detail: settings.player.showPlayerLoadingStatus
                        ? L10n.text("streams.finding_source", fallback: "Finding stream source")
                        : nil
                )
                .transition(.opacity)
            } else {
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
            // Read once — it is consumed on read, and every auto-play pass needs to know whether
            // the screen was reached by auto-advance.
            autoPlayRelease = PlaybackSessionStore.shared.consumeRelease(for: request.videoId)
            decideAutoPlayFlow()
            // The last link needs no list, so it does not wait for one. The search still runs:
            // it is what the viewer comes back to.
            playReusedLinkIfAvailable()
            await search(forceRefresh: false)
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

            resumePill

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

                    if let shared = partySharedStream {
                        partyStreamRow(shared)
                    }

                    if model.isLoading && model.groups.isEmpty {
                        NuvioLoadingView(message: L10n.text("streams.searching", fallback: "Searching your addons for sources…"))
                            .frame(maxWidth: .infinity, minHeight: dp(320))
                    } else if model.groups.isEmpty {
                        EmptyStateView(
                            systemImage: "antenna.radiowaves.left.and.right.slash",
                            title: L10n.text("streams.none_found", fallback: "No sources found"),
                            message: emptyMessage
                        )
                        .frame(maxWidth: .infinity, minHeight: dp(320))
                    } else {
                        ForEach(displayedGroups) { group in
                            StreamGroupSection(
                                group: group,
                                model: model,
                                showsHeader: selectedAddon == nil,
                                partySource: partySource,
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
                    // Upstream's `RefreshFilterChip` spins while any source is still loading.
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: NuvioTheme.sizes.icons.sm, weight: .semibold))
                        .symbolEffect(.rotate, options: .repeat(.continuous), isActive: model.isStillFetching)
                        .frame(width: dp(38), height: dp(38))
                }
                .buttonStyle(NuvioPillButtonStyle(emphasis: .ghost))
                .accessibilityLabel(L10n.text("player.reload"))

                sourceFilter("All", isSelected: selectedAddon == nil) {
                    selectedAddon = nil
                }
                // Every source asked has a chip from the start, in upstream's order: the ones
                // on screen in list order, then the ones still loading. Only a chip with
                // sources behind it filters.
                let available = model.groups.map(\.addonName)
                ForEach(SourceChips.displayOrder(available: available, chips: model.sourceChips), id: \.self) { name in
                    let status = model.sourceChips.first { $0.name == name }?.status ?? .success
                    let selectable = available.contains(name) && status == .success
                    SourceStatusChip(
                        title: name,
                        status: status,
                        isSelected: selectedAddon == name
                    ) {
                        if selectable { selectedAddon = name }
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

    // MARK: The party's source

    /// What the party is watching, when what it is watching is this.
    private var partyMediaKey: String {
        PartyMedia.key(
            type: request.contentType, id: request.contentId,
            season: request.season, episode: request.episode
        )
    }

    /// The release the party is on, for marking it in the list below.
    private var partySource: PartySource? {
        guard let active = party.party, active.media.key == partyMediaKey else { return nil }
        return active.media.source
    }

    /// The host's own resolved link, when they shared one.
    ///
    /// Not offered to the host themselves — they are already the one playing it — and only for
    /// the title the party is on, because a URL belongs to one file.
    private var partySharedStream: PartyStream? {
        guard let active = party.party, !active.isHost,
              let shared = party.sharedStream, shared.mediaKey == partyMediaKey
        else { return nil }
        return shared
    }

    private var partyHostName: String {
        party.party.flatMap { $0.member($0.hostMemberId)?.displayName }
            ?? L10n.text("party.someone", fallback: "Someone")
    }

    /// Playing the host's link rather than one of our own sources.
    ///
    /// It is deliberately a row of its own above the list, not a source mixed into it: it is the
    /// host's debrid account the stream comes through, and that is worth choosing rather than
    /// landing on.
    private func partyStreamRow(_ shared: PartyStream) -> some View {
        Button(action: { play(shared: shared) }) {
            HStack(spacing: NuvioTheme.spacing.md) {
                Image(systemName: "person.2.wave.2.fill")
                    .foregroundStyle(colors.secondary)
                VStack(alignment: .leading, spacing: NuvioTheme.spacing.xxs) {
                    Text(L10n.format(
                        "party.shared_by", fallback: "Shared by %@", partyHostName
                    ))
                    .nuvioText(NuvioTextStyles.cardTitle)
                    .foregroundStyle(colors.textPrimary)
                    if let name = shared.name?.nilIfBlank ?? shared.filename?.nilIfBlank {
                        Text(name)
                            .nuvioText(NuvioTextStyles.metadata)
                            .foregroundStyle(colors.textSecondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(NuvioTheme.spacing.lg)
            .contentShape(Rectangle())
        }
        .buttonStyle(NuvioRowButtonStyle(cornerRadius: NuvioTheme.radii.lg))
        .padding(.horizontal, NuvioTheme.components.row.horizontalPadding)
    }

    /// Opens the host's link directly. Already resolved by the device that shared it, so it does
    /// not go back through the debrid round the list's own rows take.
    private func play(shared: PartyStream) {
        didAutoPlay = true
        router.play(
            PlaybackRequest(
                streamURL: shared.url,
                title: request.title,
                subtitleLine: [request.episodeLabel, request.episodeName]
                    .compactMap { $0 }.joined(separator: " · ").nilIfBlank,
                streamName: shared.name,
                filename: shared.filename?.nilIfBlank
                    ?? NextEpisodeSourceMatch.filenameFromURL(shared.url),
                headers: shared.headers,
                contentId: request.contentId,
                contentType: request.contentType,
                videoId: request.videoId,
                season: request.season,
                episode: request.episode,
                poster: request.poster,
                backdrop: request.backdrop,
                logo: request.logo,
                startFromBeginning: false,
                preview: library.cachedPreview(
                    contentType: request.contentType, contentId: request.contentId
                ),
                nextUp: nextUpRequest,
                imdbId: request.imdbId,
                subtitles: model.subtitles,
                sourceRequest: request,
                sourceAddonName: shared.addonName,
                sourceAddonLogo: shared.addonLogo,
                sourceDescription: shared.description,
                sourceBingeGroup: shared.bingeGroup
            )
        )
    }

    /// How far into *this* episode the viewer already is.
    ///
    /// Keyed on `videoId` rather than `contentId`, so a series shows the episode's own progress
    /// and not the series'. Drawn only while there is something to resume: a finished title has
    /// no resume point and an unstarted one has none yet, and a bar pinned at either end says
    /// nothing while taking a line of a panel that is short of them.
    @ViewBuilder
    private var resumePill: some View {
        if let progress = library.progress(forVideoId: request.videoId),
           progress.fraction > 0, progress.fraction < 1 {
            VStack(alignment: .leading, spacing: NuvioTheme.spacing.xs) {
                WatchProgressBar(fraction: progress.fraction)
                Text(progress.remainingLabel)
                    .nuvioText(NuvioTextStyles.metadata)
                    .foregroundStyle(colors.textSecondary)
            }
            .frame(maxWidth: dp(420))
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

    /// Upstream's source and selection rules for auto-play, with the names this screen lists
    /// streams under: an addon by its display name, a plugin by its scraper's.
    private var autoPlayScope: StreamFilterEngine.AutoPlayScope {
        .current(settings: settings, addons: addons)
    }

    /// `stream_reuse_last_link_enabled`: the link this title last played from, within the
    /// window, goes first — before any ranking, as upstream orders it, and before the search.
    private func playReusedLinkIfAvailable() {
        guard !didAutoPlay, settings.player.reuseLastLinkEnabled,
              let cached = LastStreamLinkStore.valid(
                  contentType: request.contentType,
                  videoId: request.videoId,
                  maxAgeHours: settings.player.reuseLastLinkCacheHours
              ) else { return }
        didAutoPlay = true
        Task {
            await play(
                Self.stream(reusing: cached), sourceStableKey: cached.sourceStableKey,
                autoSelected: true, fromLinkCache: true
            )
        }
    }

    /// `shouldUseDirectAutoPlayFlow`, decided once: any auto-play mode, or — with auto-play off —
    /// a release to continue from the previous episode. Regex auto-play without a usable pattern
    /// turns the whole session's auto-play off, as upstream does.
    private func decideAutoPlayFlow() {
        guard !autoPlayFlowDecided else { return }
        autoPlayFlowDecided = true
        var active = settings.player.streamAutoPlayMode != .off
        if !active, settings.player.reuseBingeGroup, autoPlayRelease != nil {
            active = true
        }
        if settings.player.streamAutoPlayMode == .matchRegex,
           !StreamAutoPlayPolicy.isRegexSelectionConfigured(settings.player.streamAutoPlayRegex) {
            active = false
            didAutoPlay = true
        }
        autoPlayFlowActive = active
    }

    /// Runs the search and lets auto-play look at each answer as it lands, on upstream's clock:
    /// the bounded wait and the hard limit both count from the start of the search.
    private func search(forceRefresh: Bool) async {
        let timeout = settings.player.streamAutoPlayTimeoutSeconds
        let bounded = StreamAutoPlayPolicy.isBounded(timeout)
        let window: Duration = bounded ? .seconds(timeout) : .zero
        await model.load(
            request: request,
            addonStore: addons,
            settings: settings,
            forceRefresh: forceRefresh,
            autoPlayWindow: bounded ? window : nil,
            hardTimeout: autoPlayFlowActive ? window + StreamAutoPlayPolicy.hardTimeout : nil,
            stopsAtHardTimeout: { autoPlayFlowActive && !didAutoPlay },
            onEvent: { considerAutoPlay(at: $0) }
        )
        guard !Task.isCancelled else { return }
        considerAutoPlay(at: .allAnswered)
    }

    private func considerAutoPlay(at moment: StreamAutoPlayPolicy.Moment) {
        guard !didAutoPlay else { return }

        // Arrived here by auto-advance: the release that was playing is almost always the right
        // one for the next episode — same encode, same audio, same subtitle timing. Trying it
        // first is what `stream_auto_play_prefer_bingegroup_next_episode` asks for, and it
        // applies even when general auto-play is off, which is the point of the pair. An exact
        // match needs no waiting, so it is tried on every answer.
        if settings.player.reuseBingeGroup, let release = autoPlayRelease,
           let match = NextEpisodeSourceMatch.find(
               in: model.orderedStreams,
               release: release,
               season: request.season,
               episode: request.episode
           ) {
            didAutoPlay = true
            Task { await play(match.stream, autoSelected: true) }
            return
        }

        let step = StreamAutoPlayPolicy.step(
            at: moment,
            timeout: settings.player.streamAutoPlayTimeoutSeconds,
            windowElapsed: model.autoPlayWindowElapsed,
            hasStreams: model.totalCount > 0,
            cacheCheckPending: model.isCheckingCache,
            directFlow: autoPlayFlowActive
        )
        if step.select, let candidate = autoPlayCandidate() {
            didAutoPlay = true
            Task { await play(candidate, autoSelected: true) }
            return
        }
        if step.giveUpIfNoMatch {
            // Nothing suitable: auto-play is over for this screen, and the list is shown.
            didAutoPlay = true
            withAnimation(NuvioMotion.quickTween) { autoPlayFlowActive = false }
        }
    }

    private func autoPlayCandidate() -> Stream? {
        guard settings.player.streamAutoPlayMode != .off else { return nil }
        // The chain reached an episode that release does not cover. Falling back to the ordinary
        // auto-play choice is a preference, because the alternative — stopping on the picker —
        // is what some viewers want rather than a different encode mid-season.
        guard autoPlayRelease == nil || settings.player.autoPlayNextEpisodeFallbackEnabled else { return nil }
        return StreamFilterEngine.autoPlayCandidate(
            from: model.orderedStreams,
            attributes: model.attributes,
            mode: settings.player.streamAutoPlayMode,
            scope: autoPlayScope,
            regex: settings.player.streamAutoPlayRegex,
            preferredQuality: settings.player.autoPlayPreferredQuality,
            cacheStates: model.cacheStates
        )
    }

    /// Upstream's `OnRefresh`: back to "All", the loading state, and every chip loading again.
    private func reload() async {
        selectedAddon = nil
        await search(forceRefresh: true)
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

    /// - Parameters:
    ///   - sourceStableKey: the row a reused link was first chosen from, so the player's Sources
    ///     panel marks that row rather than the stand-in built for the link.
    ///   - autoSelected: started by the screen itself rather than picked by the viewer, which is
    ///     what lets the player fall back to the next match when this source fails.
    ///   - fromLinkCache: the reused last link, which a failed fallback chain forgets.
    private func play(
        _ stream: Stream,
        sourceStableKey: String? = nil,
        autoSelected: Bool = false,
        fromLinkCache: Bool = false
    ) async {
        didAutoPlay = true
        // `OnAutoPlayConsumed`: whatever happens next, coming back here finds the list.
        defer { autoPlayFlowActive = false }
        // Upstream resolves such a stream in-app; their builds without in-app YouTube playback
        // open the watch page instead, which is the only path tvOS has (see `TrailerLauncher`).
        if let youTubeId = stream.youTubeOnlyId {
            TrailerLauncher.open(youTubeId: youTubeId)
            return
        }
        // An auto-selected stream whose debrid result cannot be resolved falls back to the next
        // match here, before the player exists. Each failure replaces the last one shown, so only
        // the last is left if none resolves.
        let fallsBack = autoSelected && settings.player.streamAutoPlayFallbackActive
        let run = await SourceFallback.resolve(
            first: stream,
            maxSources: fallsBack ? settings.player.streamAutoPlayFallbackMaxSources : 0,
            resolve: { candidate -> String? in
                guard case .success(let url) = await model.playableURL(for: candidate, settings: settings) else { return nil }
                return url
            },
            next: { failed, triedKeys in
                SourceFallback.nextCandidate(
                    from: model.orderedStreams,
                    triedKeys: triedKeys,
                    failedAddonName: failed.addonName,
                    failedInfoHash: failed.effectiveInfoHash
                ) { untried in
                    StreamFilterEngine.autoPlayCandidate(
                        from: untried,
                        attributes: model.attributes,
                        mode: settings.player.streamAutoPlayMode,
                        scope: autoPlayScope,
                        regex: settings.player.streamAutoPlayRegex,
                        preferredQuality: settings.player.autoPlayPreferredQuality,
                        cacheStates: model.cacheStates
                    )
                }
            }
        )
        guard let resolved = run.resolved else { return }
        let stream = resolved.stream
        let url = resolved.link

        var playback = makePlaybackRequest(stream: stream, url: url)
        if let sourceStableKey, run.attempts == 0 { playback.sourceStableKey = sourceStableKey }
        if autoSelected {
            playback.autoSelection = SourceFallbackState(
                attempts: run.attempts,
                triedKeys: run.triedKeys,
                fromLinkCache: fromLinkCache,
                currentInfoHash: stream.effectiveInfoHash
            )
        }
        let installed = ExternalPlayerLauncher.installed

        // Where the stream opens: internally, in a chosen external app, or ask each time.
        switch settings.player.playerPreference {
        case .internalPlayer:
            router.play(playback)

        case .externalPlayer:
            let preferred = ExternalPlayer(rawValue: settings.player.preferredExternalPlayer)
            if let preferred, installed.contains(preferred) {
                ExternalPlayerLauncher.open(
                    preferred, stream: url, title: request.title,
                    subtitleURL: forwardedSubtitleURL
                )
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

    /// The addon subtitle track to hand to an external player, when the viewer asked for that.
    ///
    /// Their preferred language if one of the tracks matches it, otherwise the first — the same
    /// order the internal player auto-selects in. A hand-off carries one track, so this picks it
    /// rather than leaving the external player with none.
    private var forwardedSubtitleURL: String? {
        guard settings.player.externalPlayerForwardSubtitles else { return nil }
        let ordered = SubtitleSelector.order(
            model.subtitles,
            preferred: settings.player.subtitlePreferredLanguage,
            secondary: settings.player.subtitleSecondaryLanguage,
            onlyPreferred: false
        )
        return ordered.first?.url.nilIfBlank
    }

    /// A stand-in row for a reused link: the resolved URL and everything the player shows about
    /// the source, as it was when it last played.
    static func stream(reusing link: LastStreamLink) -> Stream {
        Stream(
            name: link.streamName,
            description: link.description,
            url: link.url,
            behaviorHints: StreamBehaviorHints(
                bingeGroup: link.bingeGroup,
                proxyHeaders: link.headers.isEmpty ? nil : ProxyHeaders(request: link.headers),
                filename: link.filename
            ),
            addonName: link.addonName ?? "",
            addonLogo: link.addonLogo
        )
    }

    private func makePlaybackRequest(stream: Stream, url: String) -> PlaybackRequest {
        let preview = library.cachedPreview(contentType: request.contentType, contentId: request.contentId)
        return PlaybackRequest(
            streamURL: url,
            title: request.title,
            subtitleLine: [request.episodeLabel, request.episodeName]
                .compactMap { $0 }.joined(separator: " · ").nilIfBlank,
            streamName: stream.displayName,
            // The addon's hint when it sent one, otherwise read off the *resolved* URL — which is
            // where a debrid link carries it, and those are most of what a viewer plays. It fills
            // the player's File row and is what the next episode's source list matches against.
            filename: stream.behaviorHints?.filename?.nilIfBlank
                ?? NextEpisodeSourceMatch.filenameFromURL(url),
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
            sourceStableKey: stream.stableKey,
            sourceBingeGroup: stream.behaviorHints?.bingeGroup
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
    /// The release the party is on, so the row carrying it can say so.
    let partySource: PartySource?
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
                ForEach(Array(group.streams.enumerated()), id: \.element.id) { index, stream in
                    if let heading = PluginProviderHeading.heading(
                        for: stream, after: index > 0 ? group.streams[index - 1] : nil
                    ) {
                        Text(heading)
                            .nuvioText(NuvioTextStyles.metadata)
                            .foregroundStyle(colors.textSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.leading, NuvioTheme.spacing.lg)
                            .padding(.top, index > 0 ? NuvioTheme.spacing.sm : 0)
                    }
                    StreamRow(
                        stream: stream,
                        attributes: model.attributes[stream.stableKey],
                        ruleBadges: model.ruleBadges[stream.stableKey] ?? [],
                        cache: model.cacheState(for: stream),
                        isResolving: model.resolvingKey == stream.stableKey,
                        isPartySource: partySource?.matches(stream) ?? false,
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
    /// Badges from the viewer's imported rules. Already matched — the row only draws them.
    let ruleBadges: [StreamBadge]
    let cache: DebridCacheResult?
    let isResolving: Bool
    /// Whether this is the file the party is watching. Marked rather than reordered: the list is
    /// still the viewer's own, in their own order.
    let isPartySource: Bool
    let action: () -> Void

    /// The template's output, when this row is one debrid will resolve.
    ///
    /// Only those rows: a direct HTTP source from an addon is already labelled the way that
    /// addon meant, and rewriting it with a template written for debrid results would replace
    /// information with a guess. Android draws the same line.
    private var formatted: DebridStreamFormatter.Rendered? {
        guard stream.effectiveInfoHash != nil, settings.debrid.canResolvePlayableLinks else {
            return nil
        }
        let rendered = DebridStreamFormatter.render(
            stream: stream,
            attributes: attributes,
            service: cache?.provider ?? settings.debrid.activeResolver?.provider,
            // `nil` while the check is still in flight, so `service.cached` is absent rather
            // than false and a template does not flash L10n.text("streams.not_ready", fallback: "Not Ready") before the answer arrives.
            isCached: cache.flatMap { result in
                switch result.state {
                case .cached: return true
                case .notCached: return false
                case .checking, .unknown: return nil
                }
            },
            templates: settings.debrid.streamTemplates.resolved
        )
        return rendered.isEmpty ? nil : rendered
    }

    /// A torrent is actionable when debrid can resolve it, or when it already has an HTTP URL.
    private var isPlayable: Bool {
        if stream.streamURL() != nil { return true }
        if stream.youTubeOnlyId != nil { return TrailerLauncher.isAvailable }
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
                    Text(formatted?.name.nilIfBlank ?? stream.displayName)
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
                if let detail = formatted?.description.nilIfBlank
                    ?? stream.displayDescription?.nilIfBlank, detail != stream.displayName {
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

                if settings.streamBadges.placement != .hidden,
                   !visibleBadges.isEmpty || !ruleBadges.isEmpty {
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
        // A pack that names Atmos and an app chip that says Atmos are the same fact twice. The
        // imported one wins, because the viewer asked for it by name.
        let claimed = Set(ruleBadges.map { $0.name.lowercased() })
        return badges.filter { !isDescribed($0.text) && !claimed.contains($0.text.lowercased()) }
    }

    /// The debrid state and the seeder count are not the addon's to describe: one comes from
    /// the debrid account, the other only sometimes appears in the text.
    private var visibleBadges: [RowBadge] {
        var badges = attributeBadges
        if settings.streamBadges.showCacheBadges, let cache, cache.state != .unknown {
            badges.append(RowBadge(
                text: cache.state == .cached ? "Cached" : L10n.text("streams.not_cached", fallback: "Not cached"),
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
            if isPartySource {
                NuvioBadge(
                    text: L10n.text("party.source", fallback: "Party's source"),
                    tint: colors.secondary,
                    filled: true
                )
            }
            // Imported badges lead: they are the ones the viewer chose to see.
            ForEach(Array(ruleBadges.enumerated()), id: \.offset) { _, badge in
                StreamRuleBadgeChip(badge: badge)
            }
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
    @Environment(AppSettings.self) private var settings

    let playback: PlaybackRequest
    let onInternal: () -> Void

    private var installed: [ExternalPlayer] { ExternalPlayerLauncher.installed }
    private var forwardsSubtitles: Bool { settings.player.externalPlayerForwardSubtitles }
    private var losesHeaders: Bool { !playback.headers.isEmpty }

    var body: some View {
        NuvioScreenBackground {
            VStack(alignment: .leading, spacing: NuvioTheme.components.settings.rowGap) {
                Text(L10n.text("streams.play_with", fallback: "Play with"))
                    .nuvioText(NuvioTextStyles.display)
                    .foregroundStyle(colors.textPrimary)

                Text(playback.title)
                    .nuvioText(NuvioTextStyles.bodyCompact)
                    .foregroundStyle(colors.textSecondary)

                SettingsCard(
                    title: L10n.text("streams.this_device", fallback: "This device"),
                    footnote: "AVFoundation covers H.264 and HEVC in MP4 and HLS. It cannot open MKV — use an external player for those."
                ) {
                    SettingsRow(
                        title: L10n.text("streams.nuvio_player", fallback: "Nuvio player"),
                        subtitle: "Resume, progress tracking, addon subtitles and auto-play all work here",
                        systemImage: "play.rectangle.fill",
                        action: onInternal
                    )
                }

                SettingsCard(
                    title: L10n.text("streams.external_players", fallback: "External players"),
                    footnote: losesHeaders
                        ? L10n.text("streams.handoff_headers_warning", fallback: "This source needs request headers that a hand-off cannot carry, so it will probably fail outside Nuvio. Progress and auto-play also stop at the hand-off.")
                        : L10n.text("streams.handoff_progress_warning", fallback: "Nuvio stops tracking progress once playback moves to another app.")
                ) {
                    ForEach(installed) { player in
                        SettingsRow(
                            title: player.displayName,
                            subtitle: player.summary,
                            systemImage: "arrow.up.forward.app",
                            action: {
                                ExternalPlayerLauncher.open(
                                    player,
                                    stream: playback.streamURL,
                                    title: playback.title,
                                    subtitleURL: forwardsSubtitles ? playback.subtitles.first?.url : nil
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
