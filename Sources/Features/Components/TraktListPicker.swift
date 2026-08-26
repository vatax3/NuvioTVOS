import SwiftUI

/// Files a title into the viewer's own Trakt lists.
///
/// Their own lists, not the watchlist — that is what the library row already toggles, and
/// offering it twice under two names would be the same control wearing a disguise.
///
/// Membership fills in after the picker is drawn rather than before it. Trakt has no endpoint
/// that answers "which of my lists contain this", so it is one request per list, and making a
/// long press wait on twelve of them before showing anything would be worse than a row of
/// checkmarks arriving a moment late.
struct TraktListPicker: View {
    @Environment(\.nuvioColors) private var colors
    @Environment(AppSettings.self) private var settings

    let preview: MetaPreview
    let onDismiss: () -> Void

    @State private var lists: [TraktClient.CustomList] = []
    @State private var membership: [Int: Bool] = [:]
    @State private var pending: Set<Int> = []
    @State private var isLoading = true
    @State private var failure: String?

    @FocusState private var focused: Int?

    private var imdbId: String? { preview.imdbId?.nilIfBlank }

    var body: some View {
        ZStack {
            Color.black.opacity(0.5)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture(perform: onDismiss)

            VStack(alignment: .leading, spacing: NuvioTheme.spacing.lg) {
                VStack(alignment: .leading, spacing: NuvioTheme.spacing.xxs) {
                    Text("Trakt lists")
                        .nuvioText(NuvioTypography.headlineLarge)
                        .foregroundStyle(colors.textPrimary)
                    Text(preview.name)
                        .nuvioText(NuvioTextStyles.bodyCompact)
                        .foregroundStyle(colors.textSecondary)
                        .lineLimit(1)
                }

                content
            }
            .padding(NuvioTheme.spacing.xl)
            .frame(width: dp(400), alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: NuvioTheme.radii.xl, style: .continuous)
                    .fill(colors.backgroundElevated)
            )
        }
        .focusSection()
        .onExitCommand(perform: onDismiss)
        .task { await load() }
    }

    @ViewBuilder
    private var content: some View {
        if let failure {
            Text(failure)
                .nuvioText(NuvioTextStyles.bodyCompact)
                .foregroundStyle(colors.error)
        } else if isLoading {
            Text("Loading your lists…")
                .nuvioText(NuvioTextStyles.bodyCompact)
                .foregroundStyle(colors.textTertiary)
        } else if lists.isEmpty {
            Text("You have no lists of your own on Trakt.")
                .nuvioText(NuvioTextStyles.bodyCompact)
                .foregroundStyle(colors.textTertiary)
        } else {
            VStack(alignment: .leading, spacing: NuvioTheme.spacing.xs) {
                ForEach(lists) { list in
                    row(list)
                }
            }
        }
    }

    private func row(_ list: TraktClient.CustomList) -> some View {
        Button(action: { Task { await toggle(list) } }) {
            HStack(spacing: NuvioTheme.spacing.md) {
                Image(systemName: symbol(for: list))
                    .frame(width: dp(22))
                Text(list.name)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text(list.itemCount == 1 ? "1 item" : "\(list.itemCount) items")
                    .nuvioText(NuvioTextStyles.metadata)
                    .foregroundStyle(colors.textTertiary)
            }
            .nuvioText(NuvioTextStyles.button)
            .foregroundStyle(colors.textPrimary)
            .padding(.horizontal, NuvioTheme.spacing.lg)
            .frame(height: NuvioTheme.components.buttonHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(NuvioRowButtonStyle(cornerRadius: NuvioTheme.radii.lg))
        .focused($focused, equals: list.id)
        .disabled(pending.contains(list.id))
    }

    /// Three states, and the unknown one has to be distinguishable from "not in it" — otherwise
    /// a row whose membership has not arrived looks like an answer.
    private func symbol(for list: TraktClient.CustomList) -> String {
        if pending.contains(list.id) { return "ellipsis" }
        switch membership[list.id] {
        case .some(true): return "checkmark.circle.fill"
        case .some(false): return "circle"
        case nil: return "circle.dotted"
        }
    }

    private func load() async {
        let clientId = settings.tracking.traktClientId
        let token = settings.tracking.traktAccessToken
        guard !clientId.isEmpty, !token.isEmpty, imdbId != nil else {
            failure = "Connect Trakt in Settings → Integrations to use your lists."
            isLoading = false
            return
        }

        lists = await TraktClient.shared.customLists(clientId: clientId, token: token)
        isLoading = false
        focused = lists.first?.id

        // Membership after the fact, one request per list — see the type's own note.
        for list in lists {
            let items = await TraktClient.shared.listItems(
                listId: list.id, type: preview.type, sortBy: "", sortHow: "",
                clientId: clientId, token: token
            )
            membership[list.id] = items.contains { $0.imdbId?.nilIfBlank == imdbId }
        }
    }

    private func toggle(_ list: TraktClient.CustomList) async {
        guard let imdbId, !pending.contains(list.id) else { return }
        let clientId = settings.tracking.traktClientId
        let token = settings.tracking.traktAccessToken

        // Unknown membership is treated as "not in it": adding a title already there is a no-op
        // on Trakt, where removing one that is not would silently do nothing and look broken.
        let isIn = membership[list.id] ?? false
        pending.insert(list.id)
        defer { pending.remove(list.id) }

        let outcome = try? await TraktClient.shared.writeListItem(
            listId: list.id, removing: isIn, imdbId: imdbId, type: preview.type,
            clientId: clientId, token: token
        )
        guard let outcome, outcome.didChangeAnything else {
            failure = "Trakt did not recognise \(preview.name)."
            return
        }
        membership[list.id] = !isIn
        failure = nil
    }
}
