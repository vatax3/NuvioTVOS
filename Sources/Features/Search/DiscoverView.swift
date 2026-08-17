import SwiftUI
import Observation

/// Port of `DiscoverScreen` / `SearchDiscoverSection`: browse every catalog an addon exposes,
/// filtered by type and genre, rather than only the ones flagged for the home screen.
@Observable
@MainActor
final class DiscoverViewModel {
    var selectedType: ContentType = .movie
    var selectedGenre: String?
    /// Applied to the grid so "hide unreleased" reaches Discover too, not only Home.
    var presentation: CatalogPresentation = .default {
        didSet { items = presentation.filter(rawItems) }
    }
    private(set) var rawItems: [MetaPreview] = []
    private(set) var items: [MetaPreview] = []
    private(set) var isLoading = false
    private(set) var error: String?
    private(set) var selection: (addon: Addon, catalog: CatalogDescriptor)?

    private let client: StremioClient
    private var loadTask: Task<Void, Never>?

    init(client: StremioClient = .shared) {
        self.client = client
    }

    func availableTypes(_ addonStore: AddonStore) -> [ContentType] {
        var seen: [ContentType] = []
        for entry in addonStore.allCatalogs where !seen.contains(entry.catalog.type) {
            seen.append(entry.catalog.type)
        }
        return seen.isEmpty ? [.movie, .series] : seen
    }

    func catalogs(_ addonStore: AddonStore) -> [(addon: Addon, catalog: CatalogDescriptor)] {
        addonStore.allCatalogs.filter { $0.catalog.type == selectedType }
    }

    func select(_ entry: (addon: Addon, catalog: CatalogDescriptor), addonStore: AddonStore) {
        selection = entry
        selectedGenre = nil
        load()
    }

    func ensureSelection(_ addonStore: AddonStore) {
        let available = catalogs(addonStore)
        let stillValid = selection.map { current in
            available.contains { $0.addon.baseUrl == current.addon.baseUrl && $0.catalog.id == current.catalog.id }
        } ?? false
        guard !stillValid, let first = available.first else { return }
        selection = first
        selectedGenre = nil
        load()
    }

    func load() {
        guard let selection else { return }
        loadTask?.cancel()
        loadTask = Task {
            isLoading = true
            defer { isLoading = false }
            var extras: [(String, String)] = []
            if let genre = selectedGenre { extras.append(("genre", genre)) }
            else if selection.catalog.requiresGenre, let first = selection.catalog.genreOptions.first {
                extras.append(("genre", first))
            }
            do {
                let result = try await client.fetchCatalog(
                    addon: selection.addon,
                    type: selection.catalog.apiType,
                    catalogId: selection.catalog.id,
                    extraArgs: extras
                )
                guard !Task.isCancelled else { return }
                rawItems = result
                items = presentation.filter(result)
                error = result.isEmpty ? "This catalog returned no items." : nil
            } catch {
                guard !Task.isCancelled else { return }
                rawItems = []
                items = []
                self.error = error.localizedDescription
            }
        }
    }
}

/// The standalone Discover destination — the browser plus its own screen title.
struct DiscoverView: View {
    @Environment(\.nuvioColors) private var colors

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: NuvioTheme.spacing.xl) {
                Text("Discover")
                    .nuvioText(NuvioTextStyles.display)
                    .foregroundStyle(colors.textPrimary)
                    .padding(.horizontal, NuvioTheme.components.row.horizontalPadding)

                DiscoverBrowser()
            }
            .padding(.top, NuvioTheme.layout.tvSafeVertical)
            .padding(.bottom, NuvioTheme.spacing.rail.tailPadding)
        }
        .scrollClipDisabled()
        .background(colors.background)
    }
}

/// Chips plus grid, without the screen chrome — Search embeds this when the viewer moved
/// Discover into the Search tab.
struct DiscoverBrowser: View {
    @Environment(\.nuvioColors) private var colors
    @Environment(\.posterMetrics) private var metrics
    @Environment(AddonStore.self) private var addons
    @Environment(AppSettings.self) private var settings
    @Environment(Router.self) private var router

    @State private var model = DiscoverViewModel()

    private var columns: [GridItem] { metrics.gridColumns() }

    var body: some View {
        VStack(alignment: .leading, spacing: NuvioTheme.spacing.xl) {
            typeChips
            catalogChips
            genreChips
            grid
        }
        .onAppear { model.ensureSelection(addons) }
        .onChange(of: model.selectedType) { _, _ in model.ensureSelection(addons) }
        .onChange(of: settings.catalogPresentation, initial: true) { _, presentation in
            model.presentation = presentation
        }
    }

    private var typeChips: some View {
        ChipRow(title: "Type") {
            ForEach(model.availableTypes(addons), id: \.self) { type in
                NuvioChip(
                    label: type.displayName,
                    isSelected: model.selectedType == type,
                    action: { model.selectedType = type }
                )
            }
        }
    }

    private var catalogChips: some View {
        ChipRow(title: "Catalog") {
            ForEach(model.catalogs(addons), id: \.catalog.descriptorKey) { entry in
                NuvioChip(
                    label: "\(entry.catalog.name) · \(entry.addon.displayName)",
                    isSelected: model.selection?.catalog.descriptorKey == entry.catalog.descriptorKey
                        && model.selection?.addon.baseUrl == entry.addon.baseUrl,
                    action: { model.select(entry, addonStore: addons) }
                )
            }
        }
    }

    @ViewBuilder
    private var genreChips: some View {
        let genres = model.selection?.catalog.genreOptions ?? []
        if !genres.isEmpty {
            ChipRow(title: "Genre") {
                NuvioChip(
                    label: "All",
                    isSelected: model.selectedGenre == nil,
                    action: {
                        model.selectedGenre = nil
                        model.load()
                    }
                )
                ForEach(genres, id: \.self) { genre in
                    NuvioChip(
                        label: genre,
                        isSelected: model.selectedGenre == genre,
                        action: {
                            model.selectedGenre = genre
                            model.load()
                        }
                    )
                }
            }
        }
    }

    @ViewBuilder
    private var grid: some View {
        if model.isLoading && model.items.isEmpty {
            PosterSkeletonRow(showsTitle: false)
        } else if model.items.isEmpty {
            EmptyStateView(
                systemImage: "square.grid.2x2",
                title: "Nothing here",
                message: model.error ?? "Pick a catalog to browse."
            )
            .frame(height: dp(300))
        } else {
            LazyVGrid(columns: columns, alignment: .leading, spacing: NuvioTheme.spacing.xl) {
                ForEach(model.items, id: \.rowKey) { item in
                    ContentCard(
                        item: item,
                        allowsBackdropExpand: false,
                        action: { router.openDetail(item) }
                    )
                }
            }
            .padding(.horizontal, NuvioTheme.components.row.horizontalPadding)
        }
    }
}

// MARK: - Chips

struct ChipRow<Content: View>: View {
    @Environment(\.nuvioColors) private var colors
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: NuvioTheme.spacing.sm) {
            Text(title.uppercased())
                .nuvioText(NuvioTextStyles.badge)
                .foregroundStyle(colors.textTertiary)
                .padding(.horizontal, NuvioTheme.components.row.horizontalPadding)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: NuvioTheme.spacing.sm) {
                    content
                }
                .padding(.horizontal, NuvioTheme.components.row.horizontalPadding)
                .padding(.vertical, NuvioTheme.spacing.xs)
            }
            .scrollClipDisabled()
        }
        .focusSection()
    }
}

struct NuvioChip: View {
    let label: String
    var isSelected: Bool = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .nuvioText(NuvioTextStyles.tab)
                .lineLimit(1)
                .padding(.horizontal, NuvioTheme.spacing.lg)
                .frame(height: NuvioTheme.components.chipHeight * 1.4)
        }
        .buttonStyle(NuvioPillButtonStyle(emphasis: .secondary, selected: isSelected))
    }
}
