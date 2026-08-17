import SwiftUI
import Network

/// Advanced section — port of `AdvancedSettingsContent`: performance and navigation, diagnostics,
/// cache, the network speed test, and the switch back to Essential mode. The official app keeps
/// the experience-mode switch here rather than as its own rail entry.
struct AdvancedSettingsContent: View {
    @Environment(\.nuvioColors) private var colors
    @Environment(AppSettings.self) private var settings
    @Environment(LibraryStore.self) private var library

    @State private var cacheCleared = false
    @State private var speedTest = NetworkSpeedTester()

    var body: some View {
        @Bindable var layout = settings.layout
        @Bindable var player = settings.player
        @Bindable var app = settings.app

        VStack(alignment: .leading, spacing: NuvioTheme.components.settings.rowGap) {
            // Android puts the experience switch in Advanced rather than on the rail.
            ExperienceSettingsContent()

            SettingsCard(title: "Performance & navigation") {
                SettingsToggle(
                    title: "Fast horizontal navigation",
                    subtitle: "Skip the settle animation when a direction is held",
                    systemImage: "forward.fill",
                    isOn: $layout.fastHorizontalNavigationEnabled
                )
                SettingsToggle(
                    title: "Nuvio focus scrolling",
                    subtitle: "Anchor the focused card instead of letting the system place it",
                    systemImage: "arrow.left.and.right",
                    isOn: $layout.smoothBringIntoViewEnabled
                )
                SettingsToggle(
                    title: "Remember last profile",
                    subtitle: "Reopen the profile that was active at shutdown",
                    systemImage: "person.crop.circle.badge.clock",
                    isOn: $app.remembersLastProfile
                )
            }

            SettingsCard(
                title: "Diagnostics",
                footnote: "Nuvio's crash reporting is not wired up in this client — there is no Sentry project to report to, so the option is omitted rather than shown doing nothing."
            ) {
                SettingsToggle(
                    title: "Playback issue reports",
                    subtitle: "Offer a report action during long loads and playback errors",
                    systemImage: "exclamationmark.bubble",
                    isOn: $player.playbackIssueReportsEnabled
                )
                SettingsToggle(
                    title: "Verbose playback logging",
                    subtitle: "Write player state changes to the system log",
                    systemImage: "doc.text.magnifyingglass",
                    isOn: $player.verboseLoggingEnabled
                )
            }

            SettingsCard(title: "Cache") {
                SettingsRow(
                    title: "Clear Continue Watching cache",
                    subtitle: cacheCleared
                        ? "Cache cleared"
                        : "Remove cached artwork and episode stills for the Continue Watching rail",
                    systemImage: "trash",
                    action: {
                        library.clearContinueWatchingCache()
                        cacheCleared = true
                    }
                )
            }

            networkCard
        }
    }

    // MARK: Network

    private var networkCard: some View {
        SettingsCard(
            title: "Network speed",
            footnote: "Latency and download throughput, measured against Cloudflare's speed endpoint."
        ) {
            SettingsInfoRow(
                title: "Connection",
                value: speedTest.connectionDescription,
                tint: speedTest.isOnline ? colors.success : colors.error
            )
            SettingsRow(
                title: speedTest.isRunning ? "Running speed test…" : "Run speed test",
                subtitle: speedTest.isRunning ? speedTest.stage : "Measure latency and download speed",
                systemImage: "speedometer",
                action: { speedTest.run() }
            )
            .disabled(speedTest.isRunning)
            .opacity(speedTest.isRunning ? NuvioTheme.effects.disabledAlpha : 1)

            if let latency = speedTest.latencyMilliseconds {
                SettingsInfoRow(title: "Latency", value: "\(Int(latency)) ms")
            }
            if let throughput = speedTest.megabitsPerSecond {
                SettingsInfoRow(title: "Download", value: String(format: "%.1f Mbps", throughput))
            }
            if let error = speedTest.error {
                SettingsInfoRow(title: "Error", value: error, tint: colors.error)
            }
        }
    }
}

// MARK: - Speed test

/// Latency and download measurement. The Android build drives fast.com through a scraped token;
/// Cloudflare's `__down` endpoint gives the same two numbers with a documented, stable contract.
@Observable
@MainActor
final class NetworkSpeedTester {
    private(set) var isRunning = false
    private(set) var stage = ""
    private(set) var latencyMilliseconds: Double?
    private(set) var megabitsPerSecond: Double?
    private(set) var error: String?
    private(set) var isOnline = true
    private(set) var connectionDescription = "Checking…"

    private let monitor = NWPathMonitor()

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                guard let self else { return }
                self.isOnline = path.status == .satisfied
                if !self.isOnline {
                    self.connectionDescription = "Offline"
                } else if path.usesInterfaceType(.wiredEthernet) {
                    self.connectionDescription = "Ethernet"
                } else if path.usesInterfaceType(.wifi) {
                    self.connectionDescription = "Wi-Fi"
                } else {
                    self.connectionDescription = "Connected"
                }
            }
        }
        monitor.start(queue: .global(qos: .utility))
    }

    deinit { monitor.cancel() }

    func run() {
        guard !isRunning else { return }
        isRunning = true
        error = nil
        latencyMilliseconds = nil
        megabitsPerSecond = nil

        Task {
            defer { isRunning = false }
            stage = "Measuring latency"
            latencyMilliseconds = await measureLatency()
            stage = "Measuring download speed"
            do {
                megabitsPerSecond = try await measureDownload()
            } catch {
                self.error = error.localizedDescription
            }
            stage = ""
        }
    }

    /// Median of five HEAD requests, so one slow handshake does not define the result.
    private func measureLatency() async -> Double? {
        guard let url = URL(string: "https://speed.cloudflare.com/__down?bytes=0") else { return nil }
        var samples: [Double] = []
        for _ in 0..<5 {
            var request = URLRequest(url: url)
            request.httpMethod = "HEAD"
            request.cachePolicy = .reloadIgnoringLocalCacheData
            let started = Date()
            guard (try? await URLSession.shared.data(for: request)) != nil else { continue }
            samples.append(Date().timeIntervalSince(started) * 1000)
        }
        guard !samples.isEmpty else { return nil }
        return samples.sorted()[samples.count / 2]
    }

    private func measureDownload() async throws -> Double {
        // 25 MB is enough to saturate a TV's link without making the test feel stuck.
        let bytes = 25_000_000
        guard let url = URL(string: "https://speed.cloudflare.com/__down?bytes=\(bytes)") else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 60

        let started = Date()
        let (data, response) = try await URLSession.shared.data(for: request)
        let elapsed = Date().timeIntervalSince(started)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        guard elapsed > 0 else { throw URLError(.cannotParseResponse) }
        return Double(data.count) * 8 / elapsed / 1_000_000
    }
}
