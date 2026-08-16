import SwiftUI
import Observation

/// Port of `StreamScreenViewModel` — fans out to every addon exposing `stream` for this id
/// and merges the results as they arrive so the first provider is actionable immediately.
@Observable
@MainActor
final class StreamsViewModel {
    private(set) var groups: [AddonStreams] = []
    private(set) var isLoading = true
    private(set) var failedAddons: [String] = []

    private let client: StremioClient

    init(client: StremioClient = .shared) {
        self.client = client
    }

    var totalCount: Int { groups.reduce(0) { $0 + $1.streams.count } }

    func load(request: StreamRequest, addonStore: AddonStore) async {
        isLoading = true
        groups = []
        failedAddons = []
        defer { isLoading = false }

        let providers = addonStore.addonsProviding(
            resource: "stream", type: request.contentType, id: request.videoId
        )
        guard !providers.isEmpty else { return }

        await withTaskGroup(of: (Addon, [Stream]?).self) { group in
            for addon in providers {
                group.addTask { [client] in
                    let streams = try? await client.fetchStreams(
                        addon: addon, type: request.contentType, videoId: request.videoId
                    )
                    return (addon, streams)
                }
            }
            for await (addon, streams) in group {
                guard let streams else {
                    failedAddons.append(addon.displayName)
                    continue
                }
                guard !streams.isEmpty else { continue }
                // Best quality first within each provider, matching the Android ordering.
                let sorted = streams.sorted { $0.qualityValue > $1.qualityValue }
                groups.append(AddonStreams(
                    addonName: addon.displayName, addonLogo: addon.logo, streams: sorted
                ))
                groups.sort { $0.addonName.localizedCaseInsensitiveCompare($1.addonName) == .orderedAscending }
            }
        }
    }
}

struct StreamsView: View {
    @Environment(\.nuvioColors) private var colors
    @Environment(AddonStore.self) private var addons
    @Environment(LibraryStore.self) private var library
    @Environment(Router.self) private var router

    let request: StreamRequest

    @State private var model = StreamsViewModel()

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: NuvioTheme.spacing.xl) {
                header

                if model.isLoading && model.groups.isEmpty {
                    NuvioLoadingView(message: "Searching your addons for sources…")
                        .frame(height: dp(320))
                } else if model.groups.isEmpty {
                    EmptyStateView(
                        systemImage: "antenna.radiowaves.left.and.right.slash",
                        title: "No sources found",
                        message: model.failedAddons.isEmpty
                            ? "None of your installed addons returned a stream for this title."
                            : "No sources returned. These addons failed: \(model.failedAddons.joined(separator: ", "))."
                    )
                    .frame(height: dp(320))
                } else {
                    ForEach(model.groups) { group in
                        StreamGroupSection(group: group, onSelect: play)
                    }
                }
            }
            .padding(.top, NuvioTheme.layout.tvSafeVertical)
            .padding(.bottom, NuvioTheme.spacing.rail.tailPadding)
        }
        .scrollClipDisabled()
        .background(colors.background)
        .task { await model.load(request: request, addonStore: addons) }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: NuvioTheme.spacing.xs) {
            Text(request.title)
                .nuvioText(NuvioTextStyles.display)
                .foregroundStyle(colors.textPrimary)
                .lineLimit(1)

            HStack(spacing: NuvioTheme.spacing.md) {
                if let label = request.episodeLabel {
                    NuvioBadge(text: label, tint: colors.secondary)
                }
                if let name = request.episodeName?.nilIfBlank {
                    Text(name)
                        .nuvioText(NuvioTextStyles.bodyCompact)
                        .foregroundStyle(colors.textSecondary)
                        .lineLimit(1)
                }
                if model.totalCount > 0 {
                    Text("\(model.totalCount) sources")
                        .nuvioText(NuvioTextStyles.metadata)
                        .foregroundStyle(colors.textTertiary)
                }
            }
        }
        .padding(.horizontal, NuvioTheme.components.row.horizontalPadding)
    }

    private func play(_ stream: Stream) {
        guard let url = stream.streamURL() else { return }
        let preview = library.cachedPreview(contentType: request.contentType, contentId: request.contentId)
        router.play(PlaybackRequest(
            streamURL: url,
            title: request.title,
            subtitleLine: [request.episodeLabel, request.episodeName].compactMap { $0 }.joined(separator: " · ").nilIfBlank,
            streamName: stream.displayName,
            headers: stream.behaviorHints?.proxyHeaders?.request ?? [:],
            contentId: request.contentId,
            contentType: request.contentType,
            videoId: request.videoId,
            season: request.season,
            episode: request.episode,
            poster: request.poster,
            backdrop: request.backdrop,
            logo: request.logo,
            startFromBeginning: false,
            preview: preview
        ))
    }
}

// MARK: - Group

private struct StreamGroupSection: View {
    @Environment(\.nuvioColors) private var colors
    let group: AddonStreams
    let onSelect: (Stream) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: NuvioTheme.spacing.md) {
            HStack(spacing: NuvioTheme.spacing.sm) {
                if let logo = group.addonLogo?.nilIfBlank {
                    RemoteImage(url: logo, contentMode: .fit) { Color.clear }
                        .frame(width: NuvioTheme.sizes.icons.lg, height: NuvioTheme.sizes.icons.lg)
                        .clipShape(RoundedRectangle(cornerRadius: NuvioTheme.radii.xs))
                }
                Text(group.addonName)
                    .nuvioText(NuvioTextStyles.sectionTitle)
                    .foregroundStyle(colors.textPrimary)
                Text("\(group.streams.count)")
                    .nuvioText(NuvioTextStyles.metadata)
                    .foregroundStyle(colors.textTertiary)
            }
            .padding(.horizontal, NuvioTheme.components.row.horizontalPadding)

            VStack(spacing: NuvioTheme.spacing.sm) {
                ForEach(group.streams) { stream in
                    StreamRow(stream: stream, action: { onSelect(stream) })
                }
            }
            .padding(.horizontal, NuvioTheme.components.row.horizontalPadding)
        }
        .focusSection()
    }
}

// MARK: - Row (port of StreamComponents / StreamBadgeChips)

private struct StreamRow: View {
    @Environment(\.nuvioColors) private var colors
    let stream: Stream
    let action: () -> Void

    private var searchText: String {
        [stream.name, stream.title, stream.description, stream.behaviorHints?.filename]
            .compactMap { $0 }
            .joined(separator: " ")
    }

    private var isPlayable: Bool { stream.streamURL() != nil }

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: NuvioTheme.spacing.lg) {
                VStack(alignment: .leading, spacing: NuvioTheme.spacing.xs) {
                    Text(stream.displayName)
                        .nuvioText(NuvioTextStyles.cardTitle)
                        .foregroundStyle(colors.textPrimary)
                        .lineLimit(1)
                        .multilineTextAlignment(.leading)

                    if let detail = stream.displayDescription?.nilIfBlank, detail != stream.displayName {
                        Text(detail)
                            .nuvioText(NuvioTextStyles.metadata)
                            .foregroundStyle(colors.textSecondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }

                    HStack(spacing: NuvioTheme.spacing.sm) {
                        if let quality = stream.quality {
                            NuvioBadge(text: quality, tint: colors.secondary, filled: true)
                        }
                        ForEach(QualityParser.tags(searchText).prefix(4), id: \.self) { tag in
                            NuvioBadge(text: tag)
                        }
                        if let size = QualityParser.size(searchText) {
                            Text(size)
                                .nuvioText(NuvioTextStyles.metadata)
                                .foregroundStyle(colors.textTertiary)
                        }
                        if let seeders = QualityParser.seeders(searchText) {
                            HStack(spacing: dp(3)) {
                                Image(systemName: "person.2.fill")
                                    .font(.system(size: NuvioTheme.sizes.icons.xs))
                                Text("\(seeders)")
                                    .nuvioText(NuvioTextStyles.metadata)
                            }
                            .foregroundStyle(colors.success)
                        }
                        if stream.isTorrent {
                            NuvioBadge(text: "Torrent", tint: colors.torrent)
                        }
                    }
                }

                Spacer(minLength: 0)

                Image(systemName: isPlayable ? "play.circle.fill" : "exclamationmark.circle")
                    .font(.system(size: NuvioTheme.sizes.icons.lg))
                    .foregroundStyle(isPlayable ? colors.textSecondary : colors.warning)
            }
            .padding(.horizontal, NuvioTheme.spacing.xl)
            .padding(.vertical, NuvioTheme.spacing.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(NuvioRowButtonStyle(cornerRadius: NuvioTheme.radii.lg, scaleOnFocus: false))
        .background {
            RoundedRectangle(cornerRadius: NuvioTheme.radii.lg, style: .continuous)
                .fill(colors.backgroundCard.opacity(0.55))
        }
        .disabled(!isPlayable)
        .opacity(isPlayable ? 1 : NuvioTheme.effects.disabledAlpha)
    }
}
