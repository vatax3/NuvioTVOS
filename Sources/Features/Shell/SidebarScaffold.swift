import SwiftUI

/// Port of `ModernSidebarScaffold` + `ModernSidebarBlurPanel` + `CollapsedSidebarPill`.
///
/// Behaviour on Android: content is full-bleed, a floating pill sits at the top-left, and
/// pressing LEFT from content blooms it into a glass panel listing every destination.
/// Here the pill *is* the selected nav item, so moving focus left lands on it and the panel
/// expands around it — focus never has to be moved programmatically, which keeps the
/// transition smooth on the tvOS focus engine.
struct SidebarScaffold<Content: View>: View {
    @Environment(\.nuvioColors) private var colors
    @Environment(Router.self) private var router
    @Environment(AppSettings.self) private var settings
    @Environment(ProfileStore.self) private var profiles
    @Environment(\.resetFocus) private var resetFocus

    @ViewBuilder var content: Content

    @FocusState private var focusedTab: RootTab?
    @State private var isExpanded = false
    /// The panel may only bloom open once the viewer has actually driven the D-pad. At cold
    /// start tvOS parks focus on whatever is focusable first — here the pill — and without
    /// this gate the menu would be wide open on the first frame, which Android never does.
    @State private var hasUserNavigated = false
    /// Held between "panel closed" and "focus released" so the focus observer cannot re-open it.
    @State private var isDismissing = false
    @State private var focusReclaim: Task<Void, Never>?
    /// Set by any directional press, cleared when a destination is opened. While the reclaim
    /// loop below is running, a move means the viewer has taken over and it must stand down.
    @State private var hasMovedSinceTabChange = false
    @Namespace private var shellFocus

    private var tokens: NuvioSidebarComponentTokens { NuvioTheme.components.sidebar }

    /// Discover only earns a nav entry when the viewer put it there; the other two placements
    /// either fold it into Search or drop it entirely.
    private var tabs: [RootTab] {
        RootTab.allCases.filter { $0 != .discover || settings.layout.discoverLocation == .sidebar }
    }

    /// `modern_sidebar_enabled` off means the classic always-open rail: no pill, no bloom.
    private var isModernSidebar: Bool { settings.layout.modernSidebarEnabled }

    /// Where the content starts. Every destination gets the same gap, and the gap is at least
    /// the rail's own width — which is the point, not a detail of spacing.
    ///
    /// A leftward move only considers candidates whose frame lies to the left of the focused
    /// item. Home used to pull its whole hero full-bleed with a negative inset, so the content
    /// sat on top of the rail column: from any row below the first there was nothing to the left
    /// of it and the menu could only be reached from the very top of the page. Keeping the
    /// content clear of the column is what buys the same gesture, from any row, on every screen.
    ///
    /// The artwork is not part of that bargain, and for a while it was: the backdrop stopped
    /// where the column did, leaving a hard vertical seam and a tenth of the screen of flat grey
    /// down the left-hand side, which somebody watching on a real television reported. The gap
    /// is published as `\.shellLeadingInset` instead, and each screen's backdrop paints back
    /// over the column without moving a single focusable frame. See `bleedingLeading`.
    private var contentLeadingOffset: CGFloat {
        guard isModernSidebar else { return NuvioTheme.components.sidebar.expandedWidth }
        return max(NuvioTheme.layout.sidebarContentOffset, railColumnWidth)
    }

    /// How far the pills sit from the physical left edge of the screen.
    ///
    /// tvOS already insets the whole scene by 80pt horizontally — the title-safe margin every
    /// television is guaranteed to show — so this is what gets added on top of it, and it used to
    /// be another 28. Measured on a panel that was showing the result, the menu began a tenth of
    /// the way across the screen with nothing in front of it, which is the "wasted space" that
    /// was reported. A small gap on top of the safe margin is the tightest the pills can sit
    /// without gambling on a set with overscan.
    private var railLeadingPadding: CGFloat { NuvioTheme.spacing.xs }

    /// Width reserved for the sidebar column: the collapsed pill and its own padding, nothing
    /// more. The expanded panel deliberately overflows this rather than widening it.
    private var railColumnWidth: CGFloat {
        guard isModernSidebar else { return NuvioTheme.components.sidebar.expandedWidth }
        // The pill is the leading visual plus the dp(5) it is padded by on each side.
        return railLeadingPadding + NuvioTheme.components.sidebar.leadingVisual + dp(10)
            + NuvioTheme.spacing.sm
    }

    var body: some View {
        // An HStack, not the ZStack the visual design suggests. As overlapping layers the pill
        // and the content are not neighbours in any direction, so LEFT — the whole interaction
        // on Android — had nothing to travel to. As columns they are, and the pill's own focus
        // frame (see `stretchesVertically`) covers the height that makes the move resolve.
        //
        // The column stays at the collapsed width. The expanded panel is wider and simply
        // overflows it, so blooming open never reflows the content behind it.
        HStack(spacing: 0) {
            sidebar
                .padding(.leading, railLeadingPadding)
                .padding(.top, NuvioTheme.spacing.lg)
                .padding(.bottom, NuvioTheme.spacing.md)
                .padding(.trailing, NuvioTheme.spacing.sm)
                .frame(width: railColumnWidth, alignment: isExpanded ? .topLeading : .leading)
                // Full height *before* the focus section, which is the whole trick. A
                // directional move only considers candidates whose frame overlaps the band it
                // projects, and the pill sits at the very top — from a row further down the
                // screen there is simply nothing to the left of it. A focus section spanning the
                // full height is always in that band, and the engine redirects into it to the
                // nearest focusable item, which is the pill.
                .frame(maxHeight: .infinity, alignment: .top)
                .focusSection()
                // RIGHT is the way back to the content. It cannot be left to the focus engine:
                // the content is disabled while the panel is open, so there is nothing to the
                // right to move to until the panel closes.
                .onMoveCommand { direction in
                    if direction == .right, isExpanded { collapse() }
                }
                .zIndex(1)

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .focusSection()
                // Without this the engine hands first focus to the sidebar, which would open
                // the panel on launch. Android starts with the pill collapsed and content live.
                .prefersDefaultFocus(in: shellFocus)
                // `NuvioLayout.sidebarContentOffset` on Android: screens that start with a
                // top-left title are nudged clear of the floating pill. The column already
                // supplies part of that gap, so only the remainder is padded here.
                .padding(.leading, contentLeadingOffset - railColumnWidth)
                // What the column took, so a screen's backdrop can give it back. Nothing about
                // the layout changes — see `fullBleedLeading`, which paints rather than moves.
                .environment(\.shellLeadingInset, contentLeadingOffset)
                // Android's `sidebarBlocksContentKeys`: while the panel is open the content
                // stops taking input entirely. Without it the panel — which overlays the
                // content rather than displacing it — competes with whatever sits underneath,
                // so moving between destinations drops focus into the content and the panel
                // collapses out from under the viewer.
                .disabled(isExpanded)
        }
        .background(colors.background)
        .focusScope(shellFocus)
        .onMoveCommand { _ in
            hasUserNavigated = true
            hasMovedSinceTabChange = true
        }
        // Android's `BackHandler` on the root routes: back opens the drawer and puts focus on
        // the current destination rather than leaving the screen. Without it the panel is only
        // reachable by a directional move, which the Home hero can swallow.
        .onExitCommand { toggleFromBackButton() }
        .onChange(of: focusedTab) { _, newValue in
            updateExpansion(focusedTab: newValue)
        }
        .onChange(of: hasUserNavigated) { _, _ in
            updateExpansion(focusedTab: focusedTab)
        }
        .onChange(of: isModernSidebar, initial: true) { _, _ in
            updateExpansion(focusedTab: focusedTab)
        }
        // Switching destination swaps the whole content subtree. `collapse()` releases the
        // sidebar's focus on the next tick, and if the incoming screen has not laid out
        // anything focusable by then — which is every screen whose first row is waiting on a
        // catalogue — tvOS drops focus entirely and never looks again. The remote then does
        // nothing at all until the viewer stumbles back through the menu. Asking the focus
        // engine to redo its default-focus pass, a few times while the screen fills in, is what
        // makes a destination usable the moment it is chosen.
        .onChange(of: router.selectedTab, initial: true) { _, _ in
            hasMovedSinceTabChange = false
            reclaimContentFocus()
        }
    }

    /// Back opens the panel on the current destination; pressing it again hands focus back to
    /// the content. Android exits the app on that second press, which tvOS neither allows nor
    /// expects — the Home button already does it.
    private func toggleFromBackButton() {
        guard router.contentHasFocusableViews else { return }
        if isExpanded { collapse() } else { expand() }
    }

    /// The engine only picks a default when the scope has a candidate, so this retries across
    /// the first second of a screen's life.
    ///
    /// It has to stop the moment it is no longer needed, and for a long time it did not. Each
    /// pass calls `resetFocus`, which sends focus back to the scope's default item — so a viewer
    /// who started moving around within that first second had the screen snatched back under
    /// them, at 200ms, at 500ms, at 900ms. That is the "sometimes the focus jumps back" this
    /// guards: two stop conditions, either of which means the job is done.
    private func reclaimContentFocus() {
        focusReclaim?.cancel()
        focusReclaim = Task { @MainActor in
            for delay in [120, 200, 500, 900] {
                try? await Task.sleep(for: .milliseconds(delay))
                guard !Task.isCancelled, !isExpanded else { return }
                // The viewer is driving. Anywhere they have moved to is a better answer than
                // the default, and overriding it is what made the remote feel unreliable. This
                // is the only reason to stand down.
                guard !hasMovedSinceTabChange else { return }
                // Focus parked on the menu is not "done": it is the exact failure this exists to
                // repair. A screen still fetching its first catalogue has nothing focusable, the
                // engine takes the nearest thing that is — the rail — and stays there once the
                // posters arrive. Used to be a reason to give up, which is why the app could open
                // with the menu lit and the content dead.
                if focusedTab == nil {
                    // Something in the content has taken focus, which is the whole objective.
                    // Asked of UIKit rather than of `@FocusState`, which reports back only what
                    // was last requested — see `FocusSystemProbe`.
                    guard !FocusSystemProbe.hasFocusedItem else { return }
                }
                resetFocus(in: shellFocus)
            }
        }
    }

    private func expand() {
        guard isModernSidebar, !isExpanded else { return }
        hasUserNavigated = true
        isDismissing = false
        withAnimation(NuvioMotion.sidebarPanelIn) { isExpanded = true }
        focusedTab = router.selectedTab
    }

    /// Closing has to happen in this order, and it is the whole reason the panel is not simply
    /// derived from `focusedTab`.
    ///
    /// The content is disabled while the panel is open, so clearing focus first leaves the engine
    /// with nowhere to put it: focus snaps back to the pill, which re-opens the panel, and the
    /// menu becomes impossible to dismiss on any screen whose content does not steal focus back
    /// by itself. So the panel closes first — re-enabling the content — and focus is released
    /// only on the next tick, with `isDismissing` holding the focus observer off in between.
    private func collapse() {
        guard isExpanded else { return }
        isDismissing = true
        withAnimation(NuvioMotion.sidebarPanelOut) { isExpanded = false }
        Task { @MainActor in
            focusedTab = nil
            try? await Task.sleep(for: .milliseconds(250))
            isDismissing = false
        }
    }

    private func updateExpansion(focusedTab: RootTab?) {
        // The classic rail is always open; only the modern pill collapses.
        guard isModernSidebar else {
            if !isExpanded { isExpanded = true }
            return
        }
        // `sidebar_collapsed_by_default` off means the panel starts — and stays — open.
        guard settings.layout.sidebarCollapsedByDefault else {
            if !isExpanded { isExpanded = true }
            return
        }
        guard !isDismissing else { return }
        // Focus arriving on the pill — via LEFT — is what opens the panel. Focus leaving is not
        // what closes it; `collapse()` is, so that the order above is always respected.
        if focusedTab != nil, hasUserNavigated, !isExpanded {
            withAnimation(NuvioMotion.sidebarPanelIn) { isExpanded = true }
        }
    }

    // MARK: Panel

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: NuvioTheme.spacing.sm - NuvioTheme.spacing.xxs) {
                ForEach(visibleTabs, id: \.self) { tab in
                    SidebarItemView(
                        tab: tab,
                        isSelected: router.selectedTab == tab,
                        showsLabel: isExpanded,
                        action: { select(tab) }
                    )
                    .focused($focusedTab, equals: tab)
                    .disabled(!router.contentHasFocusableViews)
                }

                if isExpanded, profiles.hasMultipleProfiles,
                   let active = profiles.activeProfile {
                    profileRow(active)
                }
            }
            // Centred while collapsed, as Android centres its icon column. It is also what keeps
            // a leftward move resolving from a row halfway down the screen: the column's focus
            // section spans the full height, and the engine redirects into it to the nearest
            // focusable item — which is much nearer from the middle than from the top corner.
            .frame(maxHeight: .infinity, alignment: isExpanded ? .top : .center)
        }
        .padding(.horizontal, isExpanded ? NuvioTheme.spacing.sm : 0)
        .padding(.vertical, isExpanded ? NuvioTheme.spacing.sm : 0)
        .frame(width: isExpanded ? tokens.expandedWidth : nil, alignment: .leading)
        .frame(maxHeight: .infinity, alignment: isExpanded ? .top : .center)
        .background {
            if isExpanded {
                panelBackground
            }
        }
        .animation(NuvioMotion.sidebarPanelIn, value: isExpanded)
    }

    /// The active profile, sitting under the destinations, opening the chooser.
    ///
    /// Android puts the same entry here, and it is not decoration: Account and Profiles are
    /// primary-profile-only settings sections in both apps, so on any other profile this is the
    /// only route back to the picker.
    private func profileRow(_ profile: Profile) -> some View {
        Button(action: { profiles.requestSelection() }) {
            HStack(spacing: tokens.contentGap) {
                ProfileAvatar(profile: profile, diameter: tokens.leadingVisual)
                VStack(alignment: .leading, spacing: 0) {
                    Text(profile.name)
                        .nuvioText(NuvioTextStyles.nav)
                        .lineLimit(1)
                    Text("Switch profile")
                        .nuvioText(NuvioTypography.labelSmall)
                        .foregroundStyle(colors.textTertiary)
                }
            }
            .padding(.horizontal, NuvioTheme.spacing.lg - NuvioTheme.spacing.xxs)
            .padding(.vertical, NuvioTheme.spacing.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(NuvioRowButtonStyle(cornerRadius: tokens.panelRadius / 2))
        .padding(.top, NuvioTheme.spacing.sm)
    }

    /// Every destination, collapsed or not.
    ///
    /// Collapsed used to mean *one* item — the current destination as a floating pill — and that
    /// left the rail column reading as empty space with a lozenge in it. Android's closed drawer
    /// is a strip of icons, one per destination: `drawerItems.forEach { LegacySidebarButton(…) }`
    /// runs in both states, and only `expanded` changes, which is what fills the band and lets a
    /// viewer see where they can go without opening anything.
    private var visibleTabs: [RootTab] { tabs }

    /// `glass_sidepanel_enabled` chooses the gradient-over-material glass; with it off the
    /// panel is a plain surface fill. `modern_sidebar_blur_enabled` controls the blur pass
    /// underneath, which is the expensive half on Android.
    ///
    /// Liquid Glass note: tvOS 26 does not ship the `glassEffect(_:in:)` modifier that iOS and
    /// macOS got — the only Liquid Glass surface in the tvOS SwiftUI SDK is `GlassButtonStyle`,
    /// which the rows use. So the panel itself is built the way Liquid Glass is specified to
    /// read: a thin material that refracts what is behind it, a soft top-down tint, and a
    /// specular edge that is brightest along the top.
    @ViewBuilder
    private var panelBackground: some View {
        let shape = RoundedRectangle(cornerRadius: tokens.panelRadius, style: .continuous)
        if settings.layout.glassSidePanelEnabled {
            shape
                // The material must be the visible base layer.  Filling an opaque tint above
                // it (as before) technically kept the blur in the hierarchy but hid all of
                // its refraction, which made the menu read as a flat grey dialog.
                .fill(settings.layout.modernSidebarBlurEnabled ? AnyShapeStyle(.ultraThinMaterial) : AnyShapeStyle(colors.surface.opacity(0.82)))
                .overlay {
                    shape.fill(
                        LinearGradient(
                            colors: [
                                colors.glassPanelTop.opacity(0.42),
                                colors.glassPanelBottom.opacity(0.22)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                }
                .overlay {
                    // A single flat hairline reads as a border; glass reads as a lit edge, so
                    // the stroke falls off from the top where the light is.
                    shape.strokeBorder(
                        LinearGradient(
                            colors: [
                                .white.opacity(0.45),
                                .white.opacity(0.12),
                                .white.opacity(0.05)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: NuvioTheme.strokes.thin
                    )
                }
                // Glass sits above the content rather than being painted into it.
                .shadow(color: .black.opacity(0.34), radius: dp(18), y: dp(7))
        } else {
            shape
                .fill(colors.surface)
                .overlay {
                    shape.strokeBorder(colors.border.opacity(0.6), lineWidth: NuvioTheme.strokes.hairline)
                }
        }
    }

    private func select(_ tab: RootTab) {
        router.select(tab)
        // Collapsing on activation matches the Android flow, where choosing a destination
        // hands focus straight back to the content area.
        collapse()
    }
}

// MARK: - Item

private struct SidebarItemView: View {
    @Environment(\.nuvioColors) private var colors
    @Environment(\.isFocused) private var isFocused

    let tab: RootTab
    let isSelected: Bool
    let showsLabel: Bool
    let action: () -> Void

    private var tokens: NuvioSidebarComponentTokens { NuvioTheme.components.sidebar }

    var body: some View {
        styledButton
            .contentShape(Rectangle())
    }

    /// Liquid Glass where the system has it. `GlassButtonStyle` is the one Liquid Glass surface
    /// tvOS 26 exposes to SwiftUI — there is no `glassEffect` modifier on this platform — and it
    /// brings the real material and focus response rather than an imitation of them. Below 26
    /// the hand-rolled style stands in.
    @ViewBuilder
    private var styledButton: some View {
        if #available(tvOS 26.0, *) {
            // Focus alone owns the bright, lifted glass state.  A prominent selected row plus
            // a focused row produced two competing white cards in the popup.  The active
            // destination instead gets the restrained accent marker in `label`.
            Button(action: action) { label }
                .buttonStyle(.glass)
            .buttonBorderShape(showsLabel ? .roundedRectangle(radius: tokens.panelRadius / 2) : .capsule)
            // Glass derives its label colour from the tint, and the app tint is the Nuvio red —
            // which on an unfocused row reads as five red menu entries. Neutral here; the style
            // still inverts to dark text when the row lifts on focus.
            .tint(.white)
        } else {
            Button(action: action) { label }
                .buttonStyle(SidebarItemButtonStyle(showsLabel: showsLabel, isSelected: isSelected))
        }
    }

    private var label: some View {
        HStack(spacing: showsLabel ? tokens.contentGap : 0) {
            iconCircle
            if showsLabel {
                Text(tab.title)
                    .nuvioText(NuvioTextStyles.nav)
                    .lineLimit(1)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, showsLabel ? NuvioTheme.spacing.lg - NuvioTheme.spacing.xxs : dp(5))
        .padding(.vertical, showsLabel ? NuvioTheme.spacing.sm + NuvioTheme.spacing.xxs : 0)
        .frame(height: showsLabel ? nil : NuvioTheme.sizes.player.control)
        .frame(maxWidth: showsLabel ? .infinity : nil, alignment: .leading)
        .overlay(alignment: .trailing) {
            if showsLabel && isSelected {
                Capsule(style: .continuous)
                    .fill(colors.primary.opacity(isFocused ? 0.9 : 0.65))
                    .frame(width: dp(3), height: dp(18))
                    .padding(.trailing, NuvioTheme.spacing.sm)
                    .accessibilityHidden(true)
            }
        }
        .contentShape(Rectangle())
    }

    /// No disc behind the glyph when the row is glass: two stacked materials read as muddy, and
    /// the row's own shape is already the affordance. The pre-26 style keeps its disc.
    @ViewBuilder
    private var iconCircle: some View {
        let glyph = Image(systemName: tab.systemImage)
            .font(.system(size: tokens.iconSize * 0.82, weight: .semibold))
            .frame(width: tokens.leadingVisual, height: tokens.leadingVisual)

        if #available(tvOS 26.0, *) {
            glyph
        } else {
            glyph
                .foregroundStyle(.white)
                .background {
                    Circle().fill(
                        isSelected
                            ? Color.white.opacity(NuvioTheme.effects.glowSoftAlpha)
                            : colors.surfaceVariant
                    )
                }
        }
    }
}

private struct SidebarItemButtonStyle: ButtonStyle {
    @Environment(\.isFocused) private var isFocused
    @Environment(\.nuvioColors) private var colors
    @Environment(AppSettings.self) private var settings

    let showsLabel: Bool
    let isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background { shapeFill }
            .overlay { shapeStroke }
            .animation(NuvioMotion.focusTween, value: isFocused)
    }

    /// Expanded rows use the panel's inner radius; the collapsed pill is fully rounded.
    /// `InsettableShape` is needed for `strokeBorder`, so the two cases stay concrete
    /// rather than being erased through `AnyShape`.
    @ViewBuilder
    private var shapeFill: some View {
        if showsLabel {
            RoundedRectangle(cornerRadius: NuvioTheme.components.sidebar.panelRadius / 2, style: .continuous)
                .fill(backgroundFill)
        } else {
            Capsule(style: .continuous).fill(backgroundFill)
        }
    }

    @ViewBuilder
    private var shapeStroke: some View {
        if showsLabel {
            RoundedRectangle(cornerRadius: NuvioTheme.components.sidebar.panelRadius / 2, style: .continuous)
                .strokeBorder(borderColor, lineWidth: NuvioTheme.strokes.thin)
        } else {
            Capsule(style: .continuous)
                .strokeBorder(borderColor, lineWidth: NuvioTheme.strokes.thin)
        }
    }

    private var backgroundFill: AnyShapeStyle {
        if showsLabel {
            return AnyShapeStyle(
                isFocused ? Color.white.opacity(NuvioTheme.effects.glowSoftAlpha) : Color.clear
            )
        }
        // Collapsed pill keeps the glass gradient from `CollapsedSidebarPill`, unless the
        // viewer turned the glass treatment off.
        guard settings.layout.glassSidePanelEnabled else {
            return AnyShapeStyle(colors.surface)
        }
        return AnyShapeStyle(
            LinearGradient(
                colors: [colors.glassPanelTop, colors.glassPanelBottom],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    private var borderColor: Color {
        if isFocused { return .white.opacity(NuvioTheme.effects.glowStrongAlpha) }
        return showsLabel ? .clear : .white.opacity(0.14)
    }
}
