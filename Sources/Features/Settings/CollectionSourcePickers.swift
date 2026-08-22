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
        SettingsSheet(title: chosen == nil ? "Choose a catalog" : "Choose a genre") {
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
            footnote: "A genre narrows the catalog. Leave it out to take the whole thing."
        ) {
            SettingsRow(title: "Whole catalog", systemImage: "tray.full", trailing: { EmptyView() }) {
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
        SettingsSheet(title: "TMDB source") {
            if settings.tmdb.apiKey.isEmpty {
                SettingsCard(title: nil, footnote: "Add a TMDB API key in Integrations first — without one this source returns nothing.") {
                    EmptyView()
                }
            }

            SettingsCard(title: "What to ask for") {
                SettingsOptionRow(title: "Kind", selection: $kind)
                SettingsOptionRow(title: "Media", selection: $mediaType)
                SettingsOptionRow(title: "Sort", selection: $sort)
                SettingsTextFieldRow(
                    title: "Name",
                    subtitle: "What this source is called in the folder",
                    placeholder: "Highest rated",
                    text: $title
                )
                if needsId {
                    SettingsTextFieldRow(
                        title: "TMDB id",
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
                SettingsRow(title: "Add source", systemImage: "plus", trailing: { EmptyView() }, action: add)
            }
        }
    }

    private var idHint: String {
        switch kind {
        case .list: return "The id of a TMDB list"
        case .collection: return "A TMDB collection, e.g. a film series"
        case .company: return "A studio id"
        case .network: return "A network id"
        case .person, .director: return "A person id"
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
        SettingsSheet(title: "Trakt list") {
            if settings.tracking.traktClientId.isEmpty {
                SettingsCard(title: nil, footnote: "Connect Trakt in Integrations first — without a client id this source returns nothing.") {
                    EmptyView()
                }
            }

            SettingsCard(
                title: "List",
                footnote: "The number at the end of the list's URL on trakt.tv."
            ) {
                SettingsTextFieldRow(title: "Name", placeholder: "Best of 2024", text: $title)
                SettingsTextFieldRow(title: "List id", placeholder: "1234567", text: $listId)
                SettingsOptionRow(title: "Media", selection: $mediaType)
                SettingsOptionRow(title: "Sort", selection: $sort)
                SettingsOptionRow(title: "Direction", selection: $order)
            }

            SettingsCard(title: nil) {
                SettingsRow(title: "Add source", systemImage: "plus", trailing: { EmptyView() }, action: add)
            }
        }
    }

    private func add() {
        guard let id = Int(listId) else { return }
        collections.addSource(
            .trakt(TraktCollectionSource(
                title: title.nilIfBlank ?? "Trakt list",
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
        SettingsSheet(title: mode == .importing ? "Import collections" : "Export collections") {
            SettingsCard(
                title: nil,
                footnote: mode == .importing
                    ? "Paste the JSON exported from another Nuvio app. This replaces every collection on this device."
                    : "Copy this into another Nuvio app's import screen."
            ) {
                SettingsTextFieldRow(
                    title: "JSON",
                    text: $text,
                    trailingAction: mode == .importing ? (label: "Import", action: performImport) : nil
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
                status = "That JSON held no collections."
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
        case .list: return "List"
        case .collection: return "Collection"
        case .company: return "Studio"
        case .network: return "Network"
        case .discover: return "Search"
        case .person: return "Actor"
        case .director: return "Director"
        }
    }
}

extension TmdbMediaType: SettingsOption {
    var displayName: String { self == .tv ? "Series" : "Movies" }
}

extension TmdbCollectionSort: SettingsOption {
    var displayName: String {
        switch self {
        case .original: return "As listed"
        case .popularityDesc: return "Most popular"
        case .voteAverageDesc: return "Highest rated"
        case .voteCountDesc: return "Most voted"
        case .releaseDateDesc: return "Newest"
        case .firstAirDateDesc: return "Newest aired"
        }
    }
}

extension TraktListSort: SettingsOption {
    var displayName: String { rawValue.capitalized }
}

extension TraktSortHow: SettingsOption {
    var displayName: String { self == .asc ? "Ascending" : "Descending" }
}
