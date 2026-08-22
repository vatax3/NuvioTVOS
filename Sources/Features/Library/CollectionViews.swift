import SwiftUI

// MARK: - Folder card

/// One folder of a collection, as a tile.
///
/// A folder is a saved question rather than a saved answer, so the tile shows what the viewer
/// named it and not what happens to be inside today. Artwork, when there is any, is the cover
/// they chose; otherwise the emoji; otherwise the title carries it alone.
struct CollectionFolderCard: View {
    @Environment(\.nuvioColors) private var colors
    @Environment(\.posterMetrics) private var metrics

    let folder: CollectionFolder
    var focusBinding: FocusState<String?>.Binding?
    let action: () -> Void

    @State private var isFocused = false

    private var size: CGSize { metrics.size(for: folder.tileShape) }

    var body: some View {
        Button(action: action) {
            ZStack {
                if let cover = folder.coverImageUrl?.nilIfBlank {
                    RemoteImage(url: cover, contentMode: .fill) { placeholder }
                } else {
                    placeholder
                }

                if !folder.hideTitle {
                    LinearGradient(
                        colors: [.clear, .black.opacity(0.72)],
                        startPoint: .center,
                        endPoint: .bottom
                    )
                    Text(folder.title)
                        .nuvioText(NuvioTextStyles.cardTitle)
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .padding(NuvioTheme.spacing.md)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                }
            }
            .frame(width: size.width, height: size.height)
            .clipped()
        }
        .buttonStyle(NuvioCardButtonStyle(cornerRadius: metrics.cornerRadius))
        .modifier(OptionalCardFocus(binding: focusBinding, key: folder.id))
        .accessibilityLabel(folder.title)
    }

    /// The emoji, or the folder icon, on the card surface.
    private var placeholder: some View {
        ZStack {
            colors.backgroundCard
            if let emoji = folder.coverEmoji?.nilIfBlank {
                Text(emoji).font(.system(size: size.height * 0.34))
            } else {
                Image(systemName: "folder.fill")
                    .font(.system(size: NuvioTheme.sizes.icons.lg))
                    .foregroundStyle(colors.textTertiary)
            }
        }
    }
}

/// `.focused()` only binds on the focusable view itself, and the binding is optional here, so
/// applying it conditionally needs a modifier rather than an `if` inside the body.
private struct OptionalCardFocus: ViewModifier {
    let binding: FocusState<String?>.Binding?
    let key: String

    func body(content: Content) -> some View {
        if let binding {
            content.focused(binding, equals: key)
        } else {
            content
        }
    }
}

// MARK: - Rail

/// One collection as a rail of its folders.
struct CollectionRail: View {
    @Environment(\.nuvioColors) private var colors
    @Environment(Router.self) private var router

    let collection: MediaCollection
    var focusBinding: FocusState<String?>.Binding?

    var body: some View {
        VStack(alignment: .leading, spacing: NuvioTheme.components.row.titleBottomSpacing) {
            HStack(spacing: NuvioTheme.spacing.md) {
                Text(collection.title)
                    .nuvioText(NuvioTextStyles.sectionTitle)
                    .foregroundStyle(colors.textPrimary)
                Text("\(collection.folders.count) folder\(collection.folders.count == 1 ? "" : "s")")
                    .nuvioText(NuvioTextStyles.metadata)
                    .foregroundStyle(colors.textSecondary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, NuvioTheme.components.row.horizontalPadding)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: NuvioTheme.components.row.itemSpacing) {
                    ForEach(collection.folders) { folder in
                        CollectionFolderCard(folder: folder, focusBinding: focusBinding) {
                            router.push(.collectionFolder(
                                CollectionFolderRequest(collectionId: collection.id, folderId: folder.id)
                            ))
                        }
                    }
                }
                .padding(.horizontal, NuvioTheme.components.row.horizontalPadding)
                .padding(.vertical, NuvioTheme.spacing.sm)
            }
            .scrollClipDisabled()
        }
        .focusSection()
    }
}
