import SwiftUI
import Observation

/// Remote library mode is deliberately separate from `LibraryStore`: switching to Trakt must
/// never overwrite the titles a viewer saved locally. It mirrors Android's Collection and
/// Watchlist tabs and uses their IMDb ids to open the normal addon-backed detail screen.
@Observable
@MainActor
final class TraktLibraryViewModel {
    private(set) var lists: [TraktClient.LibraryList] = []
    private(set) var isLoading = false
    private(set) var hasLoaded = false
    private(set) var errorMessage: String?

    func refresh(tracking: TrackingSettingsStore) async {
        guard !isLoading else { return }
        guard tracking.isTraktAuthenticated, !tracking.traktClientId.isEmpty else {
            lists = []
            errorMessage = "Connect Trakt in Settings → Integrations to browse its collection."
            hasLoaded = true
            return
        }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false; hasLoaded = true }
        lists = await TraktClient.shared.libraryLists(
            clientId: tracking.traktClientId,
            token: tracking.traktAccessToken
        )
        if lists.isEmpty {
            errorMessage = "No Trakt collection or watchlist items were found."
        }
    }
}

struct TraktLibraryContent: View {
    @Environment(\.nuvioColors) private var colors
    @Environment(AppSettings.self) private var settings
    @Environment(Router.self) private var router

    let typeFilter: ContentType?
    @State private var model = TraktLibraryViewModel()

    var body: some View {
        VStack(alignment: .leading, spacing: NuvioTheme.spacing.lg) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: NuvioTheme.spacing.xs) {
                    Text("Trakt library")
                        .nuvioText(NuvioTextStyles.sectionTitle)
                        .foregroundStyle(colors.textPrimary)
                    Text("Your Trakt collection and watchlist")
                        .nuvioText(NuvioTextStyles.metadata)
                        .foregroundStyle(colors.textSecondary)
                }
                Spacer()
                Button(action: { Task { await model.refresh(tracking: settings.tracking) } }) {
                    Label(model.isLoading ? "Refreshing…" : "Refresh", systemImage: "arrow.clockwise")
                }
                .buttonStyle(NuvioPillButtonStyle(emphasis: .secondary))
                .disabled(model.isLoading)
            }
            .padding(.horizontal, NuvioTheme.components.row.horizontalPadding)

            if model.isLoading && model.lists.isEmpty {
                PosterSkeletonRow(showsTitle: false)
            } else if let message = model.errorMessage, model.lists.isEmpty {
                EmptyStateView(systemImage: "checklist", title: "Trakt library", message: message)
                    .frame(height: dp(260))
            } else {
                ForEach(model.lists) { list in
                    let visible = filtered(list.items)
                    if !visible.isEmpty {
                        CatalogRowView(
                            title: list.title,
                            items: visible,
                            showsSeeAll: false,
                            onSelect: { router.openDetail($0) }
                        )
                    }
                }
            }
        }
        .task {
            guard !model.hasLoaded else { return }
            await model.refresh(tracking: settings.tracking)
        }
    }

    private func filtered(_ items: [MetaPreview]) -> [MetaPreview] {
        guard let typeFilter else { return items }
        return items.filter { $0.type == typeFilter }
    }
}
