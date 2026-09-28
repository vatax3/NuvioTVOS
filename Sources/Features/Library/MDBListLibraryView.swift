import Observation
import SwiftUI

/// The viewer's MDBList watchlist and static lists, as rails.
///
/// The shape follows `SimklLibraryContent` deliberately — the three tracker library screens are
/// the same screen with a different account behind them, and one of them looking different would
/// read as a different feature rather than a different service.
///
/// One difference, and it is the service's: MDBList's lists are **named by the viewer**, so there
/// is no fixed set of tabs to describe the way Simkl's five states can be. The lists are fetched
/// and then their contents, which is one request plus one per list.
@Observable
@MainActor
final class MDBListLibraryViewModel {
    private(set) var lists: [MDBListClient.ListContents] = []
    private(set) var isLoading = false
    private(set) var hasLoaded = false
    private(set) var errorMessage: String?

    func refresh(tracking: TrackingSettingsStore) async {
        guard !isLoading else { return }
        guard tracking.isMDBListAuthenticated else {
            lists = []
            errorMessage = L10n.text(
                "mdblist.disconnected",
                fallback: "Connect MDBList in Settings → Integrations to browse its lists."
            )
            hasLoaded = true
            return
        }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false; hasLoaded = true }

        // The token is fetched rather than read: MDBList's expire, and an expired one would show
        // an empty library rather than saying the account needs signing in again.
        guard let token = await MDBListSession.token(tracking) else {
            lists = []
            errorMessage = L10n.text(
                "mdblist.session_expired",
                fallback: "That MDBList session expired. Sign in again in Settings → Integrations."
            )
            return
        }

        var contents: [MDBListClient.ListContents] = []
        for list in await MDBListClient.shared.lists(token: token) {
            let items = await MDBListClient.shared.items(in: list, token: token)
            // An empty list is not an error and not worth a rail: a viewer with eight lists and
            // two of them filled wants two rails, not eight with six headings over nothing.
            guard !items.isEmpty else { continue }
            contents.append(.init(list: list, items: items))
        }
        lists = contents
        if contents.isEmpty {
            errorMessage = L10n.text("mdblist.empty", fallback: "No MDBList items were found.")
        }
    }
}

struct MDBListLibraryContent: View {
    @Environment(\.nuvioColors) private var colors
    @Environment(AppSettings.self) private var settings
    @Environment(Router.self) private var router

    let typeFilter: ContentType?
    @State private var model = MDBListLibraryViewModel()

    var body: some View {
        VStack(alignment: .leading, spacing: NuvioTheme.spacing.lg) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: NuvioTheme.spacing.xs) {
                    Text(L10n.text("mdblist.title", fallback: "MDBList library"))
                        .nuvioText(NuvioTextStyles.sectionTitle)
                        .foregroundStyle(colors.textPrimary)
                    Text(L10n.text(
                        "mdblist.subtitle",
                        fallback: "Your watchlist and the static lists you keep there"
                    ))
                    .nuvioText(NuvioTextStyles.metadata)
                    .foregroundStyle(colors.textSecondary)
                }
                Spacer()
                Button(action: { Task { await model.refresh(tracking: settings.tracking) } }) {
                    Label(
                        model.isLoading
                            ? L10n.text("library.refreshing", fallback: "Refreshing…")
                            : L10n.text("library.refresh", fallback: "Refresh"),
                        systemImage: "arrow.clockwise"
                    )
                }
                .buttonStyle(NuvioPillButtonStyle(emphasis: .secondary))
                .disabled(model.isLoading)
            }
            .padding(.horizontal, NuvioTheme.components.row.horizontalPadding)

            if model.isLoading && model.lists.isEmpty {
                PosterSkeletonRow(showsTitle: false)
            } else if let message = model.errorMessage, model.lists.isEmpty {
                EmptyStateView(
                    systemImage: "checklist",
                    title: L10n.text("mdblist.title", fallback: "MDBList library"),
                    message: message
                )
                .frame(height: dp(260))
            } else {
                ForEach(model.lists) { contents in
                    let visible = filtered(contents.items)
                    if !visible.isEmpty {
                        CatalogRowView(
                            title: contents.list.name,
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
