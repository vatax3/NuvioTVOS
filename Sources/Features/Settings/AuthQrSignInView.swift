import SwiftUI

/// Port of `AuthQrSignInScreen` — the full-screen QR sign-in.
///
/// This has to be its own screen rather than a card in Settings. A QR code has to be big enough
/// to scan across a living room, and at that size it does not fit in the settings column beside
/// the section rail. Worse, a QR card holds nothing focusable, so on tvOS the remote cannot
/// scroll the list far enough to bring it fully into view — the code ends up permanently clipped.
///
/// The layout follows the Android one: a brand panel on the left, and a fixed-width login pane
/// on the right carrying the code, the short code and the actions.
struct AuthQrSignInView: View {
    @Environment(\.nuvioColors) private var colors
    @Environment(\.dismiss) private var dismiss
    @Environment(NuvioAccountStore.self) private var account

    /// Ticks once a second so the expiry countdown stays live.
    @State private var now = Date()

    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            colors.background.ignoresSafeArea()

            HStack(spacing: 0) {
                brandPanel
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    .padding(.horizontal, dp(56))

                loginPane
                    .frame(width: dp(460))
                    .frame(maxHeight: .infinity)
                    .background(colors.surface)
                    .overlay(alignment: .leading) {
                        Rectangle()
                            .fill(colors.border)
                            .frame(width: NuvioTheme.strokes.hairline)
                    }
            }
        }
        .onReceive(tick) { now = $0 }
        .onExitCommand { dismiss() }
        .task {
            // Arriving on this screen is the request — no extra button press to get a code.
            if case .idle = account.loginState {
                account.startTvLogin(deviceName: deviceName)
            }
        }
        .onChange(of: account.isSignedIn) { _, signedIn in
            if signedIn { dismiss() }
        }
        .onDisappear { account.cancelLogin() }
    }

    // MARK: Brand panel

    private var brandPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("NUVIO")
                .nuvioText(NuvioTextStyles.display)
                .foregroundStyle(colors.textPrimary)
                .frame(height: dp(60), alignment: .leading)

            Spacer().frame(height: dp(32))

            Text(L10n.text("settings.qr_signin.headline", fallback: "Watch your library, anywhere"))
                .font(.system(size: sp(40), weight: .semibold))
                .foregroundStyle(colors.textPrimary)
                .frame(maxWidth: dp(440), alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)

            Spacer().frame(height: dp(18))

            Text(
                account.isSignedIn
                    ? L10n.text("settings.qr_signin.connected", fallback: "Your account is connected on this TV.")
                    : L10n.text("settings.qr_signin.use_phone", fallback: "Use your phone to sign in with email/password. TV stays QR-only for faster login.")
            )
            .font(.system(size: sp(17)))
            .foregroundStyle(colors.textSecondary)
            .frame(maxWidth: dp(400), alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)

            if account.isSignedIn {
                Spacer().frame(height: dp(24))
                Text(account.accountLabel)
                    .nuvioText(NuvioTextStyles.headline)
                    .foregroundStyle(colors.success)
            }
        }
    }

    // MARK: Login pane

    private var loginPane: some View {
        VStack(spacing: 0) {
            Spacer()

            Text(L10n.text("settings.qr_signin.title", fallback: "Account Login"))
                .font(.system(size: sp(30), weight: .semibold))
                .foregroundStyle(colors.textPrimary)

            Spacer().frame(height: dp(10))

            Text(instruction)
                .font(.system(size: sp(15)))
                .foregroundStyle(colors.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Spacer().frame(height: dp(28))

            codeBlock

            Spacer().frame(height: dp(28))

            actions

            Spacer()
        }
        .padding(.horizontal, dp(48))
        .focusSection()
    }

    private var instruction: String {
        account.isSignedIn
            ? L10n.text("settings.qr_signin.your_data", fallback: "Your synced data")
            : L10n.text("settings.qr_signin.scan_instructions", fallback: "Scan QR, approve in browser, then return here.")
    }

    // MARK: Code

    @ViewBuilder
    private var codeBlock: some View {
        switch account.loginState {
        case .pending(let code, let url, let expiresAt):
            VStack(spacing: 0) {
                qrImage(for: url)

                Spacer().frame(height: dp(18))

                // The address is spelled out, not just encoded. When the QR leads nowhere the
                // cause is almost always this URL, and there is no other way to see it on a TV.
                Text(url)
                    .nuvioText(NuvioTypography.labelSmall)
                    .foregroundStyle(colors.textTertiary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .truncationMode(.middle)

                Spacer().frame(height: dp(6))

                Text("Code: \(code)")
                    .nuvioText(NuvioTextStyles.bodyCompact)
                    .foregroundStyle(colors.textPrimary)
                    .monospaced()

                Spacer().frame(height: dp(6))

                Text("Expires in \(countdown(to: expiresAt))")
                    .nuvioText(NuvioTypography.labelSmall)
                    .foregroundStyle(colors.textTertiary)
            }

        case .exchanging:
            placeholder(L10n.text("settings.qr_signin.finishing", fallback: "Finishing sign in…"))

        case .starting:
            placeholder(L10n.text("settings.qr_signin.generating", fallback: "Generating QR…"))

        case .failed(let message):
            VStack(spacing: dp(14)) {
                placeholder(L10n.text("settings.qr_signin.unavailable", fallback: "QR unavailable. Refresh to retry."))
                Text(message)
                    .nuvioText(NuvioTypography.labelSmall)
                    .foregroundStyle(colors.error)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

        case .idle, .signedIn:
            placeholder(account.isSignedIn ? L10n.text("settings.qr_signin.signed_in", fallback: "Signed in") : L10n.text("settings.qr_signin.refresh_hint", fallback: "Refresh to get a code."))
        }
    }

    @ViewBuilder
    private func qrImage(for url: String) -> some View {
        if let image = QRCodeRenderer.image(for: url) {
            Image(uiImage: image)
                // Nearest-neighbour: a QR is a bitmask, and smoothing its edges is exactly what
                // makes a phone camera fail to lock onto it.
                .interpolation(.none)
                .resizable()
                .scaledToFit()
                .frame(width: dp(206) - dp(16), height: dp(206) - dp(16))
                .padding(dp(8))
                .background {
                    RoundedRectangle(cornerRadius: dp(8), style: .continuous).fill(.white)
                }
        } else {
            placeholder(L10n.text("settings.qr_signin.unavailable", fallback: "QR unavailable. Refresh to retry."))
        }
    }

    private func placeholder(_ message: String) -> some View {
        RoundedRectangle(cornerRadius: dp(8), style: .continuous)
            .fill(colors.surfaceVariant)
            .overlay {
                RoundedRectangle(cornerRadius: dp(8), style: .continuous)
                    .strokeBorder(colors.border, lineWidth: NuvioTheme.strokes.hairline)
            }
            .overlay {
                Text(message)
                    .nuvioText(NuvioTextStyles.bodyCompact)
                    .foregroundStyle(colors.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(NuvioTheme.spacing.md)
            }
            .frame(width: dp(206), height: dp(206))
    }

    // MARK: Actions

    private var actions: some View {
        HStack(spacing: NuvioTheme.spacing.md) {
            Button(refreshLabel) {
                account.cancelLogin()
                account.startTvLogin(deviceName: deviceName)
            }
            .buttonStyle(NuvioRowButtonStyle(cornerRadius: dp(16)))
            .disabled(isBusy)
            .opacity(isBusy ? NuvioTheme.effects.disabledAlpha : 1)

            Button(L10n.text("settings.qr_signin.back", fallback: "Back")) { dismiss() }
                .buttonStyle(NuvioRowButtonStyle(cornerRadius: dp(16)))
        }
    }

    private var isBusy: Bool {
        switch account.loginState {
        case .starting, .exchanging: return true
        default: return false
        }
    }

    private var refreshLabel: String { isBusy ? L10n.text("settings.qr_signin.please_wait", fallback: "Please wait…") : L10n.text("settings.qr_signin.refresh", fallback: "Refresh QR") }

    // MARK: Helpers

    private func countdown(to date: Date) -> String {
        let remaining = max(0, Int(date.timeIntervalSince(now)))
        return String(format: "%d:%02d", remaining / 60, remaining % 60)
    }

    private var deviceName: String {
        UIDevice.current.name.nilIfBlank ?? "Apple TV"
    }
}
