import SwiftUI
import Observation

/// The debrid cloud browser from Android's Library screen. It intentionally lives beside the
/// saved-title library rather than pretending provider files are Stremio metadata.
@Observable
@MainActor
final class CloudLibraryViewModel {
    private(set) var providers: [CloudLibraryProviderState] = []
    private(set) var isLoading = false
    private(set) var hasLoaded = false
    private(set) var resolvingFileID: String?
    private(set) var errorMessage: String?

    func showNoPlayableFiles() {
        errorMessage = L10n.text("cloud.no_supported_files", fallback: "This item has no supported video files.")
    }

    func refresh(debrid: DebridSettingsStore) async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false; hasLoaded = true }
        let configuration = CloudLibraryConfiguration(
            isEnabled: debrid.cloudLibraryEnabled,
            credentials: debrid.configuredCredentials
        )
        providers = await CloudLibraryClient.shared.refresh(configuration: configuration)
    }

    func play(
        item: CloudLibraryItem,
        file: CloudLibraryFile,
        debrid: DebridSettingsStore,
        router: Router
    ) async {
        let fileID = "\(item.stableKey)|\(file.stableKey)"
        guard resolvingFileID == nil else { return }
        resolvingFileID = fileID
        errorMessage = nil
        defer { resolvingFileID = nil }
        let configuration = CloudLibraryConfiguration(
            isEnabled: debrid.cloudLibraryEnabled,
            credentials: debrid.configuredCredentials
        )
        do {
            let url = try await CloudLibraryClient.shared.resolvePlayback(
                item: item, file: file, configuration: configuration
            )
            router.play(PlaybackRequest(
                streamURL: url,
                title: file.name,
                subtitleLine: "\(item.provider.displayName) · \(item.name)",
                streamName: item.provider.displayName,
                filename: file.name,
                headers: [:],
                contentId: item.stableKey,
                contentType: "cloud",
                videoId: fileID,
                season: nil,
                episode: nil,
                poster: nil,
                backdrop: nil,
                logo: nil,
                startFromBeginning: false,
                preview: nil,
                nextUp: nil,
                imdbId: nil
            ))
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct CloudLibrarySection: View {
    @Environment(\.nuvioColors) private var colors
    @Environment(AppSettings.self) private var settings
    @Environment(Router.self) private var router

    @State private var model = CloudLibraryViewModel()
    @State private var query = ""
    @State private var selectedItem: CloudLibraryItem?
    @State private var selectedProvider: DebridProvider?
    @State private var selectedType: CloudLibraryItemType?

    private var enabled: Bool { settings.debrid.cloudLibraryEnabled }
    private var isConnected: Bool { !settings.debrid.configuredCredentials.filter { $0.provider.supportsCloudLibrary }.isEmpty }
    private var items: [CloudLibraryItem] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let all = model.providers.flatMap(\.items)
        return all.filter { item in
            guard (selectedProvider == nil || item.provider == selectedProvider),
                  (selectedType == nil || item.type == selectedType) else { return false }
            guard !trimmed.isEmpty else { return true }
            return item.name.localizedCaseInsensitiveContains(trimmed)
                || item.files.contains { $0.name.localizedCaseInsensitiveContains(trimmed) }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: NuvioTheme.spacing.lg) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: NuvioTheme.spacing.xs) {
                    Text(L10n.text("cloud.title", fallback: "Cloud library"))
                        .nuvioText(NuvioTextStyles.sectionTitle)
                        .foregroundStyle(colors.textPrimary)
                    Text(L10n.text("cloud.subtitle", fallback: "Files saved in Premiumize and TorBox"))
                        .nuvioText(NuvioTextStyles.metadata)
                        .foregroundStyle(colors.textSecondary)
                }
                Spacer()
                Button(action: { Task { await model.refresh(debrid: settings.debrid) } }) {
                    Label(model.isLoading ? "Refreshing…" : "Refresh", systemImage: "arrow.clockwise")
                }
                .buttonStyle(NuvioPillButtonStyle(emphasis: .secondary))
                .disabled(model.isLoading || !enabled || !isConnected)
            }

            if enabled, isConnected, !model.providers.isEmpty {
                ChipRow(title: "Provider") {
                    NuvioChip(label: "All", isSelected: selectedProvider == nil, action: { selectedProvider = nil })
                    ForEach(model.providers.filter { !$0.items.isEmpty }) { provider in
                        NuvioChip(
                            label: "\(provider.provider.displayName) (\(provider.items.count))",
                            isSelected: selectedProvider == provider.provider,
                            action: { selectedProvider = provider.provider }
                        )
                    }
                }

                ChipRow(title: "Type") {
                    NuvioChip(label: "All", isSelected: selectedType == nil, action: { selectedType = nil })
                    ForEach(CloudLibraryItemType.allCases, id: \.self) { type in
                        let count = model.providers.flatMap(\.items).filter { $0.type == type }.count
                        if count > 0 {
                            NuvioChip(
                                label: "\(type.label) (\(count))",
                                isSelected: selectedType == type,
                                action: { selectedType = type }
                            )
                        }
                    }
                }

                TextField(L10n.text("cloud.filter", fallback: "Filter cloud files"), text: $query)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, NuvioTheme.spacing.md)
                    .frame(height: dp(52))
                    .background(colors.surfaceVariant, in: RoundedRectangle(cornerRadius: NuvioTheme.radii.md))
                    .frame(maxWidth: dp(560))
            }

            content
        }
        .padding(.horizontal, NuvioTheme.components.row.horizontalPadding)
        .task {
            // Restored before the fetch, so the list never renders under the wrong filter.
            selectedType = CloudLibraryItemType(rawValue: settings.layout.cloudLibraryTypeFilter)
            guard !model.hasLoaded else { return }
            await model.refresh(debrid: settings.debrid)
        }
        .onChange(of: selectedType) { _, selection in
            settings.layout.cloudLibraryTypeFilter = selection?.rawValue ?? ""
        }
        .sheet(item: $selectedItem) { item in
            CloudFilePicker(
                item: item,
                resolvingFileID: model.resolvingFileID,
                play: { file in
                    Task {
                        await model.play(item: item, file: file, debrid: settings.debrid, router: router)
                        if model.errorMessage == nil { selectedItem = nil }
                    }
                }
            )
        }
    }

    @ViewBuilder
    private var content: some View {
        if !enabled {
            cloudEmpty(icon: "cloud.slash", title: L10n.text("cloud.off_title", fallback: "Cloud library is off"), message: L10n.text("cloud.off_body", fallback: "Enable it in Settings → Debrid to browse your provider files."))
        } else if !isConnected {
            cloudEmpty(icon: "key", title: L10n.text("cloud.disconnected_title", fallback: "Connect Premiumize or TorBox"), message: L10n.text("cloud.disconnected_body", fallback: "Add an API key in Settings → Debrid to show your stored files here."))
        } else if model.isLoading && !model.hasLoaded {
            ProgressView(L10n.text("cloud.loading", fallback: "Loading cloud library…"))
                .tint(colors.secondary)
                .frame(maxWidth: .infinity, minHeight: dp(160))
        } else if items.isEmpty {
            cloudEmpty(icon: "externaldrive", title: L10n.text("cloud.empty_title", fallback: "No cloud files found"), message: providerError ?? L10n.text("cloud.empty_body", fallback: "Your connected provider did not return any saved files."))
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: NuvioTheme.spacing.lg) {
                    ForEach(items) { item in
                        CloudLibraryCard(item: item, action: { open(item) })
                    }
                }
                .padding(.vertical, NuvioTheme.spacing.sm)
            }
            .scrollClipDisabled()
        }

        if let error = model.errorMessage {
            Text(error)
                .nuvioText(NuvioTextStyles.metadata)
                .foregroundStyle(colors.error)
        }
    }

    private var providerError: String? {
        model.providers.compactMap(\.errorMessage).first
    }

    private func open(_ item: CloudLibraryItem) {
        let files = item.playableFiles
        switch files.count {
        case 0:
            model.showNoPlayableFiles()
        case 1:
            Task { await model.play(item: item, file: files[0], debrid: settings.debrid, router: router) }
        default:
            selectedItem = item
        }
    }

    private func cloudEmpty(icon: String, title: String, message: String) -> some View {
        HStack(spacing: NuvioTheme.spacing.md) {
            Image(systemName: icon)
                .font(.system(size: NuvioTheme.sizes.icons.lg))
                .foregroundStyle(colors.textTertiary)
            VStack(alignment: .leading, spacing: NuvioTheme.spacing.xs) {
                Text(title).nuvioText(NuvioTextStyles.cardTitle).foregroundStyle(colors.textPrimary)
                Text(message).nuvioText(NuvioTextStyles.metadata).foregroundStyle(colors.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, minHeight: dp(116), alignment: .leading)
    }
}

private struct CloudLibraryCard: View {
    @Environment(\.nuvioColors) private var colors
    let item: CloudLibraryItem
    let action: () -> Void

    @State private var isFocused = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: NuvioTheme.spacing.sm) {
                Image(systemName: item.provider == .torbox ? "shippingbox.fill" : "cloud.fill")
                    .font(.system(size: NuvioTheme.sizes.icons.lg))
                    .foregroundStyle(colors.secondary)
                Spacer(minLength: 0)
                Text(item.name)
                    .nuvioText(NuvioTextStyles.cardTitle)
                    .foregroundStyle(colors.textPrimary)
                    .lineLimit(2)
                Text(metadata)
                    .nuvioText(NuvioTextStyles.metadata)
                    .foregroundStyle(colors.textSecondary)
                    .lineLimit(1)
            }
            .padding(NuvioTheme.spacing.lg)
            .frame(width: dp(300), height: dp(180), alignment: .leading)
            .background(colors.surfaceVariant, in: RoundedRectangle(cornerRadius: NuvioTheme.radii.lg))
        }
        .buttonStyle(NuvioCardButtonStyle(cornerRadius: NuvioTheme.radii.lg, focusedScale: 1.04))
        .onFocusChange { isFocused = $0 }
        .accessibilityLabel("\(item.name), \(metadata)")
    }

    private var metadata: String {
        let count = item.playableFiles.count
        let fileLabel = count == 0 ? L10n.text("cloud.no_playable", fallback: "No playable files") : "\(count) playable file\(count == 1 ? "" : "s")"
        return [
            item.provider.displayName,
            item.type.label,
            item.status,
            fileLabel,
            item.sizeBytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
        ]
            .compactMap { $0?.nilIfBlank }.joined(separator: " · ")
    }
}

private struct CloudFilePicker: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.nuvioColors) private var colors
    let item: CloudLibraryItem
    let resolvingFileID: String?
    let play: (CloudLibraryFile) -> Void

    var body: some View {
        NavigationStack {
            List(item.playableFiles) { file in
                Button(action: { play(file) }) {
                    HStack(spacing: NuvioTheme.spacing.md) {
                        Image(systemName: file.isPlayable ? "play.circle.fill" : "doc")
                            .foregroundStyle(file.isPlayable ? colors.secondary : colors.textTertiary)
                        VStack(alignment: .leading, spacing: NuvioTheme.spacing.xs) {
                            Text(file.name).nuvioText(NuvioTextStyles.cardTitle).foregroundStyle(colors.textPrimary)
                            if let size = file.sizeBytes {
                                Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                                    .nuvioText(NuvioTextStyles.metadata).foregroundStyle(colors.textSecondary)
                            }
                        }
                        Spacer()
                        if resolvingFileID == "\(item.stableKey)|\(file.stableKey)" { ProgressView() }
                    }
                }
                .disabled(!file.isPlayable || resolvingFileID != nil)
            }
            .navigationTitle(item.name)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done", action: dismiss.callAsFunction) } }
        }
    }
}
