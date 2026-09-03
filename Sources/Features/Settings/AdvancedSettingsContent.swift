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

            SettingsCard(title: L10n.text("settings.advanced.performance", fallback: "Performance & navigation")) {
                SettingsToggle(
                    title: L10n.text("settings.advanced.fast_horizontal", fallback: "Fast horizontal navigation"),
                    subtitle: L10n.text("settings.advanced.fast_horizontal_sub", fallback: "Skip the settle animation when a direction is held"),
                    systemImage: "forward.fill",
                    isOn: $layout.fastHorizontalNavigationEnabled
                )
                SettingsToggle(
                    title: L10n.text("settings.advanced.focus_scrolling", fallback: "Nuvio focus scrolling"),
                    subtitle: L10n.text("settings.advanced.focus_scrolling_sub", fallback: "Anchor the focused card instead of letting the system place it"),
                    systemImage: "arrow.left.and.right",
                    isOn: $layout.smoothBringIntoViewEnabled
                )
                SettingsToggle(
                    title: L10n.text("settings.advanced.remember_profile", fallback: "Remember last profile"),
                    subtitle: L10n.text("settings.advanced.remember_profile_sub", fallback: "Reopen the profile that was active at shutdown"),
                    systemImage: "person.crop.circle.badge.clock",
                    isOn: $app.remembersLastProfile
                )
            }

            SettingsCard(
                title: L10n.text("settings.advanced.diagnostics", fallback: "Diagnostics"),
                footnote: L10n.text("settings.advanced.diagnostics_footnote", fallback: "Neither crash reporting nor playback issue reports are wired up in this client — both upload to Nuvio's own backend, whose contract belongs to the Android project. Verbose logging writes to the system log on this device instead.")
            ) {
                SettingsToggle(
                    title: L10n.text("settings.advanced.stats_overlay", fallback: "Playback stats overlay"),
                    subtitle: L10n.text(
                        "settings.advanced.stats_overlay_sub",
                        fallback: "Add a Stats button to stream information, for live buffer, network, bitrate, CPU, memory and thermal readings"
                    ),
                    systemImage: "chart.bar.xaxis",
                    isOn: $player.statsOverlayEnabled
                )
                SettingsToggle(
                    title: L10n.text("settings.advanced.verbose_logging", fallback: "Verbose playback logging"),
                    subtitle: L10n.text("settings.advanced.verbose_logging_sub", fallback: "Write player state changes to the system log"),
                    systemImage: "doc.text.magnifyingglass",
                    isOn: $player.verboseLoggingEnabled
                )
            }

            SettingsCard(title: L10n.text("settings.advanced.cache", fallback: "Cache")) {
                SettingsRow(
                    title: L10n.text("settings.advanced.clear_cw", fallback: "Clear Continue Watching cache"),
                    subtitle: cacheCleared
                        ? L10n.text("settings.advanced.cache_cleared", fallback: "Cache cleared")
                        : L10n.text("settings.advanced.clear_cw_sub", fallback: "Remove cached artwork and episode stills for the Continue Watching rail"),
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
            title: L10n.text("settings.advanced.network_speed", fallback: "Network speed"),
            footnote: L10n.text("settings.advanced.network_speed_footnote", fallback: "Latency and download throughput, measured against Cloudflare's speed endpoint.")
        ) {
            SettingsInfoRow(
                title: L10n.text("settings.advanced.connection", fallback: "Connection"),
                value: speedTest.connectionDescription,
                tint: speedTest.isOnline ? colors.success : colors.error
            )
            SettingsRow(
                title: speedTest.isRunning ? L10n.text("settings.advanced.running_test", fallback: "Running speed test…") : L10n.text("settings.advanced.run_test", fallback: "Run speed test"),
                subtitle: speedTest.isRunning ? speedTest.stage : L10n.text("settings.advanced.run_test_sub", fallback: "Measure latency and download speed"),
                systemImage: "speedometer",
                action: { speedTest.run() }
            )
            .disabled(speedTest.isRunning)
            .opacity(speedTest.isRunning ? NuvioTheme.effects.disabledAlpha : 1)

            if let latency = speedTest.latencyMilliseconds {
                SettingsInfoRow(title: L10n.text("settings.advanced.latency", fallback: "Latency"), value: "\(Int(latency)) ms")
            }
            if let throughput = speedTest.megabitsPerSecond {
                SettingsInfoRow(title: L10n.text("settings.advanced.download", fallback: "Download"), value: String(format: "%.1f Mbps", throughput))
            }
            if let error = speedTest.error {
                SettingsInfoRow(title: L10n.text("settings.advanced.error", fallback: "Error"), value: error, tint: colors.error)
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
    private(set) var connectionDescription = L10n.text("settings.advanced.checking", fallback: "Checking…")

    private let monitor = NWPathMonitor()

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                guard let self else { return }
                self.isOnline = path.status == .satisfied
                if !self.isOnline {
                    self.connectionDescription = L10n.text("settings.advanced.offline", fallback: "Offline")
                } else if path.usesInterfaceType(.wiredEthernet) {
                    self.connectionDescription = L10n.text("settings.advanced.ethernet", fallback: "Ethernet")
                } else if path.usesInterfaceType(.wifi) {
                    self.connectionDescription = "Wi-Fi"
                } else {
                    self.connectionDescription = L10n.text("settings.advanced.connected", fallback: "Connected")
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
            stage = L10n.text("settings.advanced.measuring_latency", fallback: "Measuring latency")
            latencyMilliseconds = await measureLatency()
            stage = L10n.text("settings.advanced.measuring_download", fallback: "Measuring download speed")
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
