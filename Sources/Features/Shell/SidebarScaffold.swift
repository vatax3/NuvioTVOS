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
    @Environment(SettingsStore.self) private var settings

    @ViewBuilder var content: Content

    @FocusState private var focusedTab: RootTab?
    @State private var isExpanded = false
    /// The panel may only bloom open once the viewer has actually driven the D-pad. At cold
    /// start tvOS parks focus on whatever is focusable first — here the pill — and without
    /// this gate the menu would be wide open on the first frame, which Android never does.
    @State private var hasUserNavigated = false
    @Namespace private var shellFocus

    private var tokens: NuvioSidebarComponentTokens { NuvioTheme.components.sidebar }

    private var tabs: [RootTab] {
        RootTab.allCases.filter { $0 != .discover || settings.showDiscoverTab }
    }

    private var contentLeadingOffset: CGFloat {
        let heroIsFullBleed = router.selectedTab == .home && settings.homeLayout != .grid
        return heroIsFullBleed ? 0 : NuvioTheme.layout.sidebarContentOffset
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // `NuvioLayout.sidebarContentOffset` on Android: screens that start with a
                // top-left title are nudged clear of the floating pill. The Modern and Classic
                // home layouts opt out — their hero is deliberately full-bleed behind it.
                .padding(.leading, contentLeadingOffset)
                .focusSection()
                // Without this the engine hands first focus to the sidebar, which would open
                // the panel on launch. Android starts with the pill collapsed and content live.
                .prefersDefaultFocus(in: shellFocus)

            sidebar
                .padding(.leading, NuvioTheme.spacing.lg - NuvioTheme.spacing.xxs)
                .padding(.top, NuvioTheme.spacing.lg)
                .padding(.bottom, NuvioTheme.spacing.md)
                .padding(.trailing, NuvioTheme.spacing.sm)
        }
        .background(colors.background)
        .focusScope(shellFocus)
        .onMoveCommand { _ in hasUserNavigated = true }
        .onChange(of: focusedTab) { _, newValue in
            updateExpansion(focusedTab: newValue)
        }
        .onChange(of: hasUserNavigated) { _, _ in
            updateExpansion(focusedTab: focusedTab)
        }
    }

    private func updateExpansion(focusedTab: RootTab?) {
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
        .focusSection()
    }

    /// Collapsed, the panel shows only the current destination — that is the floating pill.
    private var visibleTabs: [RootTab] {
        isExpanded ? tabs : [router.selectedTab]
    }

    private var panelBackground: some View {
        RoundedRectangle(cornerRadius: tokens.panelRadius, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [colors.glassPanelTop, colors.glassPanelBottom],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: tokens.panelRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: tokens.panelRadius, style: .continuous)
                    .strokeBorder(.white.opacity(0.14), lineWidth: NuvioTheme.strokes.hairline)
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
        // Collapsed pill keeps the glass gradient from `CollapsedSidebarPill`.
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
