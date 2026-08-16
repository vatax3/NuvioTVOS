import SwiftUI
import Observation

// MARK: - Layout modes (port of HomeLayout / ExperienceMode / PosterShape settings)

enum HomeLayout: String, CaseIterable, Codable, Identifiable {
    case classic, grid, modern
    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .classic: return "Classic View"
        case .grid: return "Grid View"
        case .modern: return "Modern View"
        }
    }

    var summary: String {
        switch self {
        case .classic: return "Focused backdrop with poster rails underneath."
        case .grid: return "Dense grid of catalogs, no hero."
        case .modern: return "Full-bleed hero carousel with floating rails."
        }
    }
}

enum ExperienceMode: String, CaseIterable, Codable, Identifiable {
    case essential, advanced
    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .essential: return "Essential"
        case .advanced: return "Advanced"
        }
    }
}

enum ContinueWatchingCardStyle: String, CaseIterable, Codable, Identifiable {
    case poster, landscape
    var id: String { rawValue }
    var displayName: String { self == .poster ? "Poster" : "Landscape" }
}

// MARK: - Store

@Observable
final class SettingsStore {
    // Appearance
    var theme: AppTheme { didSet { defaults.set(theme.rawValue, forKey: Keys.theme) } }
    var font: AppFont { didSet { defaults.set(font.rawValue, forKey: Keys.font) } }
    var amoledMode: Bool { didSet { defaults.set(amoledMode, forKey: Keys.amoled) } }
    var amoledSurfaces: Bool { didSet { defaults.set(amoledSurfaces, forKey: Keys.amoledSurfaces) } }

    // Layout
    var homeLayout: HomeLayout { didSet { defaults.set(homeLayout.rawValue, forKey: Keys.homeLayout) } }
    var layoutChosen: Bool { didSet { defaults.set(layoutChosen, forKey: Keys.layoutChosen) } }
    var experienceMode: ExperienceMode { didSet { defaults.set(experienceMode.rawValue, forKey: Keys.experienceMode) } }
    var experienceModeChosen: Bool { didSet { defaults.set(experienceModeChosen, forKey: Keys.experienceModeChosen) } }
    var sidebarCollapsed: Bool { didSet { defaults.set(sidebarCollapsed, forKey: Keys.sidebarCollapsed) } }
    var showDiscoverTab: Bool { didSet { defaults.set(showDiscoverTab, forKey: Keys.showDiscover) } }
    var continueWatchingStyle: ContinueWatchingCardStyle {
        didSet { defaults.set(continueWatchingStyle.rawValue, forKey: Keys.cwStyle) }
    }

    // Playback
    var autoPlayNextEpisode: Bool { didSet { defaults.set(autoPlayNextEpisode, forKey: Keys.autoPlayNext) } }
    var preferredQuality: String { didSet { defaults.set(preferredQuality, forKey: Keys.preferredQuality) } }
    var skipIntroEnabled: Bool { didSet { defaults.set(skipIntroEnabled, forKey: Keys.skipIntro) } }
    var resumeThresholdPercent: Double { didSet { defaults.set(resumeThresholdPercent, forKey: Keys.resumeThreshold) } }
    var subtitleSize: Double { didSet { defaults.set(subtitleSize, forKey: Keys.subtitleSize) } }

    private let defaults: UserDefaults

    private enum Keys {
        static let theme = "nuvio.theme"
        static let font = "nuvio.font"
        static let amoled = "nuvio.amoled"
        static let amoledSurfaces = "nuvio.amoledSurfaces"
        static let homeLayout = "nuvio.homeLayout"
        static let layoutChosen = "nuvio.layoutChosen"
        static let experienceMode = "nuvio.experienceMode"
        static let experienceModeChosen = "nuvio.experienceModeChosen"
        static let sidebarCollapsed = "nuvio.sidebarCollapsed"
        static let showDiscover = "nuvio.showDiscover"
        static let cwStyle = "nuvio.continueWatchingStyle"
        static let autoPlayNext = "nuvio.autoPlayNext"
        static let preferredQuality = "nuvio.preferredQuality"
        static let skipIntro = "nuvio.skipIntro"
        static let resumeThreshold = "nuvio.resumeThreshold"
        static let subtitleSize = "nuvio.subtitleSize"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Keys.theme: AppTheme.crimson.rawValue,
            Keys.font: AppFont.inter.rawValue,
            Keys.amoled: false,
            Keys.amoledSurfaces: false,
            Keys.homeLayout: HomeLayout.modern.rawValue,
            Keys.layoutChosen: false,
            Keys.experienceMode: ExperienceMode.advanced.rawValue,
            Keys.experienceModeChosen: false,
            Keys.sidebarCollapsed: true,
            Keys.showDiscover: true,
            Keys.cwStyle: ContinueWatchingCardStyle.landscape.rawValue,
            Keys.autoPlayNext: true,
            Keys.preferredQuality: "1080p",
            Keys.skipIntro: true,
            Keys.resumeThreshold: 0.9,
            Keys.subtitleSize: 1.0
        ])

        theme = AppTheme(rawValue: defaults.string(forKey: Keys.theme) ?? "") ?? .crimson
        font = AppFont(rawValue: defaults.string(forKey: Keys.font) ?? "") ?? .inter
        amoledMode = defaults.bool(forKey: Keys.amoled)
        amoledSurfaces = defaults.bool(forKey: Keys.amoledSurfaces)
        homeLayout = HomeLayout(rawValue: defaults.string(forKey: Keys.homeLayout) ?? "") ?? .modern
        layoutChosen = defaults.bool(forKey: Keys.layoutChosen)
        experienceMode = ExperienceMode(rawValue: defaults.string(forKey: Keys.experienceMode) ?? "") ?? .advanced
        experienceModeChosen = defaults.bool(forKey: Keys.experienceModeChosen)
        sidebarCollapsed = defaults.bool(forKey: Keys.sidebarCollapsed)
        showDiscoverTab = defaults.bool(forKey: Keys.showDiscover)
        continueWatchingStyle = ContinueWatchingCardStyle(
            rawValue: defaults.string(forKey: Keys.cwStyle) ?? ""
        ) ?? .landscape
        autoPlayNextEpisode = defaults.bool(forKey: Keys.autoPlayNext)
        preferredQuality = defaults.string(forKey: Keys.preferredQuality) ?? "1080p"
        skipIntroEnabled = defaults.bool(forKey: Keys.skipIntro)
        resumeThresholdPercent = defaults.double(forKey: Keys.resumeThreshold)
        subtitleSize = defaults.double(forKey: Keys.subtitleSize)
    }

    var colors: NuvioColorScheme {
        NuvioColorScheme(
            palette: ThemeColors.palette(for: theme),
            amoledMode: amoledMode,
            amoledSurfaces: amoledSurfaces
        )
    }
}
