import SwiftUI

// MARK: - Lock screen

/// Shown instead of the app when the active profile carries a PIN. Also the switcher of last
/// resort: someone who does not know the PIN can still drop back to another profile.
struct ProfileLockView: View {
    let profile: Profile
    let profiles: ProfileStore

    @State private var entry = ""
    @State private var didFail = false
    @FocusState private var keypadFocus: Int?

    private var colors: NuvioColorScheme { NuvioColorScheme(palette: ThemeColors.crimson) }

    var body: some View {
        ZStack {
            colors.background.ignoresSafeArea()

            // Identity beside the keypad rather than above it. Stacked, this screen asked for
            // about 1550pt of a 1080pt panel and simply clipped: the avatar off the top, the
            // fallback button off the bottom. Vertical is the scarce axis on a 16:9 panel and
            // horizontal is the abundant one, so the fix is the layout, not smaller keys.
            HStack(alignment: .center, spacing: NuvioTheme.spacing.xxl) {
                VStack(spacing: NuvioTheme.spacing.md) {
                    ProfileAvatar(profile: profile, diameter: dp(96))

                    Text(profile.name)
                        .nuvioText(NuvioTextStyles.headline)
                        .foregroundStyle(colors.textPrimary)

                    Text(didFail ? L10n.text("profiles.wrong_pin", fallback: "Wrong PIN — try again") : L10n.text("profiles.enter_pin", fallback: "Enter your PIN"))
                        .nuvioText(NuvioTextStyles.bodyCompact)
                        .foregroundStyle(didFail ? colors.error : colors.textSecondary)

                    pinDots

                    if profiles.hasMultipleProfiles {
                        Button(action: switchToPrimary) {
                            Text(L10n.text("profiles.switch", fallback: "Use another profile"))
                                .nuvioText(NuvioTextStyles.button)
                                .padding(.horizontal, NuvioTheme.spacing.xl)
                                .frame(height: NuvioTheme.components.buttonHeight)
                        }
                        .buttonStyle(NuvioPillButtonStyle(emphasis: .ghost))
                    }
                }
                // Its own section, so a sideways press moves between the fallback button and the
                // keypad instead of landing on whichever key is geometrically nearest.
                .focusSection()

                PinKeypad(
                    onDigit: append,
                    onDelete: { entry = String(entry.dropLast()) },
                    focus: $keypadFocus
                )
            }
            // The horizontal overscan constant was applied on all four edges, so 96pt of it was
            // charged vertically on top of the platform's own inset. Vertical has its own token.
            .padding(.horizontal, NuvioTheme.layout.tvSafeHorizontal)
            .padding(.vertical, NuvioTheme.layout.tvSafeVertical)
        }
        .environment(\.nuvioColors, colors)
        .onAppear { keypadFocus = 1 }
    }

    private var pinDots: some View {
        HStack(spacing: NuvioTheme.spacing.md) {
            ForEach(0..<4, id: \.self) { index in
                Circle()
                    .fill(index < entry.count ? colors.secondary : colors.surfaceVariant)
                    .frame(width: dp(18), height: dp(18))
            }
        }
        .animation(NuvioMotion.quickTween, value: entry.count)
    }

    private func append(_ digit: Int) {
        guard entry.count < 4 else { return }
        didFail = false
        entry += String(digit)
        guard entry.count == 4 else { return }
        Task {
            // A PIN set on another device is only checkable server-side, so this has to await.
            if await !profiles.unlockRemotely(profile, pin: entry) {
                didFail = true
                entry = ""
            }
        }
    }

    /// Falling back to the primary profile is always allowed — the PIN protects one profile's
    /// library, it is not a device lock, and pretending otherwise would just strand the viewer.
    private func switchToPrimary() {
        guard let fallback = profiles.profiles.first(where: {
            $0.id == ProfileScope.primaryProfileId && !$0.isLocked
        }) ?? profiles.profiles.first(where: { !$0.isLocked }) else { return }
        profiles.activate(fallback)
    }
}

/// D-pad friendly keypad: 0–9 in a grid plus delete, all real focusable buttons.
/// Shared by the lock screen, the switcher and the launch chooser.
struct PinKeypad: View {
    @Environment(\.nuvioColors) private var colors

    let onDigit: (Int) -> Void
    let onDelete: () -> Void
    var focus: FocusState<Int?>.Binding

    private let rows = [[1, 2, 3], [4, 5, 6], [7, 8, 9]]
    private let keyWidth = dp(76)

    var body: some View {
        VStack(spacing: NuvioTheme.spacing.sm) {
            ForEach(rows, id: \.self) { row in
                HStack(spacing: NuvioTheme.spacing.sm) {
                    ForEach(row, id: \.self) { digit in
                        key(label: "\(digit)") { onDigit(digit) }
                            .focused(focus, equals: digit)
                    }
                }
            }
            HStack(spacing: NuvioTheme.spacing.sm) {
                // An empty cell of a key's width, so 0 sits under 8 rather than straddling the
                // gap between the first two columns — which is where a two-key row lands when
                // it is centred against three.
                Color.clear.frame(width: keyWidth, height: NuvioTheme.components.buttonHeight)
                key(label: "0") { onDigit(0) }
                    .focused(focus, equals: 0)
                key(systemImage: "delete.left", action: onDelete)
                    .focused(focus, equals: -1)
            }
        }
        .focusSection()
    }

    @ViewBuilder
    private func key(label: String? = nil, systemImage: String? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ZStack {
                RoundedRectangle(cornerRadius: NuvioTheme.radii.md, style: .continuous)
                    .fill(colors.surfaceVariant.opacity(0.5))
                if let label {
                    Text(label).nuvioText(NuvioTextStyles.headline)
                } else if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: NuvioTheme.sizes.icons.md))
                }
            }
            .foregroundStyle(colors.textPrimary)
            // A key is a remote target, so its height is the app's own button height rather
            // than a number of its own — 128pt tall keys made the pad 584pt, over half the panel.
            .frame(width: keyWidth, height: NuvioTheme.components.buttonHeight)
        }
        .buttonStyle(NuvioRowButtonStyle(cornerRadius: NuvioTheme.radii.md, scaleOnFocus: true))
    }
}

// MARK: - Avatar

struct ProfileAvatar: View {
    @Environment(AvatarCatalog.self) private var avatars

    let profile: Profile
    var diameter: CGFloat = dp(72)

    var body: some View {
        Group {
            // The picture the profile actually carries, when the account has one. An SF Symbol
            // stands in only for profiles created here, or before the catalogue has loaded.
            if let url = avatars.imageURL(for: profile) {
                RemoteImage(url: url, contentMode: .fill) { symbolAvatar }
            } else {
                symbolAvatar
            }
        }
            .frame(width: diameter, height: diameter)
            .clipShape(Circle())
            .background {
                Circle().fill(Color(argbHex: profile.tintHex).opacity(0.85))
            }
            .overlay(alignment: .bottomTrailing) {
                if profile.isLocked {
                    Image(systemName: "lock.fill")
                        .font(.system(size: diameter * 0.2, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(diameter * 0.08)
                        .background(Circle().fill(.black.opacity(0.65)))
                }
            }
    }

    /// Falls back to a person glyph rather than nothing: a synced profile can arrive with an
    /// empty `symbol`, and `Image(systemName: "")` draws a blank circle.
    private var symbolAvatar: some View {
        Image(systemName: profile.symbol.nilIfBlank ?? "person.fill")
            .font(.system(size: diameter * 0.42, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: diameter, height: diameter)
    }
}
