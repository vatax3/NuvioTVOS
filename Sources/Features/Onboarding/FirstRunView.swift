import SwiftUI

/// The first-launch walk-through: experience mode, home layout, essential add-ons.
///
/// Upstream has three screens here — `ExperienceModeSelectionScreen`, `LayoutSelectionScreen`
/// and `EssentialAddonSetupScreen` — and this port had none of them. The choices themselves were
/// all reachable in Settings, and both "have they chosen yet" flags were *written* there and read
/// by nothing, so the flow could never start. This is that reader.
///
/// Deliberately one screen with three steps rather than three pushed screens: on a remote, Back
/// out of step two should return to step one, not leave a half-configured app, and a single
/// `@State` step makes that true by construction.
struct FirstRunView: View {
    @Environment(\.nuvioColors) private var colors
    @Environment(AppSettings.self) private var settings
    @Environment(AddonStore.self) private var addons

    /// Whether a fresh install should see this at all.
    ///
    /// Keyed on the experience-mode flag, and on the add-on list still being the two seeded
    /// defaults. Someone upgrading from an earlier build has a configured app and no business
    /// being walked through setup, and the second test is what tells the two apart.
    @MainActor
    static func shouldPresent(settings: AppSettings, addons: AddonStore) -> Bool {
        // A UI test launches into a fresh container, which is exactly the state this screen is
        // for — and it would sit in front of whatever the test came to exercise.
        guard !LaunchArguments.isUITesting else { return false }
        return !settings.app.experienceModeChosen
            && addons.installed.count <= AddonStore.defaultAddonURLs.count
    }

    enum Step: Int, CaseIterable {
        case experience, layout, addons

        var title: String {
            switch self {
            case .experience: return L10n.text("firstrun.experience_title", fallback: "How much do you want to see?")
            case .layout: return L10n.text("firstrun.layout_title", fallback: "Choose your home screen")
            case .addons: return L10n.text("firstrun.addons_title", fallback: "Add your sources")
            }
        }

        var subtitle: String {
            switch self {
            case .experience:
                return L10n.text("firstrun.experience_sub", fallback: "Essential keeps Settings short. Advanced opens the playback, debrid and integration surfaces. You can change this later.")
            case .layout:
                return L10n.text("firstrun.layout_sub", fallback: "All three show the same catalogues — they differ in how much room the artwork gets.")
            case .addons:
                return L10n.text("firstrun.addons_sub", fallback: "Nuvio has no catalogue of its own: add-ons provide everything you browse and play. Cinemeta and OpenSubtitles are already installed.")
            }
        }
    }

    let onFinish: () -> Void

    @State private var step: Step = .experience
    @State private var installing: String?
    @State private var installed: Set<String> = []
    @State private var failed: Set<String> = []

    /// The same list the Add-on Manager offers, minus the two that ship installed.
    private static let suggestions: [(name: String, detail: String, url: String)] = [
        ("Torrentio", L10n.text("firstrun.torrentio_sub", fallback: "Torrent sources — configure it for debrid afterwards"), "https://torrentio.strem.fun"),
        ("Anime Kitsu", L10n.text("firstrun.kitsu_sub", fallback: "Anime catalogue and metadata"), "https://anime-kitsu.strem.fun"),
        ("Public Domain Movies", L10n.text("firstrun.publicdomain_sub", fallback: "Freely licensed classics, nothing to configure"), "https://public-domain-movies.now.sh")
    ]

    var body: some View {
        NuvioScreenBackground {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: NuvioTheme.components.settings.rowGap) {
                    header
                    switch step {
                    case .experience: experienceStep
                    case .layout: layoutStep
                    case .addons: addonStep
                    }
                    footer
                }
                .frame(maxWidth: dp(900), alignment: .leading)
                .padding(.horizontal, NuvioTheme.layout.tvSafeHorizontal)
                .padding(.vertical, NuvioTheme.layout.tvSafeVertical)
            }
            .scrollClipDisabled()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: NuvioTheme.spacing.sm) {
            Text("Step \(step.rawValue + 1) of \(Step.allCases.count)")
                .nuvioText(NuvioTextStyles.tab)
                .foregroundStyle(colors.textTertiary)
            Text(step.title)
                .nuvioText(NuvioTextStyles.display)
                .foregroundStyle(colors.textPrimary)
            Text(step.subtitle)
                .nuvioText(NuvioTextStyles.bodyCompact)
                .foregroundStyle(colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, NuvioTheme.spacing.md)
    }

    // MARK: Steps

    private var experienceStep: some View {
        SettingsCard {
            ForEach(ExperienceMode.allCases) { mode in
                SettingsRow(
                    title: mode.displayName,
                    subtitle: mode.summary,
                    systemImage: mode == .essential ? "leaf" : "slider.horizontal.3",
                    trailing: { selectionMark(settings.app.experienceMode == mode) },
                    action: {
                        settings.app.experienceMode = mode
                        step = .layout
                    }
                )
            }
        }
    }

    private var layoutStep: some View {
        SettingsCard {
            ForEach(HomeLayout.allCases) { option in
                SettingsRow(
                    title: option.displayName,
                    subtitle: option.summary,
                    systemImage: icon(for: option),
                    trailing: { selectionMark(settings.layout.selectedLayout == option) },
                    action: {
                        settings.layout.selectedLayout = option
                        settings.layout.hasChosenLayout = true
                        step = .addons
                    }
                )
            }
        }
    }

    private var addonStep: some View {
        SettingsCard(
            footnote: "Every one of these can be added or removed later in Settings → Sources → Add-ons, along with any other Stremio add-on URL."
        ) {
            ForEach(Self.suggestions, id: \.url) { suggestion in
                SettingsRow(
                    title: suggestion.name,
                    subtitle: statusLine(for: suggestion),
                    systemImage: "puzzlepiece.extension",
                    trailing: {
                        if installing == suggestion.url {
                            ProgressView()
                        } else {
                            selectionMark(installed.contains(suggestion.url))
                        }
                    },
                    action: { install(suggestion.url) }
                )
                .disabled(installing != nil || installed.contains(suggestion.url))
            }
        }
    }

    // MARK: Chrome

    private var footer: some View {
        HStack(spacing: NuvioTheme.spacing.lg) {
            if step != .experience {
                Button(action: { step = Step(rawValue: step.rawValue - 1) ?? .experience }) {
                    Text("Back").nuvioText(NuvioTextStyles.button)
                        .padding(.horizontal, NuvioTheme.spacing.xl)
                        .padding(.vertical, NuvioTheme.spacing.md)
                }
                .buttonStyle(NuvioRowButtonStyle(cornerRadius: NuvioTheme.radii.full, scaleOnFocus: false))
            }

            Button(action: advance) {
                Text(step == .addons ? L10n.text("firstrun.start_watching", fallback: "Start watching") : "Skip")
                    .nuvioText(NuvioTextStyles.button)
                    .padding(.horizontal, NuvioTheme.spacing.xl)
                    .padding(.vertical, NuvioTheme.spacing.md)
            }
            .buttonStyle(NuvioRowButtonStyle(cornerRadius: NuvioTheme.radii.full, scaleOnFocus: false))
        }
        .padding(.top, NuvioTheme.spacing.lg)
    }

    private func selectionMark(_ isOn: Bool) -> some View {
        Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
            .font(.system(size: NuvioTheme.sizes.icons.md))
            .foregroundStyle(isOn ? colors.secondary : colors.textTertiary)
    }

    private func icon(for layout: HomeLayout) -> String {
        switch layout {
        case .classic: return "rectangle.grid.1x2"
        case .grid: return "square.grid.3x3"
        case .modern: return "rectangle.on.rectangle"
        }
    }

    private func statusLine(for suggestion: (name: String, detail: String, url: String)) -> String {
        if installed.contains(suggestion.url) { return "Installed" }
        if failed.contains(suggestion.url) { return L10n.text("firstrun.unreachable", fallback: "Could not be reached — try again from Settings later") }
        return suggestion.detail
    }

    // MARK: Actions

    private func advance() {
        switch step {
        case .experience: step = .layout
        case .layout: step = .addons
        case .addons: finish()
        }
    }

    /// Written here rather than at each choice: the walk-through is done when the viewer leaves
    /// it, whether they chose everything or skipped straight through. Setting it early would mean
    /// an app killed mid-setup never offers the rest.
    private func finish() {
        settings.app.experienceModeChosen = true
        onFinish()
    }

    private func install(_ url: String) {
        installing = url
        failed.remove(url)
        Task {
            let result = await addons.install(url: url)
            installing = nil
            switch result {
            case .success: installed.insert(url)
            case .failure: failed.insert(url)
            }
        }
    }
}
