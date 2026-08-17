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

    @ViewBuilder var content: Content

    @FocusState private var focusedTab: RootTab?
    @State private var isExpanded = false
    /// The panel may only bloom open once the viewer has actually driven the D-pad. At cold
    /// start tvOS parks focus on whatever is focusable first — here the pill — and without
    /// this gate the menu would be wide open on the first frame, which Android never does.
    @State private var hasUserNavigated = false
    @Namespace private var shellFocus

    private var tokens: NuvioSidebarComponentTokens { NuvioTheme.components.sidebar }

    /// Discover only earns a nav entry when the viewer put it there; the other two placements
    /// either fold it into Search or drop it entirely.
    private var tabs: [RootTab] {
        RootTab.allCases.filter { $0 != .discover || settings.layout.discoverLocation == .sidebar }
    }

    /// `modern_sidebar_enabled` off means the classic always-open rail: no pill, no bloom.
    private var isModernSidebar: Bool { settings.layout.modernSidebarEnabled }

    private var contentLeadingOffset: CGFloat {
        guard isModernSidebar else { return NuvioTheme.components.sidebar.expandedWidth }
        let heroIsFullBleed = router.selectedTab == .home && settings.layout.selectedLayout != .grid
        return heroIsFullBleed ? 0 : NuvioTheme.layout.sidebarContentOffset
    }

    /// Width reserved for the sidebar column: the collapsed pill and its own padding, nothing
    /// more. The expanded panel deliberately overflows this rather than widening it.
    private var railColumnWidth: CGFloat {
        guard isModernSidebar else { return NuvioTheme.components.sidebar.expandedWidth }
        let leading = NuvioTheme.spacing.lg - NuvioTheme.spacing.xxs
        // The pill is the leading visual plus the dp(5) it is padded by on each side.
        return leading + NuvioTheme.components.sidebar.leadingVisual + dp(10)
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
                .padding(.leading, NuvioTheme.spacing.lg - NuvioTheme.spacing.xxs)
                .padding(.top, NuvioTheme.spacing.lg)
                .padding(.bottom, NuvioTheme.spacing.md)
                .padding(.trailing, NuvioTheme.spacing.sm)
                .frame(width: railColumnWidth, alignment: .topLeading)
                // Full height *before* the focus section, which is the whole trick. A
                // directional move only considers candidates whose frame overlaps the band it
                // projects, and the pill sits at the very top — from a row further down the
                // screen there is simply nothing to the left of it. A focus section spanning the
                // full height is always in that band, and the engine redirects into it to the
                // nearest focusable item, which is the pill.
                .frame(maxHeight: .infinity, alignment: .top)
                .focusSection()
                .zIndex(1)

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .focusSection()
                // Without this the engine hands first focus to the sidebar, which would open
                // the panel on launch. Android starts with the pill collapsed and content live.
                .prefersDefaultFocus(in: shellFocus)
                // `NuvioLayout.sidebarContentOffset` on Android: screens that start with a
                // top-left title are nudged clear of the floating pill. The column already
                // supplies part of that gap, so only the remainder is padded here. The Modern
                // and Classic home layouts opt out — their hero is deliberately full-bleed, so
                // it is pulled back under the pill.
                .padding(.leading, contentLeadingOffset - railColumnWidth)
        }
        .background(colors.background)
        .focusScope(shellFocus)
        .onMoveCommand { _ in hasUserNavigated = true }
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
    }

    /// Back opens the panel on the current destination; pressing it again hands focus back to
    /// the content. Android exits the app on that second press, which tvOS neither allows nor
    /// expects — the Home button already does it.
    private func toggleFromBackButton() {
        guard router.contentHasFocusableViews else { return }
        // Keyed on the panel's own state, not on `focusedTab`: focus can still be parked on the
        // pill after the panel has collapsed, and reading that as "open" makes Back a no-op.
        if isExpanded {
            focusedTab = nil
        } else {
            hasUserNavigated = true
            focusedTab = router.selectedTab
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
        let shouldExpand = focusedTab != nil && hasUserNavigated
        guard shouldExpand != isExpanded else { return }
        withAnimation(shouldExpand ? NuvioMotion.sidebarPanelIn : NuvioMotion.sidebarPanelOut) {
            isExpanded = shouldExpand
        }
    }

    // MARK: Panel

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            if isExpanded {
                brandMark
                    .padding(.bottom, NuvioTheme.spacing.lg)
                    .transition(.opacity)
            }

            VStack(alignment: .leading, spacing: NuvioTheme.spacing.sm - NuvioTheme.spacing.xxs) {
                ForEach(visibleTabs, id: \.self) { tab in
                    SidebarItemView(
                        tab: tab,
                        isSelected: router.selectedTab == tab,
                        showsLabel: isExpanded,
                        stretchesVertically: !isExpanded,
                        action: { select(tab) }
                    )
                    .focused($focusedTab, equals: tab)
                    .disabled(!router.contentHasFocusableViews)
                }
            }
        }
        .padding(.horizontal, isExpanded ? NuvioTheme.spacing.md : 0)
        .padding(.vertical, isExpanded ? NuvioTheme.spacing.lg - NuvioTheme.spacing.xxs : 0)
        .frame(width: isExpanded ? tokens.expandedWidth : nil, alignment: .leading)
        .background {
            if isExpanded {
                panelBackground
            }
        }
        .animation(NuvioMotion.sidebarPanelIn, value: isExpanded)
    }

    /// Collapsed, the panel shows only the current destination — that is the floating pill.
    private var visibleTabs: [RootTab] {
        isExpanded ? tabs : [router.selectedTab]
    }

    /// `glass_sidepanel_enabled` chooses the gradient-over-material glass; with it off the
    /// panel is a plain surface fill. `modern_sidebar_blur_enabled` controls the blur pass
    /// underneath, which is the expensive half on Android.
    @ViewBuilder
    private var panelBackground: some View {
        let shape = RoundedRectangle(cornerRadius: tokens.panelRadius, style: .continuous)
        if settings.layout.glassSidePanelEnabled {
            shape
                .fill(
                    LinearGradient(
                        colors: [colors.glassPanelTop, colors.glassPanelBottom],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .background {
                    if settings.layout.modernSidebarBlurEnabled {
                        shape.fill(.ultraThinMaterial)
                    } else {
                        shape.fill(colors.surface)
                    }
                }
                .overlay {
                    shape.strokeBorder(.white.opacity(0.14), lineWidth: NuvioTheme.strokes.hairline)
                }
        } else {
            shape
                .fill(colors.surface)
                .overlay {
                    shape.strokeBorder(colors.border.opacity(0.6), lineWidth: NuvioTheme.strokes.hairline)
                }
        }
    }

    private var brandMark: some View {
        Text("NUVIO")
            .nuvioText(NuvioTextStyles.headline)
            .foregroundStyle(colors.textPrimary)
            .frame(height: dp(36), alignment: .leading)
            .padding(.horizontal, NuvioTheme.spacing.lg - NuvioTheme.spacing.xxs)
    }

    private func select(_ tab: RootTab) {
        router.select(tab)
        // Collapsing on activation matches the Android flow, where choosing a destination
        // hands focus straight back to the content area.
        focusedTab = nil
    }
}

// MARK: - Item

private struct SidebarItemView: View {
    @Environment(\.nuvioColors) private var colors
    @Environment(\.isFocused) private var isFocused

    let tab: RootTab
    let isSelected: Bool
    let showsLabel: Bool
    /// Collapsed, the pill's focus frame spans the whole column even though it draws at the
    /// top. A leftward move only considers candidates level with the focused row, so a pill
    /// pinned to the top corner is unreachable from anywhere below it.
    var stretchesVertically: Bool = false
    let action: () -> Void

    private var tokens: NuvioSidebarComponentTokens { NuvioTheme.components.sidebar }

    var body: some View {
        Button(action: action) {
            HStack(spacing: showsLabel ? tokens.contentGap : 0) {
                iconCircle
                if showsLabel {
                    Text(tab.title)
                        .nuvioText(NuvioTextStyles.nav)
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .transition(.opacity)
                }
            }
            .padding(.horizontal, showsLabel ? NuvioTheme.spacing.lg - NuvioTheme.spacing.xxs : dp(5))
            .padding(.vertical, showsLabel ? NuvioTheme.spacing.sm + NuvioTheme.spacing.xxs : 0)
            .frame(height: showsLabel ? nil : NuvioTheme.sizes.player.control)
            .frame(maxWidth: showsLabel ? .infinity : nil, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(SidebarItemButtonStyle(showsLabel: showsLabel, isSelected: isSelected))
        .frame(maxHeight: stretchesVertically ? .infinity : nil, alignment: .top)
        .contentShape(Rectangle())
    }

    private var iconCircle: some View {
        Image(systemName: tab.systemImage)
            .font(.system(size: tokens.iconSize * 0.72, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: tokens.leadingVisual, height: tokens.leadingVisual)
            .background {
                Circle().fill(
                    isSelected
                        ? Color.white.opacity(NuvioTheme.effects.glowSoftAlpha)
                        : colors.surfaceVariant
                )
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
