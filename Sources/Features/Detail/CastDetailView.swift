import SwiftUI
import Observation

/// Port of the cast detail screen: a person's photo and biography, plus everything they have
/// appeared in as a browsable rail. Backed entirely by TMDB, so it needs an API key.
struct CastDetailView: View {
    @Environment(\.nuvioColors) private var colors
    @Environment(AppSettings.self) private var settings
    @Environment(Router.self) private var router

    let request: CastRequest

    @State private var model = CastDetailViewModel()

    var body: some View {
        NuvioScreenBackground {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: NuvioTheme.spacing.xxl) {
                    header

                    if model.isLoading && model.profile == nil {
                        NuvioLoadingView()
                            .frame(height: dp(200))
                    } else if let error = model.error {
                        ErrorStateView(message: error) {
                            Task { await model.load(request: request, settings: settings) }
                        }
                        .frame(height: dp(280))
                    } else if let profile = model.profile {
                        biography(profile)

                        if !profile.credits.isEmpty {
                            CatalogRowView(
                                title: "Filmography",
                                subtitle: "\(profile.credits.count) titles",
                                items: profile.credits,
                                showsSeeAll: false,
                                onSelect: { router.openDetail($0) }
                            )
                            // The rail draws its own horizontal inset; the screen already has one.
                            .padding(.horizontal, -NuvioTheme.components.row.horizontalPadding)
                        }
                    }
                }
                .padding(.bottom, NuvioTheme.spacing.rail.tailPadding)
            }
            .scrollClipDisabled()
        }
        .task { await model.load(request: request, settings: settings) }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: NuvioTheme.spacing.xl) {
            RemoteImage(url: model.profile?.photo ?? request.photo, contentMode: .fill) {
                ZStack {
                    colors.backgroundCard
                    Image(systemName: "person.fill")
                        .font(.system(size: NuvioTheme.sizes.icons.xl))
                        .foregroundStyle(colors.textTertiary)
                }
            }
            .frame(width: dp(180), height: dp(240))
            .clipShape(RoundedRectangle(cornerRadius: NuvioTheme.radii.lg, style: .continuous))

            VStack(alignment: .leading, spacing: NuvioTheme.spacing.sm) {
                Text(model.profile?.name ?? request.name)
                    .nuvioText(NuvioTextStyles.display)
                    .foregroundStyle(colors.textPrimary)
                    .lineLimit(2)

                if !factTokens.isEmpty {
                    Text(factTokens.joined(separator: "  •  "))
                        .nuvioText(NuvioTextStyles.metadata)
                        .foregroundStyle(colors.textSecondary)
                }
            }

            Spacer(minLength: 0)
        }
    }

    private var factTokens: [String] {
        guard let profile = model.profile else { return [] }
        var tokens: [String] = []
        if let department = profile.knownFor { tokens.append(department) }
        if let birthday = profile.birthday {
            let born = formatted(birthday)
            tokens.append(profile.deathday == nil ? "Born \(born)" : born)
        }
        if let deathday = profile.deathday { tokens.append("Died \(formatted(deathday))") }
        if let place = profile.placeOfBirth { tokens.append(place) }
        return tokens
    }

    private func formatted(_ raw: String) -> String {
        guard let date = VideoDateParser.parse(raw) else { return raw }
        return DateFormatter.nuvioMediumDate.string(from: date)
    }

    @ViewBuilder
    private func biography(_ profile: TMDBClient.PersonProfile) -> some View {
        if let biography = profile.biography {
            VStack(alignment: .leading, spacing: NuvioTheme.spacing.sm) {
                Text("Biography")
                    .nuvioText(NuvioTextStyles.sectionTitle)
                    .foregroundStyle(colors.textPrimary)
                Text(biography)
                    .nuvioText(NuvioTextStyles.bodyCompact)
                    .foregroundStyle(colors.textSecondary)
                    .lineLimit(8)
                    .frame(maxWidth: dp(900), alignment: .leading)
            }
        }
    }
}

@Observable
@MainActor
final class CastDetailViewModel {
    private(set) var profile: TMDBClient.PersonProfile?
    private(set) var isLoading = true
    private(set) var error: String?

    func load(request: CastRequest, settings: AppSettings) async {
        guard profile == nil else { return }
        isLoading = true
        error = nil
        defer { isLoading = false }

        guard !settings.tmdb.apiKey.isEmpty else {
            error = "Cast details come from TMDB — add an API key in Metadata settings."
            return
        }
        guard let loaded = await TMDBClient.shared.person(
            id: request.tmdbId,
            apiKey: settings.tmdb.apiKey,
            language: settings.tmdb.language
        ) else {
            error = "TMDB had nothing for this person."
            return
        }
        profile = loaded
    }
}

// MARK: - Entity browse

/// Port of the TMDB network / studio / genre listings reachable from the detail screen.
struct TMDBBrowseView: View {
    @Environment(\.nuvioColors) private var colors
    @Environment(\.posterMetrics) private var metrics
    @Environment(AppSettings.self) private var settings
    @Environment(Router.self) private var router

    let request: TMDBBrowseRequest

    @State private var model = TMDBBrowseViewModel()

    private var columns: [GridItem] { metrics.gridColumns() }

    var body: some View {
        NuvioScreenBackground {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: NuvioTheme.spacing.xl) {
                    header

                    if model.isLoading && model.items.isEmpty {
                        PosterSkeletonRow(showsTitle: false)
                    } else if model.items.isEmpty {
                        EmptyStateView(
                            systemImage: "building.2",
                            title: "Nothing here",
                            message: model.error ?? "TMDB returned no titles for this."
                        )
                        .frame(height: dp(320))
                    } else {
                        LazyVGrid(columns: columns, alignment: .leading, spacing: NuvioTheme.spacing.xl) {
                            ForEach(Array(model.items.enumerated()), id: \.element.rowKey) { index, item in
                                ContentCard(
                                    item: item,
                                    allowsBackdropExpand: false,
                                    onFocus: { _ in
                                        if index >= model.items.count - 10 {
                                            Task { await model.loadMore(request: request, settings: settings) }
                                        }
                                    },
                                    action: { router.openDetail(item) }
                                )
                            }
                        }

                        if model.isLoading {
                            ProgressView()
                                .tint(colors.secondary)
                                .frame(maxWidth: .infinity)
                        }
                    }
                }
                .padding(.bottom, NuvioTheme.spacing.rail.tailPadding)
            }
            .scrollClipDisabled()
        }
        .task { await model.load(request: request, settings: settings) }
    }

    private var header: some View {
        HStack(spacing: NuvioTheme.spacing.lg) {
            if let logo = request.logo?.nilIfBlank {
                RemoteImage(url: logo, contentMode: .fit) { Color.clear }
                    .frame(height: dp(56))
                    .frame(maxWidth: dp(200), alignment: .leading)
            }
            Text(request.title)
                .nuvioText(NuvioTextStyles.display)
                .foregroundStyle(colors.textPrimary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
    }
}

@Observable
@MainActor
final class TMDBBrowseViewModel {
    private(set) var items: [MetaPreview] = []
    private(set) var isLoading = true
    private(set) var error: String?

    private var page = 0
    private var reachedEnd = false

    func load(request: TMDBBrowseRequest, settings: AppSettings) async {
        guard items.isEmpty else { return }
        guard !settings.tmdb.apiKey.isEmpty else {
            isLoading = false
            error = "Browsing by studio or network uses TMDB — add an API key in Metadata settings."
            return
        }
        await loadMore(request: request, settings: settings)
    }

    func loadMore(request: TMDBBrowseRequest, settings: AppSettings) async {
        guard !reachedEnd, !settings.tmdb.apiKey.isEmpty else { return }
        isLoading = true
        defer { isLoading = false }

        page += 1
        let results = await TMDBClient.shared.discover(
            type: ContentType.from(request.contentType),
            filter: request.entity.filter,
            page: page,
            apiKey: settings.tmdb.apiKey,
            language: settings.tmdb.language
        )
        guard !results.isEmpty else {
            reachedEnd = true
            return
        }
        let existing = Set(items.map(\.rowKey))
        let additions = results.filter { !existing.contains($0.rowKey) }
        items.append(contentsOf: additions)
        reachedEnd = additions.isEmpty
    }
}

private extension TMDBBrowseRequest.Entity {
    var filter: TMDBClient.BrowseFilter {
        switch self {
        case .network(let id): return .network(id)
        case .company(let id): return .company(id)
        case .genre(let id): return .genre(id)
        }
    }
}
