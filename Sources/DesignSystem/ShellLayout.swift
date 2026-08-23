import SwiftUI

// MARK: - Shell geometry

private struct ShellLeadingInsetKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

extension EnvironmentValues {
    /// How far a screen's content has been pushed right by the shell's navigation column.
    ///
    /// Every destination is laid out *beside* the sidebar rather than under it — see
    /// `SidebarScaffold`, where that is load-bearing for the LEFT gesture and not a spacing
    /// choice. A decorative layer that is supposed to reach the edge of the television has to
    /// know how much of the screen the column took, because nothing else in its own view tree
    /// can tell it.
    var shellLeadingInset: CGFloat {
        get { self[ShellLeadingInsetKey.self] }
        set { self[ShellLeadingInsetKey.self] = newValue }
    }
}

extension View {
    /// Slides a layer that has already been *built* wider back over the shell's navigation
    /// column and out through the screen's safe margin, so a backdrop reaches the physical edge
    /// of the panel.
    ///
    /// Android's home is full-bleed with the menu floating over it; ours had a hard vertical
    /// seam where the artwork began, measured at 204pt — a tenth of the screen of flat grey down
    /// the left-hand side, which is what a viewer on a real television reported.
    ///
    /// The widening has to happen inside the layer, at the frames that size the image and its
    /// gradient. Wrapping a fixed-width child in a wider frame does not widen it: the child is
    /// aligned inside the new frame and the whole thing then slides left, which trades a seam on
    /// the left for a seam on the right. Measured, that is exactly what it did — 80pt of bare
    /// background down the trailing edge.
    ///
    /// `offset` rather than `padding`, deliberately: this is paint, not layout. Nothing else in
    /// the stack moves, so every focusable frame stays where the focus engine last saw it and the
    /// leftward move into the menu is untouched.
    func bleedingLeading(by inset: CGFloat) -> some View {
        offset(x: -max(0, inset))
    }
}

// MARK: - Scrollers

extension View {
    /// Clips a horizontal scroller to its container's width while leaving a focused item room to
    /// grow upwards and downwards.
    ///
    /// `scrollClipDisabled` is all-or-nothing across both axes. These rows need it for one of
    /// them — a chip lifts and glows on focus, and clipping to the scroller's own bounds shears
    /// the top and bottom off — so turning it off wholesale let the row spill sideways out of the
    /// card it belongs to, past the rounded corner and over the section beside it. Reported as
    /// the settings rows having "no delimited zone", which is exactly what they had.
    ///
    /// The sandwich is the standard answer: pad the bounds outwards vertically, clip to those
    /// bounds, then take the padding back out of the layout. Horizontal is clipped at the real
    /// edge; vertical is not clipped at all.
    func clippedHorizontalScroller(overhang: CGFloat = NuvioTheme.spacing.lg) -> some View {
        scrollClipDisabled()
            .padding(.vertical, overhang)
            .clipped()
            .padding(.vertical, -overhang)
    }
}

// MARK: - Long-form text

extension View {
    /// Makes a block of text a focus target so the page it sits on can be scrolled.
    ///
    /// tvOS scrolls a `ScrollView` by moving focus into something below the fold. About and
    /// Licences are the only screens in the app made entirely of text — no rows, no switches,
    /// nothing focusable at all — so the focus engine had nowhere to go and the page was frozen
    /// at the top with the rest of it unreachable. Reported exactly that way.
    ///
    /// The treatment is deliberately quiet: this is a paragraph, not a button, and it should read
    /// as the place you are rather than as something to press.
    func readableBlock() -> some View {
        modifier(ReadableBlock())
    }
}

private struct ReadableBlock: ViewModifier {
    @Environment(\.nuvioColors) private var colors
    @FocusState private var isFocused: Bool

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: NuvioTheme.radii.md, style: .continuous)
                    .fill(isFocused ? Color.white.opacity(0.06) : .clear)
            }
            .animation(NuvioMotion.focusTween, value: isFocused)
            .focusEffectDisabled()
            .focusable()
            .focused($isFocused)
    }
}
