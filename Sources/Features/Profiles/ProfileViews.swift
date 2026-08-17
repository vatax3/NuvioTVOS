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

            VStack(spacing: NuvioTheme.spacing.xl) {
                ProfileAvatar(profile: profile, diameter: dp(120))

                Text(profile.name)
                    .nuvioText(NuvioTextStyles.display)
                    .foregroundStyle(colors.textPrimary)

                Text(didFail ? "Wrong PIN — try again" : "Enter your PIN")
                    .nuvioText(NuvioTextStyles.bodyCompact)
                    .foregroundStyle(didFail ? colors.error : colors.textSecondary)

                pinDots

                PinKeypad(
                    onDigit: append,
                    onDelete: { entry = String(entry.dropLast()) },
                    focus: $keypadFocus
                )

                if profiles.hasMultipleProfiles {
                    Button(action: switchToPrimary) {
                        Text("Use another profile")
                            .nuvioText(NuvioTextStyles.button)
                            .padding(.horizontal, NuvioTheme.spacing.xl)
                            .frame(height: NuvioTheme.components.buttonHeight)
                    }
                    .buttonStyle(NuvioPillButtonStyle(emphasis: .ghost))
                }
            }
            .padding(NuvioTheme.layout.tvSafeHorizontal)
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

    var body: some View {
        VStack(spacing: NuvioTheme.spacing.md) {
            ForEach(rows, id: \.self) { row in
                HStack(spacing: NuvioTheme.spacing.md) {
                    ForEach(row, id: \.self) { digit in
                        key(label: "\(digit)") { onDigit(digit) }
                            .focused(focus, equals: digit)
                    }
                }
            }
            HStack(spacing: NuvioTheme.spacing.md) {
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
            .frame(width: dp(86), height: dp(64))
        }
        .buttonStyle(NuvioRowButtonStyle(cornerRadius: NuvioTheme.radii.md, scaleOnFocus: true))
    }
}

// MARK: - Avatar

struct ProfileAvatar: View {
    let profile: Profile
    var diameter: CGFloat = dp(72)

    var body: some View {
        Image(systemName: profile.symbol)
            .font(.system(size: diameter * 0.42, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: diameter, height: diameter)
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
}
