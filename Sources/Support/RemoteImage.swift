import SwiftUI
import UIKit
import os

// MARK: - Loader

/// Coil stands in for this on Android. Here: a small two-tier cache (RAM + URLCache-backed
/// disk) with request coalescing, sized for the handful of rails visible on a TV screen.
actor ImageLoader {
    static let shared = ImageLoader()

    private let memory: NSCache<NSURL, UIImage> = {
        let cache = NSCache<NSURL, UIImage>()
        cache.countLimit = 400
        cache.totalCostLimit = 192 * 1024 * 1024
        return cache
    }()

    private var inFlight: [URL: Task<UIImage?, Never>] = [:]
    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        config.requestCachePolicy = .returnCacheDataElseLoad
        config.urlCache = URLCache(
            memoryCapacity: 32 * 1024 * 1024,
            diskCapacity: 512 * 1024 * 1024,
            diskPath: "nuvio-images"
        )
        session = URLSession(configuration: config)
    }

    func cached(_ url: URL) -> UIImage? { memory.object(forKey: url as NSURL) }

    func image(for url: URL) async -> UIImage? {
        if let hit = memory.object(forKey: url as NSURL) { return hit }
        if let existing = inFlight[url] { return await existing.value }

        let task = Task<UIImage?, Never> { [session] in
            guard let (data, response) = try? await session.data(from: url) else { return nil }
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                return nil
            }
            return UIImage(data: data)
        }
        inFlight[url] = task
        let image = await task.value
        inFlight[url] = nil
        if let image {
            memory.setObject(image, forKey: url as NSURL, cost: image.estimatedCost)
        }
        return image
    }

    /// Warms artwork for rows that are about to scroll into view.
    func prefetch(_ urls: [URL]) {
        for url in urls where memory.object(forKey: url as NSURL) == nil && inFlight[url] == nil {
            Task { _ = await image(for: url) }
        }
    }
}

private extension UIImage {
    var estimatedCost: Int {
        guard let cg = cgImage else { return 1 }
        return cg.bytesPerRow * cg.height
    }
}

// MARK: - View

/// Drop-in for Coil's `AsyncImage`: placeholder while loading, cross-fade on arrival,
/// and a `failed` signal so heroes can fall back from a logo to a text title.
struct RemoteImage<Placeholder: View>: View {
    let url: String?
    var contentMode: ContentMode = .fill
    var transition: Bool = true
    var onFailure: (() -> Void)?
    @ViewBuilder var placeholder: () -> Placeholder

    @State private var image: UIImage?
    @State private var didFail = false
    @State private var loadedURL: URL?

    private var resolvedURL: URL? {
        guard let url, let trimmed = url.nilIfBlank else { return nil }
        return URL(string: trimmed)
    }

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
                    .transition(transition ? .opacity : .identity)
            } else {
                placeholder()
            }
        }
        .task(id: resolvedURL) { await load() }
    }

    private func load() async {
        guard let resolvedURL else {
            image = nil
            return
        }
        guard loadedURL != resolvedURL else { return }

        // Show a cache hit synchronously so scrolling rails do not flash their placeholder.
        if let hit = await ImageLoader.shared.cached(resolvedURL) {
            image = hit
            loadedURL = resolvedURL
            didFail = false
            return
        }

        image = nil
        didFail = false
        let loaded = await ImageLoader.shared.image(for: resolvedURL)
        guard !Task.isCancelled, resolvedURL == self.resolvedURL else { return }
        if let loaded {
            withAnimation(NuvioMotion.quickTween) { image = loaded }
            loadedURL = resolvedURL
        } else {
            didFail = true
            onFailure?()
        }
    }
}

extension RemoteImage where Placeholder == AnyView {
    /// Convenience initialiser using the standard poster placeholder surface.
    init(url: String?, contentMode: ContentMode = .fill, background: Color) {
        self.init(url: url, contentMode: contentMode, transition: true, onFailure: nil) {
            AnyView(background)
        }
    }
}

// MARK: - Placeholder surface

/// Port of `MonochromePosterPlaceholder` — a flat card surface with a muted glyph.
struct PosterPlaceholder: View {
    @Environment(\.nuvioColors) private var colors
    var iconFraction: CGFloat = NuvioTheme.media.posterFallbackIconFraction
    var systemImage: String = "film"

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                colors.posterFallback
                Image(systemName: systemImage)
                    .font(.system(size: min(proxy.size.width, proxy.size.height) * iconFraction))
                    .foregroundStyle(colors.textTertiary.opacity(0.55))
            }
        }
    }
}

// MARK: - Shimmer

/// Port of `PlaceholderShimmer` — used by the skeleton rails during first load.
struct ShimmerView: View {
    @Environment(\.nuvioColors) private var colors
    @State private var phase: CGFloat = -1

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            LinearGradient(
                stops: [
                    .init(color: colors.surfaceVariant.opacity(NuvioTheme.effects.shimmerLowAlpha), location: 0),
                    .init(color: colors.surfaceVariant.opacity(NuvioTheme.effects.shimmerHighAlpha), location: 0.5),
                    .init(color: colors.surfaceVariant.opacity(NuvioTheme.effects.shimmerLowAlpha), location: 1)
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
            .background(colors.backgroundCard)
            .offset(x: phase * width)
            .onAppear {
                withAnimation(.linear(duration: NuvioMotion.durations.shimmer).repeatForever(autoreverses: false)) {
                    phase = 1
                }
            }
        }
        .clipped()
    }
}
