import SwiftUI

// MARK: - Addon catalogue

/// Every catalogue the installed addons expose, plus the genres each one offers.
///
/// This is the source kind that needs no account and no key, so it is the one a folder is most
/// likely to be built from — and the one to reach for when checking that any of this works.
struct AddonCatalogPickerView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AddonStore.self) private var addons
    @Environment(CollectionStore.self) private var collections

    let collectionId: String
    let folderId: String

    @State private var chosen: (addon: Addon, catalog: CatalogDescriptor)?

    var body: some View {
        SettingsSheet(title: chosen == nil ? L10n.text("settings.source.choose_catalog", fallback: "Choose a catalog") : L10n.text("settings.source.choose_genre", fallback: "Choose a genre")) {
            if let chosen {
                genreCard(for: chosen)
            } else {
                catalogCards
            }
        }
    }

    private var catalogCards: some View {
        ForEach(addons.enabledAddons.filter { !$0.catalogs.isEmpty }) { addon in
            SettingsCard(title: addon.displayName) {
                ForEach(addon.catalogs) { catalog in
                    SettingsRow(
                        title: catalog.name,
                        subtitle: ContentType.from(catalog.apiType).displayName,
                        systemImage: "square.grid.2x2",
                        trailing: { SettingsValueLabel(value: "") },
                        action: { select(addon: addon, catalog: catalog) }
                    )
                }
            }
        }
    }

    private func genreCard(for entry: (addon: Addon, catalog: CatalogDescriptor)) -> some View {
        SettingsCard(
            title: entry.catalog.name,
            footnote: L10n.text("settings.source.genre_footnote", fallback: "A genre narrows the catalog. Leave it out to take the whole thing.")
        ) {
            SettingsRow(title: L10n.text("settings.source.whole_catalog", fallback: "Whole catalog"), systemImage: "tray.full", trailing: { EmptyView() }) {
                add(entry: entry, genre: nil)
            }
            ForEach(entry.catalog.genreOptions, id: \.self) { genre in
                SettingsRow(title: genre, systemImage: "tag", trailing: { EmptyView() }) {
                    add(entry: entry, genre: genre)
                }
            }
        }
    }

    private func select(addon: Addon, catalog: CatalogDescriptor) {
        // Skip the second step when the catalogue has no genres to narrow by.
        if catalog.genreOptions.isEmpty {
            add(entry: (addon, catalog), genre: nil)
        } else {
            chosen = (addon, catalog)
        }
    }

    private func add(entry: (addon: Addon, catalog: CatalogDescriptor), genre: String?) {
        // Keyed by manifest id, which is what the other apps write — a base URL differs per
        // installation and would not survive the trip.
        collections.addSource(
            .addon(AddonCollectionSource(
                addonId: entry.addon.id,
                type: entry.catalog.apiType,
                catalogId: entry.catalog.id,
                genre: genre
            )),
            toFolder: folderId,
            in: collectionId
        )
        dismiss()
    }
}

// MARK: - TMDB

struct TmdbSourcePickerView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(CollectionStore.self) private var collections
    @Environment(AppSettings.self) private var settings

    let collectionId: String
    let folderId: String

    @State private var kind: TmdbSourceKind = .discover
    @State private var mediaType: TmdbMediaType = .movie
    @State private var sort: TmdbCollectionSort = .popularityDesc
    @State private var title = ""
    @State private var tmdbId = ""
    /// One box per TMDB filter, keyed by the field it writes. Eighteen `@State` strings and an
    /// eighteen-arm assignment was the alternative; this keeps the list and the write in step.
    @State private var filterText: [TmdbFilterField: String] = [:]

    private var needsId: Bool { kind != .discover }

    var body: some View {
        SettingsSheet(title: L10n.text("settings.source.tmdb_source", fallback: "TMDB source")) {
            if settings.tmdb.apiKey.isEmpty {
                SettingsCard(title: nil, footnote: L10n.text("settings.source.tmdb_footnote", fallback: "Add a TMDB API key in Integrations first — without one this source returns nothing.")) {
                    EmptyView()
                }
            }

            SettingsCard(title: L10n.text("settings.source.what_to_ask", fallback: "What to ask for")) {
                SettingsOptionRow(title: L10n.text("settings.source.kind", fallback: "Kind"), selection: $kind)
                SettingsOptionRow(title: L10n.text("settings.source.media", fallback: "Media"), selection: $mediaType)
                SettingsOptionRow(title: L10n.text("settings.source.sort", fallback: "Sort"), selection: $sort)
                SettingsTextFieldRow(
                    title: L10n.text("settings.source.name", fallback: "Name"),
                    subtitle: L10n.text("settings.source.name_sub", fallback: "What this source is called in the folder"),
                    placeholder: L10n.text("settings.source.highest_rated", fallback: "Highest rated"),
                    text: $title
                )
                if needsId {
                    SettingsTextFieldRow(
                        title: L10n.text("settings.source.tmdb_id", fallback: "TMDB id"),
                        subtitle: idHint,
                        placeholder: "12345",
                        text: $tmdbId
                    )
                }
            }

            if kind == .discover {
                ForEach(TmdbFilterField.Group.allCases) { group in
                    SettingsCard(title: group.title, footnote: group.footnote) {
                        ForEach(TmdbFilterField.allCases.filter { $0.group == group }) { field in
                            SettingsTextFieldRow(
                                title: field.title,
                                subtitle: field.hint,
                                placeholder: field.placeholder,
                                text: Binding(
                                    get: { filterText[field] ?? "" },
                                    set: { filterText[field] = $0 }
                                )
                            )
                        }
                    }
                }
            }

            SettingsCard(title: nil) {
                SettingsRow(title: L10n.text("settings.source.add_source", fallback: "Add source"), systemImage: "plus", trailing: { EmptyView() }, action: add)
            }
        }
    }

    private var idHint: String {
        switch kind {
        case .list: return L10n.text("settings.source.hint_list", fallback: "The id of a TMDB list")
        case .collection: return L10n.text("settings.source.hint_collection", fallback: "A TMDB collection, e.g. a film series")
        case .company: return L10n.text("settings.source.hint_studio", fallback: "A studio id")
        case .network: return L10n.text("settings.source.hint_network", fallback: "A network id")
        case .person, .director: return L10n.text("settings.source.hint_person", fallback: "A person id")
        case .discover: return ""
        }
    }

    private func add() {
        guard !needsId || Int(tmdbId) != nil else { return }
        var filters = TmdbCollectionFilters()
        for (field, text) in filterText { field.apply(text, to: &filters) }

        collections.addSource(
            .tmdb(TmdbCollectionSource(
                sourceType: kind,
                title: title.nilIfBlank ?? kind.rawValue.capitalized,
                tmdbId: Int(tmdbId),
                mediaType: mediaType,
                sortBy: sort.rawValue,
                filters: filters
            )),
            toFolder: folderId,
            in: collectionId
        )
        dismiss()
    }
}

// MARK: - Trakt

struct TraktSourcePickerView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(CollectionStore.self) private var collections
    @Environment(AppSettings.self) private var settings

    let collectionId: String
    let folderId: String

    @State private var title = ""
    @State private var listId = ""
    @State private var mediaType: TmdbMediaType = .movie
    @State private var sort: TraktListSort = .rank
    @State private var order: TraktSortHow = .asc

    var body: some View {
        SettingsSheet(title: L10n.text("settings.source.trakt_list", fallback: "Trakt list")) {
            if settings.tracking.traktClientId.isEmpty {
                SettingsCard(title: nil, footnote: L10n.text("settings.source.trakt_footnote", fallback: "Connect Trakt in Integrations first — without a client id this source returns nothing.")) {
                    EmptyView()
                }
            }

            SettingsCard(
                title: L10n.text("settings.source.list", fallback: "List"),
                footnote: L10n.text("settings.source.list_footnote", fallback: "The number at the end of the list's URL on trakt.tv.")
            ) {
                SettingsTextFieldRow(title: L10n.text("settings.source.name", fallback: "Name"), placeholder: L10n.text("settings.source.list_hint", fallback: "Best of 2024"), text: $title)
                SettingsTextFieldRow(title: L10n.text("settings.source.list_id", fallback: "List id"), placeholder: "1234567", text: $listId)
                SettingsOptionRow(title: L10n.text("settings.source.media", fallback: "Media"), selection: $mediaType)
                SettingsOptionRow(title: L10n.text("settings.source.sort", fallback: "Sort"), selection: $sort)
                SettingsOptionRow(title: L10n.text("settings.source.direction", fallback: "Direction"), selection: $order)
            }

            SettingsCard(title: nil) {
                SettingsRow(title: L10n.text("settings.source.add_source", fallback: "Add source"), systemImage: "plus", trailing: { EmptyView() }, action: add)
            }
        }
    }

    private func add() {
        guard let id = Int(listId) else { return }
        collections.addSource(
            .trakt(TraktCollectionSource(
                title: title.nilIfBlank ?? L10n.text("settings.source.trakt_list", fallback: "Trakt list"),
                traktListId: id,
                mediaType: mediaType,
                sortBy: sort.rawValue,
                sortHow: order.rawValue
            )),
            toFolder: folderId,
            in: collectionId
        )
        dismiss()
    }
}

// MARK: - Transfer

/// Import and export, in the format the other Nuvio apps read.
///
/// A television has no filesystem to browse and no clipboard worth the name, so this is a text
/// field either way. Ungainly, and the only way to move a collection between apps that are not
/// signed in to the same account.
struct CollectionTransferView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(CollectionStore.self) private var collections

    enum Mode { case importing, exporting }
    let mode: Mode

    @State private var text = ""
    @State private var status: String?

    var body: some View {
        SettingsSheet(title: mode == .importing ? L10n.text("settings.source.import", fallback: "Import collections") : L10n.text("settings.source.export", fallback: "Export collections")) {
            SettingsCard(
                title: nil,
                footnote: mode == .importing
                    ? L10n.text("settings.source.import_footnote", fallback: "Paste the JSON exported from another Nuvio app. This replaces every collection on this device.")
                    : L10n.text("settings.source.export_footnote", fallback: "Copy this into another Nuvio app's import screen.")
            ) {
                SettingsTextFieldRow(
                    title: "JSON",
                    text: $text,
                    trailingAction: mode == .importing ? (label: L10n.text("settings.source.import_action", fallback: "Import"), action: performImport) : nil
                )
                if let status {
                    SettingsRow(title: status, trailing: { EmptyView() }, action: {})
                }
            }
        }
        .onAppear {
            guard mode == .exporting else { return }
            text = collections.exportJSON() ?? ""
        }
    }

    private func performImport() {
        do {
            let incoming = try CollectionStore.decode(text)
            guard !incoming.isEmpty else {
                status = L10n.text("settings.source.import_empty", fallback: "That JSON held no collections.")
                return
            }
            collections.replaceAll(with: incoming)
            dismiss()
        } catch {
            status = "That is not a collections export: \(error.localizedDescription)"
        }
    }
}

// MARK: - Option labels

extension TmdbSourceKind: SettingsOption {
    var displayName: String {
        switch self {
        case .list: return L10n.text("settings.source.list", fallback: "List")
        case .collection: return L10n.text("settings.source.collection", fallback: "Collection")
        case .company: return L10n.text("settings.source.studio", fallback: "Studio")
        case .network: return L10n.text("settings.source.network", fallback: "Network")
        case .discover: return L10n.text("settings.source.search", fallback: "Search")
        case .person: return L10n.text("settings.source.actor", fallback: "Actor")
        case .director: return L10n.text("settings.source.director", fallback: "Director")
        }
    }
}

extension TmdbMediaType: SettingsOption {
    var displayName: String { self == .tv ? L10n.text("settings.source.series", fallback: "Series") : L10n.text("settings.source.movies", fallback: "Movies") }
}

extension TmdbCollectionSort: SettingsOption {
    var displayName: String {
        switch self {
        case .original: return L10n.text("settings.source.as_listed", fallback: "As listed")
        case .popularityDesc: return L10n.text("settings.source.most_popular", fallback: "Most popular")
        case .voteAverageDesc: return L10n.text("settings.source.highest_rated", fallback: "Highest rated")
        case .voteCountDesc: return L10n.text("settings.source.most_voted", fallback: "Most voted")
        case .releaseDateDesc: return L10n.text("settings.source.newest", fallback: "Newest")
        case .firstAirDateDesc: return L10n.text("settings.source.newest_aired", fallback: "Newest aired")
        }
    }
}

extension TraktListSort: SettingsOption {
    var displayName: String { rawValue.capitalized }
}

extension TraktSortHow: SettingsOption {
    var displayName: String { self == .asc ? L10n.text("settings.source.ascending", fallback: "Ascending") : L10n.text("settings.source.descending", fallback: "Descending") }
}
