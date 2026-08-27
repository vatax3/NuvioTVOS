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
        // Order and grouping mirror the Android rail: Account, Profiles, Appearance, Layout,
        // Content & Discovery, Integrations, Playback, Advanced, Tracking, About. Experience mode
        // is not a rail entry there either — it lives inside Advanced.
        case account, profiles, appearance, layout, contentDiscovery, integrations,
             playback, advanced, tracking, about
        var id: String { rawValue }

        var title: String {
            switch self {
            case .account: return L10n.text("settings.account")
            case .profiles: return L10n.text("settings.profiles")
            case .appearance: return L10n.text("settings.appearance")
            case .layout: return L10n.text("settings.layout")
            case .contentDiscovery: return L10n.text("settings.content_discovery")
            case .integrations: return L10n.text("settings.integrations")
            case .playback: return L10n.text("settings.playback")
            case .advanced: return L10n.text("settings.advanced")
            case .tracking: return L10n.text("settings.tracking")
            case .about: return L10n.text("settings.about")
            }
        }

        var systemImage: String {
            switch self {
            case .account: return "person.crop.circle"
            case .profiles: return "person.2.fill"
            case .appearance: return "paintpalette.fill"
            case .layout: return "rectangle.3.group.fill"
            case .contentDiscovery: return "square.grid.2x2.fill"
            case .integrations: return "link"
            case .playback: return "play.rectangle.fill"
            case .advanced: return "slider.horizontal.3"
            case .tracking: return "chart.line.uptrend.xyaxis"
            case .about: return "info.circle.fill"
            }
        }

        /// Essential mode hides the deep surfaces, matching the Android experience gate.
        /// The official rail hides nothing for Essential mode — it trims section *content*
        /// instead. Kept as a hook, but no section opts in.
        var isAdvancedOnly: Bool { false }

        /// Account and Profiles are owner-level surfaces: Android shows them only while the
        /// primary profile is active.
        var isPrimaryProfileOnly: Bool {
            self == .account || self == .profiles
        }

        /// A restricted profile must not be able to reach the settings that would let it lift
        /// its own restriction, or reconfigure sources for the whole household.
        var isBlockedWhenRestricted: Bool {
            switch self {
            case .contentDiscovery, .playback, .integrations, .advanced, .profiles, .account:
                return true
            default:
                return false
            }
        }
    }

    @State private var section: Section =
        LaunchArguments.settingsSection.flatMap(Section.init(rawValue:)) ?? .account

    private var isRestricted: Bool { profiles.activeProfile?.isRestricted ?? false }

    private var isPrimaryProfileActive: Bool {
        profiles.activeProfileId == ProfileScope.primaryProfileId
    }

    private var sections: [Section] {
        Section.allCases.filter { section in
            guard settings.app.showsAdvancedSettings || !section.isAdvancedOnly else { return false }
            guard isPrimaryProfileActive || !section.isPrimaryProfileOnly else { return false }
            return !(isRestricted && section.isBlockedWhenRestricted)
        }
    }

    /// Two-pane rail, or a single column you drill into — the reader for `settings_ui_style`,
    /// which had a picker in Advanced and changed nothing. The rail is right for a remote most of
    /// the time; the single list is the one that works when the section names are long, and it is
    /// what Android offers as the alternative.
    var body: some View {
        Group {
            switch settings.app.settingsUIStyle {
            case .rail:
                HStack(alignment: .top, spacing: NuvioTheme.spacing.xxl) {
                    rail
                    workspace
                }
            case .list:
                singleColumn
            }
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
                Text(L10n.text("navigation.settings"))
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

    @ViewBuilder
    private var sectionContent: some View {
        switch section {
        case .account: AccountSettingsContent()
        case .profiles: ProfilesSettingsContent()
        case .appearance: ThemeSettingsContent()
        case .layout: LayoutSettingsContent()
        case .contentDiscovery: ContentDiscoverySettingsContent()
        case .integrations: IntegrationsHubContent()
        case .playback:
            if settings.app.showsAdvancedSettings {
                PlaybackSettingsContent()
            } else {
                EssentialPlaybackSettingsContent()
            }
        case .advanced: AdvancedSettingsContent()
        case .tracking: TrackingSettingsContent()
        case .about: AboutContent()
        }
    }

    /// The single-list style: an index you drill into, and a way back out. `listSection` being
    /// nil *is* the index — there is no separate mode flag to keep in step with it.
    @State private var listSection: Section?

    private var singleColumn: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: NuvioTheme.components.settings.rowGap) {
                if listSection == nil {
                    Text(L10n.text("navigation.settings"))
                        .nuvioText(NuvioTextStyles.headline)
                        .foregroundStyle(colors.textPrimary)
                    SettingsCard {
                        ForEach(sections) { item in
                            SettingsRow(
                                title: item.title,
                                systemImage: item.systemImage,
                                trailing: { SettingsValueLabel(value: "") },
                                action: {
                                    section = item
                                    listSection = item
                                }
                            )
                        }
                    }
                } else {
                    SettingsRow(
                        title: L10n.text("navigation.settings"),
                        systemImage: "chevron.left",
                        action: { listSection = nil }
                    )
                    Text(section.title)
                        .nuvioText(NuvioTextStyles.headline)
                        .foregroundStyle(colors.textPrimary)
                    sectionContent
                }
            }
            .padding(.bottom, NuvioTheme.spacing.rail.tailPadding)
        }
        .id(listSection)
        .scrollClipDisabled()
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .focusSection()
    }

    private var workspace: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: NuvioTheme.components.settings.rowGap) {
                sectionContent
            }
            .padding(.bottom, NuvioTheme.spacing.rail.tailPadding)
        }
        // One scroll view served every section, and SwiftUI keeps a scroll offset for as long as
        // the view keeps its identity — so arriving at a section you had never opened could land
        // you halfway down it. Tying the identity to the section makes each one a fresh page.
        .id(section)
        .scrollClipDisabled()
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .focusSection()
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
            SettingsCard(title: L10n.text("settings.appearance.accent_theme", fallback: "Accent theme")) {
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
                .clippedHorizontalScroller()
            }

            SettingsCard(title: L10n.text("settings.appearance.typeface", fallback: "Typeface")) {
                ForEach(AppFont.allCases) { font in
                    SettingsRow(
                        title: font.displayName,
                        subtitle: font == app.font ? L10n.text("settings.appearance.currently_in_use", fallback: "Currently in use") : nil,
                        trailing: {
                            Image(systemName: app.font == font ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: NuvioTheme.sizes.icons.md))
                                .foregroundStyle(app.font == font ? colors.secondary : colors.textTertiary)
                        },
                        action: { app.font = font }
                    )
                }
            }

            SettingsCard(title: L10n.text("settings.appearance.contrast", fallback: "Contrast"), footnote: L10n.text("settings.appearance.amoled_footnote", fallback: "AMOLED mode replaces the near-black background with pure black.")) {
                SettingsToggle(
                    title: L10n.text("settings.appearance.amoled_background", fallback: "AMOLED background"),
                    subtitle: L10n.text("settings.appearance.amoled_background_subtitle", fallback: "Use pure black for the app background"),
                    systemImage: "circle.lefthalf.filled",
                    isOn: $app.amoledMode
                )
                SettingsToggle(
                    title: L10n.text("settings.appearance.amoled_surfaces", fallback: "AMOLED surfaces"),
                    subtitle: L10n.text("settings.appearance.amoled_surfaces_subtitle", fallback: "Also flatten cards and panels to pure black"),
                    systemImage: "square.stack.3d.up",
                    isOn: $app.amoledSurfaces
                )
            }

            SettingsCard(title: L10n.text("settings.appearance.settings_layout", fallback: "Settings layout")) {
                SettingsOptionRow(
                    title: L10n.text("settings.appearance.presentation", fallback: "Presentation"),
                    subtitle: L10n.text("settings.appearance.presentation_subtitle", fallback: "How this screen itself is laid out"),
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
            SettingsCard(title: L10n.text("settings.layout.home_layout", fallback: "Home layout")) {
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

            SettingsCard(title: L10n.text("settings.section.hero", fallback: "Hero")) {
                SettingsToggle(title: L10n.text("settings.layout.hero_section", fallback: "Hero section"), systemImage: "rectangle.inset.filled", isOn: $layout.heroSectionEnabled)
                SettingsToggle(
                    title: L10n.text("settings.layout.fullscreen_backdrop", fallback: "Full-screen backdrop"),
                    subtitle: L10n.text("settings.layout.fullscreen_backdrop_subtitle", fallback: "Let the hero image fill the whole screen in Modern view"),
                    isOn: $layout.modernHeroFullScreenBackdrop
                )
                SettingsToggle(
                    title: L10n.text("settings.layout.classic_focus_gradient", fallback: "Classic focus gradient"),
                    subtitle: L10n.text("settings.layout.classic_focus_gradient_subtitle", fallback: "Tint the backdrop toward the focused poster"),
                    isOn: $layout.classicFocusGradientEnabled
                )
            }

            SettingsCard(title: L10n.text("settings.section.sidebar", fallback: "Sidebar")) {
                SettingsToggle(title: L10n.text("settings.layout.modern_sidebar", fallback: "Modern sidebar"), systemImage: "sidebar.leading", isOn: $layout.modernSidebarEnabled)
                SettingsToggle(title: L10n.text("settings.layout.glass_blur", fallback: "Glass blur"), isOn: $layout.modernSidebarBlurEnabled)
                SettingsToggle(title: L10n.text("settings.layout.collapsed_by_default", fallback: "Collapsed by default"), isOn: $layout.sidebarCollapsedByDefault)
                SettingsToggle(title: L10n.text("settings.layout.glass_side_panels", fallback: "Glass side panels"), isOn: $layout.glassSidePanelEnabled)
            }

            SettingsCard(
                title: L10n.text("settings.layout.poster_cards", fallback: "Poster cards"),
                footnote: L10n.text("settings.layout.poster_cards_footnote", fallback: "Sizes are in Android dp and scale automatically to the tvOS point grid.")
            ) {
                SettingsStepperRow(title: L10n.text("settings.section.width", fallback: "Width"), value: $layout.posterCardWidthDp, range: 90...220, step: 2, format: { "\($0) dp" })
                SettingsStepperRow(title: L10n.text("settings.section.height", fallback: "Height"), value: $layout.posterCardHeightDp, range: 120...330, step: 3, format: { "\($0) dp" })
                SettingsStepperRow(title: L10n.text("settings.layout.corner_radius", fallback: "Corner radius"), value: $layout.posterCardCornerRadiusDp, range: 0...28, format: { "\($0) dp" })
                SettingsToggle(title: L10n.text("settings.layout.show_labels", fallback: "Show labels"), subtitle: L10n.text("settings.layout.show_labels_subtitle", fallback: "Title and year under each poster"), isOn: $layout.posterLabelsEnabled)
                SettingsToggle(title: L10n.text("settings.layout.landscape_posters", fallback: "Landscape posters in Modern view"), isOn: $layout.modernLandscapePostersEnabled)
            }

            SettingsCard(
                title: L10n.text("settings.layout.focused_poster", fallback: "Focused poster"),
                footnote: L10n.text("settings.layout.focused_poster_footnote", fallback: "Holding focus on a card widens it into its backdrop — a Nuvio signature.")
            ) {
                SettingsToggle(title: L10n.text("settings.layout.expand_to_backdrop", fallback: "Expand to backdrop"), systemImage: "rectangle.expand.vertical", isOn: $layout.focusedPosterBackdropExpandEnabled)
                if layout.focusedPosterBackdropExpandEnabled {
                    SettingsStepperRow(title: L10n.text("settings.layout.expand_after", fallback: "Expand after"), value: $layout.focusedPosterBackdropExpandDelaySeconds, range: 0...10, format: { "\($0)s" })
                }
            }

            SettingsCard(title: L10n.text("settings.layout.card_depth", fallback: "Card depth")) {
                SettingsToggle(title: L10n.text("settings.layout.depth_effect", fallback: "Depth effect"), systemImage: "cube.transparent", isOn: $layout.cardDepthEnabled)
                if layout.cardDepthEnabled {
                    SettingsToggle(title: L10n.text("settings.section.posters", fallback: "Posters"), isOn: $layout.cardDepthPostersEnabled)
                    SettingsToggle(title: L10n.text("settings.section.continue_watching", fallback: "Continue Watching"), isOn: $layout.cardDepthContinueWatchingEnabled)
                    SettingsToggle(title: L10n.text("settings.layout.episode_cards", fallback: "Episode cards"), isOn: $layout.cardDepthEpisodeCardsEnabled)
                    SettingsToggle(title: L10n.text("settings.section.cast", fallback: "Cast"), isOn: $layout.cardDepthCastEnabled)
                    SettingsToggle(title: L10n.text("settings.section.trailers", fallback: "Trailers"), isOn: $layout.cardDepthTrailersEnabled)
                    SettingsDecimalStepperRow(title: L10n.text("settings.layout.edge_strength", fallback: "Edge strength"), value: $layout.cardDepthEdgeStrength, range: 0...1, step: 0.05, format: { String(format: "%.0f%%", $0 * 100) })
                    SettingsDecimalStepperRow(title: L10n.text("settings.layout.edge_coverage", fallback: "Edge coverage"), value: $layout.cardDepthEdgeCoverage, range: 0...1, step: 0.05, format: { String(format: "%.0f%%", $0 * 100) })
                    SettingsDecimalStepperRow(title: L10n.text("settings.layout.sheen", fallback: "Sheen"), value: $layout.cardDepthSheenStrength, range: 0...1, step: 0.05, format: { String(format: "%.0f%%", $0 * 100) })
                }
            }

            SettingsCard(title: L10n.text("settings.section.ratings", fallback: "Ratings")) {
                SettingsOptionRow(title: L10n.text("settings.layout.on_home", fallback: "On Home"), selection: $layout.homeRatingsVisibility)
                SettingsOptionRow(
                    title: L10n.text("settings.layout.on_detail", fallback: "On a title's page"),
                    subtitle: layout.detailRatingsVisibility.summary,
                    selection: $layout.detailRatingsVisibility
                )
            }

            SettingsCard(title: L10n.text("settings.section.continue_watching", fallback: "Continue Watching")) {
                SettingsToggle(
                    title: L10n.text("settings.layout.show_the_rail", fallback: "Show the rail"),
                    subtitle: L10n.text("settings.layout.show_the_rail_subtitle", fallback: "Off hides what you are part-way through from Home entirely"),
                    isOn: $layout.continueWatchingEnabled
                )
                SettingsOptionRow(title: L10n.text("settings.layout.card_style", fallback: "Card style"), selection: $layout.continueWatchingCardStyle)
                SettingsOptionRow(title: L10n.text("settings.section.sort", fallback: "Sort"), selection: $layout.continueWatchingSortMode)
                SettingsToggle(title: L10n.text("settings.layout.use_episode_thumbnails", fallback: "Use episode thumbnails"), isOn: $layout.useEpisodeThumbnailsInContinueWatching)
                SettingsToggle(title: L10n.text("settings.layout.blur_next_up", fallback: "Blur next-up artwork"), subtitle: L10n.text("settings.layout.blur_next_up_subtitle", fallback: "Avoid spoilers in the rail"), isOn: $layout.blurContinueWatchingNextUp)
                SettingsToggle(title: L10n.text("settings.layout.blur_unwatched", fallback: "Blur unwatched episode stills"), isOn: $layout.blurUnwatchedEpisodes)
                SettingsToggle(title: L10n.text("settings.layout.next_up_furthest", fallback: "Next up from furthest episode"), isOn: $layout.nextUpFromFurthestEpisode)
                SettingsToggle(title: L10n.text("settings.layout.show_unaired", fallback: "Show unaired next up"), isOn: $layout.showUnairedNextUp)
            }

            SettingsCard(
                title: L10n.text("settings.section.collections", fallback: "Collections"),
                footnote: L10n.text("settings.layout.collections_footnote", fallback: "Your own folders of titles, built from the Library tab.")
            ) {
                SettingsToggle(
                    title: L10n.text("settings.layout.collections_on_home", fallback: "Show on Home"),
                    subtitle: L10n.text("settings.layout.collections_on_home_subtitle", fallback: "One rail per collection, after your catalogs"),
                    isOn: $layout.collectionsOnHomeEnabled
                )
            }

            SettingsCard(title: L10n.text("settings.section.library", fallback: "Library")) {
                SettingsOptionRow(title: L10n.text("settings.layout.sort_saved", fallback: "Sort saved titles"), selection: $layout.librarySortOption)
            }

            SettingsCard(title: L10n.text("settings.section.catalogs", fallback: "Catalogs")) {
                SettingsToggle(title: L10n.text("settings.layout.show_addon_name", fallback: "Show addon name"), subtitle: L10n.text("settings.layout.show_addon_name_subtitle", fallback: "Next to each rail title"), isOn: $layout.catalogAddonNameEnabled)
                SettingsToggle(title: L10n.text("settings.layout.show_type_suffix", fallback: "Show type suffix"), subtitle: L10n.text("settings.layout.show_type_suffix_subtitle", fallback: "Append Movies / Series to rail titles"), isOn: $layout.catalogTypeSuffixEnabled)
                SettingsToggle(title: L10n.text("settings.layout.follow_addon_order", fallback: "Follow addon order"), subtitle: L10n.text("settings.layout.follow_addon_order_subtitle", fallback: "Order rails by the addon list rather than manually"), isOn: $layout.followAddonsOrder)
            }

            SettingsCard(title: L10n.text("settings.section.navigation", fallback: "Navigation")) {
                SettingsOptionRow(title: L10n.text("settings.layout.discover_placement", fallback: "Discover placement"), systemImage: "square.grid.2x2", selection: $layout.discoverLocation)
                SettingsToggle(title: L10n.text("settings.layout.discover_in_search", fallback: "Discover inside Search"), isOn: $layout.searchDiscoverEnabled)
                SettingsToggle(title: L10n.text("settings.layout.fast_horizontal", fallback: "Fast horizontal navigation"), subtitle: L10n.text("settings.layout.fast_horizontal_subtitle", fallback: "Skip the settle animation when holding a direction"), isOn: $layout.fastHorizontalNavigationEnabled)
                SettingsToggle(title: L10n.text("settings.layout.smooth_scroll", fallback: "Smooth bring-into-view"), isOn: $layout.smoothBringIntoViewEnabled)
            }

            SettingsCard(title: L10n.text("settings.section.content", fallback: "Content")) {
                SettingsToggle(title: L10n.text("settings.layout.hide_unreleased", fallback: "Hide unreleased content"), isOn: $layout.hideUnreleasedContent)
                SettingsToggle(title: L10n.text("settings.layout.full_release_date", fallback: "Show full release date"), subtitle: L10n.text("settings.layout.full_release_date_subtitle", fallback: "Rather than only the year"), isOn: $layout.showFullReleaseDate)
                SettingsToggle(title: L10n.text("settings.layout.trailer_button", fallback: "Trailer button on detail pages"), isOn: $layout.detailPageTrailerButtonEnabled)
                SettingsToggle(title: L10n.text("settings.layout.prefer_external_meta", fallback: "Prefer external meta addon"), subtitle: L10n.text("settings.layout.prefer_external_meta_subtitle", fallback: "Use a non-Cinemeta addon for details when available"), isOn: $layout.preferExternalMetaAddonDetail)
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
                title: L10n.text("settings.experience_mode", fallback: "Experience mode"),
                footnote: L10n.text("settings.experience_mode_footnote", fallback: "Essential hides the deep playback, debrid and integration surfaces.")
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

    /// Checked when this screen opens, not at launch. A sideloaded build cannot update itself on
    /// tvOS, so the most an update check can do is tell you — and a thing that can only tell you
    /// does not need to reach the network before you have asked.
    @State private var update: AppUpdateCheck.Available?

    private var version: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(short) (\(build))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: NuvioTheme.components.settings.rowGap) {
            updateCard

            SettingsCard(title: L10n.text("settings.about.app_name", fallback: "Nuvio for Apple TV")) {
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
                    Text(L10n.text("about.made_with_love"))
                        .nuvioText(NuvioTextStyles.metadata)
                        .foregroundStyle(colors.textTertiary)
                }
                .padding(.horizontal, NuvioTheme.spacing.lg)
                .padding(.vertical, NuvioTheme.spacing.sm)
                .frame(maxWidth: .infinity, alignment: .leading)
                // About and Licences are the only screens made entirely of text. tvOS scrolls by
                // moving focus into something below the fold, so with nothing focusable anywhere
                // on the page it simply would not move — reported as About not scrolling.
                .readableBlock()
            }

            LicensesContent()
        }
        .task {
            update = await AppUpdateCheck.fetch(current: AppUpdateCheck.currentVersion)
        }
    }

    @ViewBuilder
    private var updateCard: some View {
        if let update {
            SettingsCard(title: L10n.text("settings.about.update_available", fallback: "Update available")) {
                VStack(alignment: .leading, spacing: NuvioTheme.spacing.sm) {
                    Text("Version \(update.version)")
                        .nuvioText(NuvioTextStyles.cardTitle)
                        .foregroundStyle(colors.textPrimary)
                    Text("""
                    Nuvio cannot install this itself — a sideloaded app on tvOS has no way to \
                    replace itself. Sideload it the way you installed this one; your \
                    sideloading app will already be offering it if it follows the Nuvio source.
                    """)
                        .nuvioText(NuvioTextStyles.bodyCompact)
                        .foregroundStyle(colors.textSecondary)
                        .frame(maxWidth: dp(720), alignment: .leading)
                    if !update.notes.isEmpty {
                        Text(update.notes)
                            .nuvioText(NuvioTextStyles.metadata)
                            .foregroundStyle(colors.textTertiary)
                            .frame(maxWidth: dp(720), alignment: .leading)
                    }
                }
                .padding(.horizontal, NuvioTheme.spacing.lg)
                .padding(.vertical, NuvioTheme.spacing.sm)
                .frame(maxWidth: .infinity, alignment: .leading)
                .readableBlock()
            }
        }
    }
}
