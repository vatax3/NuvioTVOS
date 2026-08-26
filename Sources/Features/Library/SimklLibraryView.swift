import Observation
import SwiftUI

@Observable
@MainActor
final class SimklLibraryViewModel {
    private(set) var lists: [SimklClient.LibraryList] = []
    private(set) var isLoading = false
    private(set) var hasLoaded = false
    private(set) var errorMessage: String?

    func refresh(tracking: TrackingSettingsStore) async {
        guard !isLoading else { return }
        guard tracking.isSimklAuthenticated, !tracking.simklClientId.isEmpty else {
            lists = []
            errorMessage = L10n.text("simkl.disconnected", fallback: "Connect Simkl in Settings → Integrations to browse its lists.")
            hasLoaded = true
            return
        }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false; hasLoaded = true }
        do {
            lists = try await SimklClient.shared.libraryLists(
                clientId: tracking.simklClientId,
                token: tracking.simklAccessToken,
                animePreference: tracking.simklAnimeIdPreference
            )
            if lists.isEmpty { errorMessage = L10n.text("simkl.empty", fallback: "No Simkl list items were found.") }
        } catch {
            lists = []
            errorMessage = "Simkl could not be refreshed. \(error.localizedDescription)"
        }
    }
}

struct SimklLibraryContent: View {
    @Environment(\.nuvioColors) private var colors
    @Environment(AppSettings.self) private var settings
    @Environment(Router.self) private var router

    let typeFilter: ContentType?
    @State private var model = SimklLibraryViewModel()

    var body: some View {
        VStack(alignment: .leading, spacing: NuvioTheme.spacing.lg) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: NuvioTheme.spacing.xs) {
                    Text(L10n.text("simkl.title", fallback: "Simkl library"))
                        .nuvioText(NuvioTextStyles.sectionTitle)
                        .foregroundStyle(colors.textPrimary)
                    Text("Watching, Plan to Watch, On Hold, Completed and Dropped")
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
                EmptyStateView(systemImage: "checklist", title: L10n.text("simkl.title", fallback: "Simkl library"), message: message)
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
