import SwiftUI

// MARK: - Settings design system (port of SettingsDesignSystem.kt)

/// Rounded container used for every settings group.
struct SettingsCard<Content: View>: View {
    @Environment(\.nuvioColors) private var colors
    var title: String?
    var footnote: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: NuvioTheme.spacing.md) {
            if let title {
                Text(title)
                    .nuvioText(NuvioTextStyles.tab)
                    .foregroundStyle(colors.textTertiary)
            }
            VStack(spacing: NuvioTheme.spacing.xs) {
                content
            }
            .padding(NuvioTheme.components.settings.workspacePadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: NuvioTheme.components.settings.containerRadius, style: .continuous)
                    .fill(colors.backgroundCard)
            }
            if let footnote {
                Text(footnote)
                    .nuvioText(NuvioTextStyles.metadata)
                    .foregroundStyle(colors.textTertiary)
                    .frame(maxWidth: dp(820), alignment: .leading)
            }
        }
    }
}

/// A single settings row: label + optional detail, with the standard focus treatment.
struct SettingsRow<Trailing: View>: View {
    @Environment(\.nuvioColors) private var colors
    let title: String
    var subtitle: String?
    var systemImage: String?
    @ViewBuilder var trailing: Trailing
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: NuvioTheme.spacing.lg) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: NuvioTheme.sizes.icons.md))
                        .foregroundStyle(colors.textSecondary)
                        .frame(width: NuvioTheme.sizes.icons.lg)
                }
                VStack(alignment: .leading, spacing: NuvioTheme.spacing.xxs) {
                    Text(title)
                        .nuvioText(NuvioTextStyles.cardTitle)
                        .foregroundStyle(colors.textPrimary)
                        .multilineTextAlignment(.leading)
                    if let subtitle {
                        Text(subtitle)
                            .nuvioText(NuvioTextStyles.metadata)
                            .foregroundStyle(colors.textSecondary)
                            .multilineTextAlignment(.leading)
                    }
                }
                Spacer(minLength: NuvioTheme.spacing.lg)
                trailing
            }
            .padding(.horizontal, NuvioTheme.spacing.lg)
            .frame(minHeight: NuvioTheme.sizes.settings.rowMinHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(NuvioRowButtonStyle(cornerRadius: NuvioTheme.components.settings.secondaryCardRadius, scaleOnFocus: false))
    }
}

extension SettingsRow where Trailing == EmptyView {
    init(title: String, subtitle: String? = nil, systemImage: String? = nil, action: @escaping () -> Void) {
        self.init(title: title, subtitle: subtitle, systemImage: systemImage, trailing: { EmptyView() }, action: action)
    }
}

/// Value indicator on the trailing edge of a row.
struct SettingsValueLabel: View {
    @Environment(\.nuvioColors) private var colors
    let value: String
    var chevron: Bool = true

    var body: some View {
        HStack(spacing: NuvioTheme.spacing.sm) {
            Text(value)
                .nuvioText(NuvioTextStyles.metadata)
                .foregroundStyle(colors.textSecondary)
            if chevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: NuvioTheme.sizes.icons.xs, weight: .semibold))
                    .foregroundStyle(colors.textTertiary)
            }
        }
    }
}

/// Toggle styled like the Compose switch rows.
struct SettingsToggle: View {
    @Environment(\.nuvioColors) private var colors
    let title: String
    var subtitle: String?
    var systemImage: String?
    @Binding var isOn: Bool

    var body: some View {
        SettingsRow(
            title: title,
            subtitle: subtitle,
            systemImage: systemImage,
            trailing: {
                ZStack(alignment: isOn ? .trailing : .leading) {
                    Capsule()
                        .fill(isOn ? colors.secondary : colors.surfaceVariant)
                        .frame(width: dp(52), height: dp(30))
                    Circle()
                        .fill(.white)
                        .frame(width: dp(24), height: dp(24))
                        .padding(.horizontal, dp(3))
                }
                .animation(NuvioMotion.quickTween, value: isOn)
            },
            action: { isOn.toggle() }
        )
    }
}

// MARK: - Main settings screen (port of SettingsScreen.kt)

struct SettingsView: View {
    @Environment(\.nuvioColors) private var colors
    @Environment(AppSettings.self) private var settings
    @Environment(AddonStore.self) private var addons
    @Environment(ProfileStore.self) private var profiles
    @Environment(Router.self) private var router

    enum Section: String, CaseIterable, Identifiable {
        case addons, appearance, layout, playback, debrid, plugins, tracking, metadata, extras, profiles, experience, about
        var id: String { rawValue }

        var title: String {
            switch self {
            case .addons: return "Addons"
            case .appearance: return "Appearance"
            case .layout: return "Layout"
            case .playback: return "Playback"
            case .debrid: return "Debrid"
            case .plugins: return "Plugins"
            case .tracking: return "Tracking"
            case .metadata: return "Metadata"
            case .extras: return "Extras"
            case .profiles: return "Profiles"
            case .experience: return "Experience"
            case .about: return "About"
            }
        }

        var systemImage: String {
            switch self {
            case .addons: return "puzzlepiece.extension.fill"
            case .appearance: return "paintpalette.fill"
            case .layout: return "rectangle.3.group.fill"
            case .playback: return "play.rectangle.fill"
            case .debrid: return "link"
            case .plugins: return "puzzlepiece.fill"
            case .tracking: return "chart.line.uptrend.xyaxis"
            case .metadata: return "photo.stack.fill"
            case .extras: return "sparkles"
            case .profiles: return "person.2.fill"
            case .experience: return "slider.horizontal.3"
            case .about: return "info.circle.fill"
            }
        }

        /// Essential mode hides the deep surfaces, matching the Android experience gate.
        var isAdvancedOnly: Bool {
            switch self {
            case .playback, .debrid, .plugins, .tracking, .metadata, .extras: return true
            default: return false
            }
        }

        /// A restricted profile must not be able to reach the settings that would let it lift
        /// its own restriction, or reconfigure sources for the whole household.
        var isBlockedWhenRestricted: Bool {
            switch self {
            case .addons, .playback, .debrid, .plugins, .profiles: return true
            default: return false
            }
        }
    }

    @State private var section: Section =
        LaunchArguments.settingsSection.flatMap(Section.init(rawValue:)) ?? .addons

    private var isRestricted: Bool { profiles.activeProfile?.isRestricted ?? false }

    private var sections: [Section] {
        Section.allCases.filter { section in
            guard settings.app.showsAdvancedSettings || !section.isAdvancedOnly else { return false }
            return !(isRestricted && section.isBlockedWhenRestricted)
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: NuvioTheme.spacing.xxl) {
            rail
            workspace
        }
        .padding(.horizontal, NuvioTheme.layout.tvSafeHorizontal)
        .padding(.vertical, NuvioTheme.layout.tvSafeVertical)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(colors.background)
        .onChange(of: sections.map(\.id), initial: true) { _, available in
            // Appearance is always present, so it is the safe landing spot when the current
            // section disappears (experience mode change, or a restricted profile).
            if !available.contains(section.id) { section = sections.first ?? .appearance }
        }
    }

    private var rail: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: NuvioTheme.spacing.sm) {
                Text("Settings")
                    .nuvioText(NuvioTextStyles.headline)
                    .foregroundStyle(colors.textPrimary)
                    .padding(.bottom, NuvioTheme.spacing.md)

                ForEach(sections) { item in
                    Button(action: { section = item }) {
                        HStack(spacing: NuvioTheme.spacing.md) {
                            Image(systemName: item.systemImage)
                                .font(.system(size: NuvioTheme.sizes.icons.sm))
                                .frame(width: NuvioTheme.sizes.icons.lg)
                            Text(item.title)
                                .nuvioText(NuvioTextStyles.nav)
                            Spacer(minLength: 0)
                        }
                        .foregroundStyle(section == item ? colors.textPrimary : colors.textSecondary)
                        .padding(.horizontal, NuvioTheme.spacing.lg)
                        .frame(height: NuvioTheme.sizes.settings.railItemHeight)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(NuvioRowButtonStyle(
                        cornerRadius: NuvioTheme.radii.full,
                        selected: section == item,
                        scaleOnFocus: false
                    ))
                }
            }
            .padding(.bottom, NuvioTheme.spacing.xxxl)
        }
        .scrollClipDisabled()
        .frame(width: NuvioTheme.sizes.settings.railWidth, alignment: .leading)
        .focusSection()
    }

    private var workspace: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: NuvioTheme.components.settings.rowGap) {
                switch section {
                case .addons: addonsSection
                case .appearance: ThemeSettingsContent()
                case .layout: LayoutSettingsContent()
                case .playback: PlaybackSettingsContent()
                case .debrid: DebridSettingsContent()
                case .plugins: PluginsSettingsContent()
                case .tracking: TrackingSettingsContent()
                case .metadata: MetadataSettingsContent()
                case .extras: ExtrasSettingsContent()
                case .profiles: ProfilesSettingsContent()
                case .experience: ExperienceSettingsContent()
                case .about: AboutContent()
                }
            }
            .padding(.bottom, NuvioTheme.spacing.rail.tailPadding)
        }
        .scrollClipDisabled()
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .focusSection()
    }

    private var addonsSection: some View {
        SettingsCard(title: "Stremio addons") {
            SettingsRow(
                title: "Addon Manager",
                subtitle: "\(addons.installed.count) installed · \(addons.enabledAddons.count) enabled",
                systemImage: "puzzlepiece.extension.fill",
                trailing: { SettingsValueLabel(value: "") },
                action: { router.push(.addonManager) }
            )
            SettingsRow(
                title: "Catalog Order",
                subtitle: "Choose which catalogs appear on Home and in what order",
                systemImage: "list.number",
                trailing: { SettingsValueLabel(value: "") },
                action: { router.push(.catalogOrder) }
            )
        }
    }
}

// MARK: - Standalone wrappers for pushed routes

struct ThemeSettingsView: View {
    var body: some View {
        NuvioScreenBackground {
            ScrollView { ThemeSettingsContent() }.scrollClipDisabled()
        }
    }
}

struct LayoutSettingsView: View {
    var body: some View {
        NuvioScreenBackground {
            ScrollView { LayoutSettingsContent() }.scrollClipDisabled()
        }
    }
}

struct PlaybackSettingsView: View {
    var body: some View {
        NuvioScreenBackground {
            ScrollView { PlaybackSettingsContent() }.scrollClipDisabled()
        }
    }
}

struct AboutView: View {
    var body: some View {
        NuvioScreenBackground {
            ScrollView { AboutContent() }.scrollClipDisabled()
        }
    }
}

// MARK: - Appearance (port of ThemeSettingsScreen)

struct ThemeSettingsContent: View {
    @Environment(\.nuvioColors) private var colors
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var app = settings.app

        VStack(alignment: .leading, spacing: NuvioTheme.components.settings.rowGap) {
            SettingsCard(title: "Accent theme") {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: NuvioTheme.spacing.md) {
                        ForEach(AppTheme.allCases) { theme in
                            ThemeSwatch(
                                theme: theme,
                                isSelected: app.theme == theme,
                                action: { app.theme = theme }
                            )
                        }
                    }
                    .padding(.vertical, NuvioTheme.spacing.xs)
                }
                .scrollClipDisabled()
            }

            SettingsCard(title: "Typeface") {
                ForEach(AppFont.allCases) { font in
                    SettingsRow(
                        title: font.displayName,
                        subtitle: font == app.font ? "Currently in use" : nil,
                        trailing: {
                            Image(systemName: app.font == font ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: NuvioTheme.sizes.icons.md))
                                .foregroundStyle(app.font == font ? colors.secondary : colors.textTertiary)
                        },
                        action: { app.font = font }
                    )
                }
            }

            SettingsCard(title: "Contrast", footnote: "AMOLED mode replaces the near-black background with pure black.") {
                SettingsToggle(
                    title: "AMOLED background",
                    subtitle: "Use pure black for the app background",
                    systemImage: "circle.lefthalf.filled",
                    isOn: $app.amoledMode
                )
                SettingsToggle(
                    title: "AMOLED surfaces",
                    subtitle: "Also flatten cards and panels to pure black",
                    systemImage: "square.stack.3d.up",
                    isOn: $app.amoledSurfaces
                )
            }

            SettingsCard(title: "Settings layout") {
                SettingsOptionRow(
                    title: "Presentation",
                    subtitle: "How this screen itself is laid out",
                    selection: $app.settingsUIStyle
                )
            }
        }
    }
}

private struct ThemeSwatch: View {
    @Environment(\.nuvioColors) private var colors
    let theme: AppTheme
    let isSelected: Bool
    let action: () -> Void

    private var palette: ThemeColorPalette { ThemeColors.palette(for: theme) }

    var body: some View {
        Button(action: action) {
            VStack(spacing: NuvioTheme.spacing.sm) {
                ZStack {
                    RoundedRectangle(cornerRadius: NuvioTheme.radii.md, style: .continuous)
                        .fill(palette.background)
                    Circle()
                        .fill(palette.secondary)
                        .frame(width: dp(34), height: dp(34))
                    if isSelected {
                        Image(systemName: "checkmark")
                            .font(.system(size: dp(16), weight: .bold))
                            .foregroundStyle(palette.onSecondary)
                    }
                }
                .frame(width: dp(96), height: dp(64))
                .overlay {
                    RoundedRectangle(cornerRadius: NuvioTheme.radii.md, style: .continuous)
                        .strokeBorder(isSelected ? palette.focusRing : .clear, lineWidth: NuvioTheme.strokes.medium)
                }

                Text(theme.displayName)
                    .nuvioText(NuvioTextStyles.metadata)
                    .foregroundStyle(isSelected ? colors.textPrimary : colors.textSecondary)
            }
        }
        .buttonStyle(NuvioCardButtonStyle(cornerRadius: NuvioTheme.radii.md, showsRing: true, elevated: false))
    }
}

// MARK: - Layout (port of LayoutSettingsScreen)

struct LayoutSettingsContent: View {
    @Environment(\.nuvioColors) private var colors
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var layout = settings.layout

        VStack(alignment: .leading, spacing: NuvioTheme.components.settings.rowGap) {
            SettingsCard(title: "Home layout") {
                ForEach(HomeLayout.allCases) { option in
                    SettingsRow(
                        title: option.displayName,
                        subtitle: option.summary,
                        systemImage: icon(for: option),
                        trailing: {
                            Image(systemName: layout.selectedLayout == option ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: NuvioTheme.sizes.icons.md))
                                .foregroundStyle(layout.selectedLayout == option ? colors.secondary : colors.textTertiary)
                        },
                        action: {
                            layout.selectedLayout = option
                            layout.hasChosenLayout = true
                        }
                    )
                }
            }

            SettingsCard(title: "Hero") {
                SettingsToggle(title: "Hero section", systemImage: "rectangle.inset.filled", isOn: $layout.heroSectionEnabled)
                SettingsToggle(
                    title: "Full-screen backdrop",
                    subtitle: "Let the hero image fill the whole screen in Modern view",
                    isOn: $layout.modernHeroFullScreenBackdrop
                )
                SettingsToggle(
                    title: "Classic focus gradient",
                    subtitle: "Tint the backdrop toward the focused poster",
                    isOn: $layout.classicFocusGradientEnabled
                )
            }

            SettingsCard(title: "Sidebar") {
                SettingsToggle(title: "Modern sidebar", systemImage: "sidebar.leading", isOn: $layout.modernSidebarEnabled)
                SettingsToggle(title: "Glass blur", isOn: $layout.modernSidebarBlurEnabled)
                SettingsToggle(title: "Collapsed by default", isOn: $layout.sidebarCollapsedByDefault)
                SettingsToggle(title: "Glass side panels", isOn: $layout.glassSidePanelEnabled)
            }

            SettingsCard(
                title: "Poster cards",
                footnote: "Sizes are in Android dp and scale automatically to the tvOS point grid."
            ) {
                SettingsStepperRow(title: "Width", value: $layout.posterCardWidthDp, range: 90...220, step: 2, format: { "\($0) dp" })
                SettingsStepperRow(title: "Height", value: $layout.posterCardHeightDp, range: 120...330, step: 3, format: { "\($0) dp" })
                SettingsStepperRow(title: "Corner radius", value: $layout.posterCardCornerRadiusDp, range: 0...28, format: { "\($0) dp" })
                SettingsToggle(title: "Show labels", subtitle: "Title and year under each poster", isOn: $layout.posterLabelsEnabled)
                SettingsToggle(title: "Landscape posters in Modern view", isOn: $layout.modernLandscapePostersEnabled)
            }

            SettingsCard(
                title: "Focused poster",
                footnote: "Holding focus on a card widens it into its backdrop — a Nuvio signature."
            ) {
                SettingsToggle(title: "Expand to backdrop", systemImage: "rectangle.expand.vertical", isOn: $layout.focusedPosterBackdropExpandEnabled)
                if layout.focusedPosterBackdropExpandEnabled {
                    SettingsStepperRow(title: "Expand after", value: $layout.focusedPosterBackdropExpandDelaySeconds, range: 0...10, format: { "\($0)s" })
                    // Android plays the TMDB trailer inline, which is a YouTube stream. tvOS has
                    // no WKWebView and AVPlayer cannot resolve a YouTube watch URL, so there is
                    // no way to honour this here — saying so beats an inert switch.
                    SettingsToggle(
                        title: "Play a trailer when expanded",
                        subtitle: "Unavailable on Apple TV — trailers are YouTube-only and tvOS cannot play them in-app",
                        isOn: $layout.focusedPosterBackdropTrailerEnabled
                    )
                    .disabled(true)
                }
            }

            SettingsCard(title: "Card depth") {
                SettingsToggle(title: "Depth effect", systemImage: "cube.transparent", isOn: $layout.cardDepthEnabled)
                if layout.cardDepthEnabled {
                    SettingsToggle(title: "Posters", isOn: $layout.cardDepthPostersEnabled)
                    SettingsToggle(title: "Continue Watching", isOn: $layout.cardDepthContinueWatchingEnabled)
                    SettingsToggle(title: "Episode cards", isOn: $layout.cardDepthEpisodeCardsEnabled)
                    SettingsToggle(title: "Cast", isOn: $layout.cardDepthCastEnabled)
                    SettingsToggle(title: "Trailers", isOn: $layout.cardDepthTrailersEnabled)
                    SettingsDecimalStepperRow(title: "Edge strength", value: $layout.cardDepthEdgeStrength, range: 0...1, step: 0.05, format: { String(format: "%.0f%%", $0 * 100) })
                    SettingsDecimalStepperRow(title: "Edge coverage", value: $layout.cardDepthEdgeCoverage, range: 0...1, step: 0.05, format: { String(format: "%.0f%%", $0 * 100) })
                    SettingsDecimalStepperRow(title: "Sheen", value: $layout.cardDepthSheenStrength, range: 0...1, step: 0.05, format: { String(format: "%.0f%%", $0 * 100) })
                }
            }

            SettingsCard(title: "Continue Watching") {
                SettingsOptionRow(title: "Card style", selection: $layout.continueWatchingCardStyle)
                SettingsOptionRow(title: "Sort", selection: $layout.continueWatchingSortMode)
                SettingsToggle(title: "Use episode thumbnails", isOn: $layout.useEpisodeThumbnailsInContinueWatching)
                SettingsToggle(title: "Blur next-up artwork", subtitle: "Avoid spoilers in the rail", isOn: $layout.blurContinueWatchingNextUp)
                SettingsToggle(title: "Blur unwatched episode stills", isOn: $layout.blurUnwatchedEpisodes)
                SettingsToggle(title: "Next up from furthest episode", isOn: $layout.nextUpFromFurthestEpisode)
                SettingsToggle(title: "Show unaired next up", isOn: $layout.showUnairedNextUp)
            }

            SettingsCard(title: "Catalogs") {
                SettingsToggle(title: "Show addon name", subtitle: "Next to each rail title", isOn: $layout.catalogAddonNameEnabled)
                SettingsToggle(title: "Show type suffix", subtitle: "Append Movies / Series to rail titles", isOn: $layout.catalogTypeSuffixEnabled)
                SettingsToggle(title: "Follow addon order", subtitle: "Order rails by the addon list rather than manually", isOn: $layout.followAddonsOrder)
            }

            SettingsCard(title: "Navigation") {
                SettingsOptionRow(title: "Discover placement", systemImage: "square.grid.2x2", selection: $layout.discoverLocation)
                SettingsToggle(title: "Discover inside Search", isOn: $layout.searchDiscoverEnabled)
                SettingsToggle(title: "Fast horizontal navigation", subtitle: "Skip the settle animation when holding a direction", isOn: $layout.fastHorizontalNavigationEnabled)
                SettingsToggle(title: "Smooth bring-into-view", isOn: $layout.smoothBringIntoViewEnabled)
            }

            SettingsCard(title: "Content") {
                SettingsToggle(title: "Hide unreleased content", isOn: $layout.hideUnreleasedContent)
                SettingsToggle(title: "Show full release date", subtitle: "Rather than only the year", isOn: $layout.showFullReleaseDate)
                SettingsToggle(title: "Trailer button on detail pages", isOn: $layout.detailPageTrailerButtonEnabled)
                SettingsToggle(title: "Prefer external meta addon", subtitle: "Use a non-Cinemeta addon for details when available", isOn: $layout.preferExternalMetaAddonDetail)
            }
        }
    }

    private func icon(for layout: HomeLayout) -> String {
        switch layout {
        case .classic: return "rectangle.grid.1x2.fill"
        case .grid: return "square.grid.3x3.fill"
        case .modern: return "rectangle.inset.filled"
        }
    }
}

// MARK: - Experience mode (port of ExperienceModeSelectionScreen)

struct ExperienceSettingsContent: View {
    @Environment(\.nuvioColors) private var colors
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var app = settings.app

        VStack(alignment: .leading, spacing: NuvioTheme.components.settings.rowGap) {
            SettingsCard(
                title: "Experience mode",
                footnote: "Essential hides the deep playback, debrid and integration surfaces."
            ) {
                ForEach(ExperienceMode.allCases) { mode in
                    SettingsRow(
                        title: mode.displayName,
                        subtitle: mode.summary,
                        systemImage: mode == .essential ? "leaf" : "slider.horizontal.3",
                        trailing: {
                            Image(systemName: app.experienceMode == mode ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: NuvioTheme.sizes.icons.md))
                                .foregroundStyle(app.experienceMode == mode ? colors.secondary : colors.textTertiary)
                        },
                        action: {
                            app.experienceMode = mode
                            app.experienceModeChosen = true
                        }
                    )
                }
            }
        }
    }
}

// MARK: - About (port of AboutScreen)

struct AboutContent: View {
    @Environment(\.nuvioColors) private var colors

    private var version: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(short) (\(build))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: NuvioTheme.components.settings.rowGap) {
            SettingsCard(title: "Nuvio for Apple TV") {
                VStack(alignment: .leading, spacing: NuvioTheme.spacing.md) {
                    Text("Nuvio")
                        .nuvioText(NuvioTextStyles.display)
                        .foregroundStyle(colors.textPrimary)
                    Text("Version \(version)")
                        .nuvioText(NuvioTextStyles.bodyCompact)
                        .foregroundStyle(colors.textSecondary)
                    Text("""
                    A tvOS client for the Stremio addon ecosystem, built to mirror the NuvioTV \
                    experience on Android TV. Nuvio is a playback interface only: it does not host, \
                    store or distribute any media. All content comes from the addons you install.
                    """)
                        .nuvioText(NuvioTextStyles.bodyCompact)
                        .foregroundStyle(colors.textSecondary)
                        .frame(maxWidth: dp(720), alignment: .leading)
                }
                .padding(.horizontal, NuvioTheme.spacing.lg)
                .padding(.vertical, NuvioTheme.spacing.sm)
            }
        }
    }
}
