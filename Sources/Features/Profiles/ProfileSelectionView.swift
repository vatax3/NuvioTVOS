import SwiftUI

/// Port of `ProfileSelectionScreen` — the "Who's watching?" chooser shown before the app proper.
///
/// The background is tinted by whichever profile currently holds focus, which is the whole
/// character of the Android screen: the colour a household member picked for themselves is what
/// they see as they arrive, and it moves with the selection rather than sitting still.
struct ProfileSelectionView: View {
    @Environment(\.nuvioColors) private var colors
    let profiles: ProfileStore

    @FocusState private var focusedProfileId: String?
    /// The locked profile awaiting a PIN.
    @State private var challenging: Profile?
    @State private var entry = ""
    @State private var didFail = false
    @State private var isVerifying = false
    @State private var swallowsNextPress = false
    @FocusState private var keypadFocus: Int?

    private var tintedProfile: Profile? {
        profiles.profiles.first { $0.id == (focusedProfileId ?? profiles.activeProfileId) }
    }

    private var tint: Color {
        Color(argbHex: tintedProfile?.tintHex ?? "#1E88E5")
    }

    /// A TV profile picker reads best as one compact, centred row.  The previous Android-sized
    /// cards became needlessly imposing on an Apple TV canvas, especially with four or more
    /// household profiles.  Keep the roomy variant for one or two profiles, then tighten it.
    private var isCompact: Bool { profiles.profiles.count >= 3 }
    private var cardWidth: CGFloat { isCompact ? dp(96) : dp(120) }
    private var avatarSize: CGFloat { isCompact ? dp(64) : dp(82) }
    private var cardGap: CGFloat { isCompact ? dp(14) : dp(18) }

    var body: some View {
        ZStack {
            background

            VStack(spacing: 0) {
                Spacer()

                if let challenging {
                    pinChallenge(for: challenging)
                } else {
                    chooser
                }

                Spacer()
            }
            .padding(.horizontal, NuvioTheme.layout.tvSafeHorizontal)
        }
        .animation(NuvioMotion.slowTween, value: tint)
        .onChange(of: challenging) { _, profile in
            entry = ""
            didFail = false
            if profile != nil { keypadFocus = 1 }
        }
    }

    // MARK: Background

    private var background: some View {
        ZStack {
            LinearGradient(
                stops: [
                    .init(color: colors.surface.blended(with: tint, amount: 0.30), location: 0),
                    .init(color: colors.background.blended(with: tint, amount: 0.14), location: 0.42),
                    .init(color: colors.background, location: 1)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            // The second wash is horizontal, so the colour pools on the leading side rather
            // than flooding the whole screen.
            LinearGradient(
                stops: [
                    .init(color: tint.opacity(0.26), location: 0),
                    .init(color: tint.opacity(0.08), location: 0.45),
                    .init(color: .clear, location: 0.72)
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
        }
        .ignoresSafeArea()
    }

    // MARK: Chooser

    private var chooser: some View {
        VStack(spacing: 0) {
            Text(L10n.text("profiles.whos_watching"))
                .nuvioText(NuvioTextStyles.headline)
                .foregroundStyle(colors.textPrimary)

            Spacer().frame(height: NuvioTheme.spacing.xs)

            Text(L10n.text("profiles.select_to_continue"))
                .nuvioText(NuvioTextStyles.bodyCompact)
                .foregroundStyle(colors.textSecondary)

            Spacer().frame(height: dp(26))

            // No scroll view: five is the ceiling, and at compact metrics six cards fit the
            // safe area, so the row is centred rather than anchored to the left edge.
            HStack(alignment: .top, spacing: cardGap) {
                ForEach(profiles.profiles) { profile in
                    card(for: profile)
                }
                addCard
            }
            .padding(.vertical, NuvioTheme.spacing.md)
            .frame(maxWidth: .infinity)
            .focusSection()

            Spacer().frame(height: dp(18))

            Text(L10n.text("profiles.hold_to_manage"))
                .nuvioText(NuvioTypography.labelSmall)
                .foregroundStyle(colors.textTertiary)
        }
    }

    private func card(for profile: Profile) -> some View {
        Button(action: {
            if swallowsNextPress {
                swallowsNextPress = false
                return
            }
            choose(profile)
        }) {
            VStack(spacing: dp(10)) {
                ProfileAvatar(profile: profile, diameter: avatarSize)
                Text(profile.name)
                    .nuvioText(NuvioTextStyles.cardTitle)
                    .foregroundStyle(colors.textPrimary)
                    .lineLimit(1)
            }
            .frame(width: cardWidth)
            .padding(.horizontal, dp(8))
            .padding(.vertical, NuvioTheme.spacing.sm)
            .contentShape(Rectangle())
        }
        .buttonStyle(NuvioRowButtonStyle(cornerRadius: NuvioTheme.radii.lg))
        .focused($focusedProfileId, equals: profile.id)
        // Long press is the management gesture on Android; the same gesture is available here
        // rather than adding a button the official screen does not have. One flag for the whole
        // screen is enough — exactly one card holds focus at a time.
        .onSelectHold(
            isFocused: focusedProfileId == profile.id,
            swallowsNextPress: $swallowsNextPress
        ) { profiles.requestProfileManagement() }
    }

    private var addCard: some View {
        // Creating a profile lives in Settings, so this opens the app straight onto it.
        Button(action: { profiles.requestProfileManagement() }) {
            VStack(spacing: dp(10)) {
                Image(systemName: "plus")
                    .font(.system(size: avatarSize * 0.34, weight: .semibold))
                    .foregroundStyle(colors.textSecondary)
                    .frame(width: avatarSize, height: avatarSize)
                    .background {
                        Circle().strokeBorder(
                            colors.border, lineWidth: NuvioTheme.strokes.thin
                        )
                    }
                Text(L10n.text("profiles.add"))
                    .nuvioText(NuvioTextStyles.cardTitle)
                    .foregroundStyle(colors.textSecondary)
                    .lineLimit(1)
            }
            .frame(width: cardWidth)
            .padding(.horizontal, dp(8))
            .padding(.vertical, NuvioTheme.spacing.sm)
            .contentShape(Rectangle())
        }
        .buttonStyle(NuvioRowButtonStyle(cornerRadius: NuvioTheme.radii.lg))
        .focused($focusedProfileId, equals: "add")
    }

    // MARK: PIN

    private func pinChallenge(for profile: Profile) -> some View {
        VStack(spacing: 0) {
            ProfileAvatar(profile: profile, diameter: dp(96))

            Spacer().frame(height: dp(14))

            Text(profile.name)
                .nuvioText(NuvioTextStyles.headline)
                .foregroundStyle(colors.textPrimary)

            Spacer().frame(height: NuvioTheme.spacing.sm)

            Text(didFail ? L10n.text("profiles.wrong_pin") : L10n.text("profiles.enter_pin"))
                .nuvioText(NuvioTextStyles.body)
                .foregroundStyle(didFail ? colors.error : colors.textSecondary)

            Spacer().frame(height: dp(26))

            HStack(spacing: dp(14)) {
                ForEach(0..<4, id: \.self) { index in
                    Circle()
                        .fill(index < entry.count ? tint : colors.surfaceVariant)
                        .frame(width: dp(18), height: dp(18))
                }
            }
            .animation(NuvioMotion.quickTween, value: entry.count)

            Spacer().frame(height: dp(26))

            PinKeypad(
                onDigit: append,
                onDelete: { entry = String(entry.dropLast()) },
                focus: $keypadFocus
            )
            .disabled(isVerifying)
            .opacity(isVerifying ? NuvioTheme.effects.disabledAlpha : 1)

            Spacer().frame(height: NuvioTheme.spacing.lg)

            Button(L10n.text("common.back")) { challenging = nil }
                .buttonStyle(NuvioRowButtonStyle(cornerRadius: NuvioTheme.radii.md))
        }
        .focusSection()
    }

    private func append(_ digit: Int) {
        guard entry.count < 4, !isVerifying else { return }
        didFail = false
        entry += String(digit)
        guard entry.count == 4, let profile = challenging else { return }
        isVerifying = true
        Task {
            // A PIN set on another device has no local hash, so this may go to the server.
            let unlocked = await profiles.unlockRemotely(profile, pin: entry)
            isVerifying = false
            if unlocked {
                profiles.markSelectionHandled()
            } else {
                didFail = true
                entry = ""
            }
        }
    }

    // MARK: Selection

    private func choose(_ profile: Profile) {
        if profile.isLocked {
            challenging = profile
            return
        }
        profiles.activate(profile)
        profiles.markSelectionHandled()
    }
}

private extension Color {
    /// Compose's `lerp` between two colours, used for the tinted gradient stops.
    func blended(with other: Color, amount: Double) -> Color {
        let base = UIColor(self)
        let overlay = UIColor(other)
        var r1: CGFloat = 0, g1: CGFloat = 0, b1: CGFloat = 0, a1: CGFloat = 0
        var r2: CGFloat = 0, g2: CGFloat = 0, b2: CGFloat = 0, a2: CGFloat = 0
        base.getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
        overlay.getRed(&r2, green: &g2, blue: &b2, alpha: &a2)
        let t = CGFloat(min(max(amount, 0), 1))
        return Color(
            red: Double(r1 + (r2 - r1) * t),
            green: Double(g1 + (g2 - g1) * t),
            blue: Double(b1 + (b2 - b1) * t),
            opacity: Double(a1 + (a2 - a1) * t)
        )
    }
}
