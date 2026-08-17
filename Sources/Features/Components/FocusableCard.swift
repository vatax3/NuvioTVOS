import SwiftUI

// MARK: - Card button style
//
// Android TV draws focus as a 2dp ring in the theme's focus colour plus a 1.02 scale and
// an 8dp elevation. tvOS's stock `.card` style instead applies Apple's parallax/lift, which
// reads nothing like Nuvio — so focus is rendered by hand here to match the Compose code.

struct NuvioCardButtonStyle: ButtonStyle {
    @Environment(\.isFocused) private var isFocused
    @Environment(\.nuvioColors) private var colors
    @Environment(\.navigationFeel) private var feel

    var cornerRadius: CGFloat = NuvioTheme.components.posterCard.cornerRadius
    var focusedScale: CGFloat = NuvioTheme.components.posterCard.focusedScale
    var ringWidth: CGFloat = NuvioTheme.components.posterCard.focusedBorderWidth
    var showsRing: Bool = true
    var elevated: Bool = true

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                if showsRing {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(isFocused ? colors.focusRing : .clear, lineWidth: ringWidth)
                }
            }
            .scaleEffect(scale(pressed: configuration.isPressed))
            .shadow(
                color: .black.opacity(elevated && isFocused ? 0.55 : 0),
                radius: isFocused ? NuvioTheme.elevations.focused : 0,
                y: isFocused ? NuvioTheme.elevations.card : 0
            )
            .animation(feel.focusAnimation, value: isFocused)
            .animation(NuvioMotion.quickTween, value: configuration.isPressed)
    }

    private func scale(pressed: Bool) -> CGFloat {
        if pressed { return NuvioMotion.pressedScale }
        return isFocused ? focusedScale : 1
    }
}

/// Focus treatment for list rows and settings entries: a filled focus background plus ring,
/// mirroring `SettingsDesignSystem`'s row styling rather than the poster card's scale.
struct NuvioRowButtonStyle: ButtonStyle {
    @Environment(\.isFocused) private var isFocused
    @Environment(\.nuvioColors) private var colors

    var cornerRadius: CGFloat = NuvioTheme.radii.md
    var selected: Bool = false
    var scaleOnFocus: Bool = true

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(background)
            }
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        isFocused ? colors.focusRing : .clear,
                        lineWidth: NuvioTheme.strokes.focus
                    )
            }
            .scaleEffect(scaleOnFocus && isFocused ? NuvioFocus.tokens.subtleScale : 1)
            .animation(NuvioMotion.focusTween, value: isFocused)
    }

    private var background: Color {
        if isFocused { return colors.focusBackground }
        if selected { return colors.focusBackground.opacity(0.55) }
        return .clear
    }
}

/// Pill/chip buttons — hero actions, filter chips, dialog actions.
struct NuvioPillButtonStyle: ButtonStyle {
    @Environment(\.isFocused) private var isFocused
    @Environment(\.nuvioColors) private var colors

    enum Emphasis { case primary, secondary, ghost }

    var emphasis: Emphasis = .secondary
    var selected: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(foreground)
            .background {
                Capsule(style: .continuous).fill(background)
            }
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(borderColor, lineWidth: NuvioTheme.strokes.focus)
            }
            .scaleEffect(configuration.isPressed ? NuvioMotion.pressedScale : (isFocused ? NuvioMotion.focusScale : 1))
            .animation(NuvioMotion.focusTween, value: isFocused)
            .animation(NuvioMotion.quickTween, value: configuration.isPressed)
    }

    private var background: Color {
        switch emphasis {
        case .primary:
            return isFocused ? colors.focusRing : colors.secondary
        case .secondary:
            if isFocused { return colors.focusContent }
            return selected ? colors.focusBackground : colors.surfaceVariant.opacity(0.85)
        case .ghost:
            if isFocused { return colors.focusBackground }
            return selected ? colors.focusBackground.opacity(0.6) : .clear
        }
    }

    private var foreground: Color {
        switch emphasis {
        case .primary:
            return isFocused ? colors.textInverse : colors.onSecondary
        case .secondary:
            return isFocused ? colors.textInverse : colors.textPrimary
        case .ghost:
            return isFocused ? colors.focusContent : colors.textSecondary
        }
    }

    private var borderColor: Color {
        if isFocused { return colors.focusRing }
        if selected { return colors.secondaryVariant }
        return .clear
    }
}

// MARK: - Focus observation

/// Reports focus changes of the wrapped subtree — used to drive hero backdrops and
/// row anchoring, which on Android come from `onFocusChanged`.
struct FocusReporter: ViewModifier {
    @Environment(\.isFocused) private var isFocused
    let onChange: (Bool) -> Void

    func body(content: Content) -> some View {
        content
            .onChange(of: isFocused, initial: true) { _, focused in
                onChange(focused)
            }
    }
}

extension View {
    func onFocusChange(_ action: @escaping (Bool) -> Void) -> some View {
        modifier(FocusReporter(onChange: action))
    }

    /// Binds focus only when the caller supplied a binding, so shared row components can be
    /// reused on screens that do not need to drive focus programmatically.
    @ViewBuilder
    func focusedIfAvailable(_ binding: FocusState<String?>.Binding?, equals value: String) -> some View {
        if let binding {
            focused(binding, equals: value)
        } else {
            self
        }
    }
}

// MARK: - Marquee text

/// Port of `FocusMarqueeText` — titles scroll horizontally only while focused.
struct FocusMarqueeText: View {
    let text: String
    var style: NuvioTextStyle = NuvioTextStyles.cardTitle
    var color: Color
    var isFocused: Bool

    @State private var textWidth: CGFloat = 0
    @State private var containerWidth: CGFloat = 0
    @State private var offset: CGFloat = 0

    private var overflow: CGFloat { max(0, textWidth - containerWidth) }

    var body: some View {
        GeometryReader { proxy in
            Text(text)
                .nuvioText(style)
                .foregroundStyle(color)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .background {
                    GeometryReader { textProxy in
                        Color.clear
                            .onAppear { textWidth = textProxy.size.width }
                            .onChange(of: textProxy.size.width) { _, new in textWidth = new }
                    }
                }
                .offset(x: offset)
                .frame(width: proxy.size.width, alignment: .leading)
                .clipped()
                .onAppear { containerWidth = proxy.size.width }
                .onChange(of: proxy.size.width) { _, new in containerWidth = new }
                .onChange(of: isFocused) { _, focused in animate(focused) }
        }
        .frame(height: sp(style.lineHeight))
    }

    private func animate(_ focused: Bool) {
        guard focused, overflow > 1 else {
            withAnimation(NuvioMotion.quickTween) { offset = 0 }
            return
        }
        // Pause at the start, scroll to the end, hold, then return — the Compose behaviour.
        let duration = Double(overflow) / dp(40)
        withAnimation(.easeInOut(duration: duration).delay(0.8).repeatForever(autoreverses: true)) {
            offset = -overflow
        }
    }
}

// MARK: - Section header

struct SectionHeader: View {
    @Environment(\.nuvioColors) private var colors
    let title: String
    var subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: NuvioTheme.spacing.xxs) {
            Text(title)
                .nuvioText(NuvioTextStyles.sectionTitle)
                .foregroundStyle(colors.textPrimary)
            if let subtitle {
                Text(subtitle)
                    .nuvioText(NuvioTextStyles.metadata)
                    .foregroundStyle(colors.textSecondary)
            }
        }
    }
}

// MARK: - Badges & chips

struct NuvioBadge: View {
    @Environment(\.nuvioColors) private var colors
    let text: String
    var tint: Color?
    var filled: Bool = false

    var body: some View {
        Text(text.uppercased())
            .nuvioText(NuvioTextStyles.badge)
            .foregroundStyle(filled ? colors.textInverse : (tint ?? colors.textSecondary))
            .padding(.horizontal, NuvioTheme.spacing.sm)
            .padding(.vertical, NuvioTheme.spacing.xxs)
            .background {
                RoundedRectangle(cornerRadius: NuvioTheme.shapes.badge, style: .continuous)
                    .fill(filled ? (tint ?? colors.secondary) : colors.surfaceVariant.opacity(0.7))
            }
            .overlay {
                RoundedRectangle(cornerRadius: NuvioTheme.shapes.badge, style: .continuous)
                    .strokeBorder((tint ?? colors.border).opacity(filled ? 0 : 0.5), lineWidth: NuvioTheme.strokes.hairline)
            }
    }
}

struct RatingLabel: View {
    @Environment(\.nuvioColors) private var colors
    let rating: Float

    var body: some View {
        HStack(spacing: NuvioTheme.spacing.xs) {
            Image(systemName: "star.fill")
                .font(.system(size: NuvioTheme.sizes.icons.xs))
                .foregroundStyle(colors.rating)
            Text(String(format: "%.1f", rating))
                .nuvioText(NuvioTextStyles.metadata)
                .foregroundStyle(colors.textPrimary)
        }
    }
}

/// The thin progress bar drawn under Continue Watching artwork.
struct WatchProgressBar: View {
    @Environment(\.nuvioColors) private var colors
    let fraction: Double

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(colors.textPrimary.opacity(0.28))
                Capsule()
                    .fill(colors.secondary)
                    .frame(width: max(0, min(1, fraction)) * proxy.size.width)
            }
        }
        .frame(height: NuvioTheme.strokes.progress)
    }
}

// MARK: - Aggregated ratings (port of the MDBList strip on the detail hero)

struct RatingsStrip: View {
    @Environment(\.nuvioColors) private var colors
    @Environment(AppSettings.self) private var settings

    let ratings: MDBListRatings

    private var entries: [(label: String, value: Double, tint: Color)] {
        var rows: [(String, Double, Color)] = []
        let mdblist = settings.mdblist
        if mdblist.showImdb, let value = ratings.imdb { rows.append(("IMDb", value, colors.sourceImdb)) }
        if mdblist.showTmdb, let value = ratings.tmdb { rows.append(("TMDB", value, colors.sourceTmdb)) }
        if mdblist.showTomatoes, let value = ratings.tomatoes { rows.append(("RT", value, colors.error)) }
        if mdblist.showAudience, let value = ratings.audience { rows.append(("Audience", value, colors.warning)) }
        if mdblist.showMetacritic, let value = ratings.metacritic { rows.append(("Metacritic", value, colors.info)) }
        if mdblist.showTrakt, let value = ratings.trakt { rows.append(("Trakt", value, colors.sourceTrakt)) }
        if mdblist.showLetterboxd, let value = ratings.letterboxd { rows.append(("Letterboxd", value, colors.success)) }
        if mdblist.showMal, let value = ratings.mal { rows.append(("MAL", value, colors.sourceMdblist)) }
        return rows
    }

    var body: some View {
        HStack(spacing: NuvioTheme.spacing.lg) {
            ForEach(entries, id: \.label) { entry in
                HStack(spacing: NuvioTheme.spacing.xs) {
                    Text(entry.label)
                        .nuvioText(NuvioTypography.labelSmall)
                        .foregroundStyle(entry.tint)
                    Text(formatted(entry.value))
                        .nuvioText(NuvioTextStyles.metadata)
                        .foregroundStyle(colors.textPrimary)
                }
            }
        }
    }

    /// MDBList mixes 0–10 and 0–100 scales depending on the source.
    private func formatted(_ value: Double) -> String {
        value > 10 ? String(format: "%.0f", value) : String(format: "%.1f", value)
    }
}
