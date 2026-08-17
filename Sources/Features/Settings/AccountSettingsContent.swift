import SwiftUI

/// Account section: backend configuration, the QR sign-in flow, and sync.
struct AccountSettingsContent: View {
    @Environment(\.nuvioColors) private var colors
    @Environment(NuvioAccountStore.self) private var account
    @Environment(NuvioSyncService.self) private var sync
    @Environment(LibraryStore.self) private var library
    @Environment(CollectionStore.self) private var collections
    @Environment(AddonStore.self) private var addons
    @Environment(PluginStore.self) private var plugins
    @Environment(ProfileStore.self) private var profiles
    @Environment(AppSettings.self) private var settings

    @State private var backendUrl = ""
    @State private var publishableKey = ""
    @State private var email = ""
    @State private var password = ""
    @State private var didLoadConfiguration = false

    var body: some View {
        VStack(alignment: .leading, spacing: NuvioTheme.components.settings.rowGap) {
            if account.isSignedIn {
                signedInCard
                syncCard
            } else {
                serverCard
                if account.isConfigured { signInCard }
            }
        }
        .onAppear(perform: loadConfigurationOnce)
    }

    // MARK: Server

    private var serverCard: some View {
        SettingsCard(
            title: "Nuvio backend",
            footnote: """
            Nuvio's own backend URL and publishable key are build-time secrets in the official \
            app and are not in its public source, so they cannot be shipped here — paste them in, \
            or point this at a self-hosted server with the same schema. The official app has the \
            same custom-server option.
            """
        ) {
            SettingsTextFieldRow(
                title: "Backend URL",
                subtitle: "The Supabase project URL, e.g. https://xyz.supabase.co",
                placeholder: "https://…",
                text: $backendUrl
            )
            SettingsTextFieldRow(
                title: "Publishable key",
                subtitle: "The anon / publishable key — safe to store on the device, it is what every Nuvio client ships",
                masked: true,
                text: $publishableKey
            )
            SettingsRow(
                title: "Save backend",
                subtitle: "Then sign in below",
                systemImage: "server.rack",
                action: saveConfiguration
            )
        }
    }

    // MARK: Sign in

    @ViewBuilder
    private var signInCard: some View {
        SettingsCard(
            title: "Sign in",
            footnote: "Scan the code with a phone, sign in there, and this device is signed in too."
        ) {
            switch account.loginState {
            case .idle, .failed:
                SettingsRow(
                    title: "Sign in with a phone",
                    subtitle: "Shows a QR code and a short code",
                    systemImage: "qrcode",
                    action: { account.startTvLogin(deviceName: deviceName) }
                )
            case .starting:
                SettingsInfoRow(title: "Status", value: "Asking the server for a code…")
            case .pending(let code, let url, let expiresAt):
                pendingRow(code: code, url: url, expiresAt: expiresAt)
                SettingsRow(
                    title: "Cancel",
                    systemImage: "xmark",
                    action: { account.cancelLogin() }
                )
            case .exchanging:
                SettingsInfoRow(title: "Status", value: "Approved — finishing sign-in…")
            case .signedIn:
                EmptyView()
            }

            if case .failed(let message) = account.loginState {
                SettingsInfoRow(title: "Error", value: message, tint: colors.error)
            }
        }

        if account.configuration.supportsEmailPassword {
            SettingsCard(
                title: "Or use email and password",
                footnote: "The official deployment prefers phone sign-in; a self-hosted server may allow this."
            ) {
                SettingsTextFieldRow(title: "Email", placeholder: "you@example.com", text: $email)
                SettingsTextFieldRow(title: "Password", masked: true, text: $password)
                SettingsRow(
                    title: "Sign in",
                    systemImage: "arrow.right.circle",
                    action: {
                        Task { await account.signIn(email: email, password: password) }
                    }
                )
                .disabled(email.isEmpty || password.isEmpty)
                .opacity(email.isEmpty || password.isEmpty ? NuvioTheme.effects.disabledAlpha : 1)
            }
        }
    }

    private func pendingRow(code: String, url: String, expiresAt: Date) -> some View {
        HStack(alignment: .top, spacing: NuvioTheme.spacing.xl) {
            if let image = QRCodeRenderer.image(for: url) {
                Image(uiImage: image)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: dp(200), height: dp(200))
                    .padding(NuvioTheme.spacing.md)
                    .background {
                        RoundedRectangle(cornerRadius: NuvioTheme.radii.md, style: .continuous)
                            .fill(.white)
                    }
            }

            VStack(alignment: .leading, spacing: NuvioTheme.spacing.md) {
                Text("Go to")
                    .nuvioText(NuvioTextStyles.metadata)
                    .foregroundStyle(colors.textTertiary)
                Text(url)
                    .nuvioText(NuvioTextStyles.bodyCompact)
                    .foregroundStyle(colors.secondary)
                    .frame(maxWidth: dp(520), alignment: .leading)

                Text("Code")
                    .nuvioText(NuvioTextStyles.metadata)
                    .foregroundStyle(colors.textTertiary)
                Text(code)
                    .nuvioText(NuvioTextStyles.display)
                    .foregroundStyle(colors.textPrimary)

                Text("Expires \(expiresAt.formatted(date: .omitted, time: .shortened))")
                    .nuvioText(NuvioTypography.labelSmall)
                    .foregroundStyle(colors.textTertiary)
            }
        }
        .padding(.horizontal, NuvioTheme.spacing.lg)
        .padding(.vertical, NuvioTheme.spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Signed in

    private var signedInCard: some View {
        SettingsCard(title: "Nuvio account") {
            SettingsInfoRow(
                title: "Signed in as",
                value: account.accountLabel,
                tint: colors.success
            )
            if let owner = account.syncOwnerId, owner != account.session?.userId {
                SettingsInfoRow(
                    title: "Linked to",
                    value: String(owner.prefix(8)),
                    tint: colors.textSecondary
                )
            }
            SettingsRow(
                title: "Sign out",
                subtitle: "Local library and settings stay on this device",
                systemImage: "rectangle.portrait.and.arrow.right",
                action: { account.signOut() }
            )
        }
    }

    private var syncCard: some View {
        @Bindable var sync = sync

        return SettingsCard(
            title: "Sync",
            footnote: """
            Library, watch progress, collections, addons, plugin repositories and settings sync \
            per profile. Watch progress resolves per item by which device watched it most \
            recently, so the furthest-along position wins.
            """
        ) {
            SettingsToggle(
                title: "Sync with my account",
                systemImage: "arrow.triangle.2.circlepath",
                isOn: $sync.isEnabled
            )
            SettingsRow(
                title: "Sync now",
                subtitle: statusText,
                systemImage: "arrow.clockwise",
                action: runSync
            )
            .disabled(isSyncing)
            .opacity(isSyncing ? NuvioTheme.effects.disabledAlpha : 1)

            if case .failed(let message) = sync.status {
                SettingsInfoRow(title: "Error", value: message, tint: colors.error)
            }
        }
    }

    private var isSyncing: Bool {
        if case .syncing = sync.status { return true }
        return false
    }

    private var statusText: String {
        switch sync.status {
        case .idle: return "Never synced on this device"
        case .syncing(let stage): return "Syncing \(stage.lowercased())…"
        case .succeeded(let date):
            return "Last synced \(date.formatted(date: .abbreviated, time: .shortened))"
        case .failed: return "Last attempt failed"
        }
    }

    // MARK: Actions

    private var deviceName: String {
        // Shown on the phone so the viewer can tell which device is asking.
        UIDevice.current.name.nilIfBlank ?? "Apple TV"
    }

    private func loadConfigurationOnce() {
        guard !didLoadConfiguration else { return }
        didLoadConfiguration = true
        backendUrl = account.configuration.backendUrl
        publishableKey = account.configuration.publishableKey
    }

    private func saveConfiguration() {
        account.save(configuration: NuvioServerConfiguration(
            backendUrl: backendUrl,
            publishableKey: publishableKey
        ))
    }

    private func runSync() {
        sync.sync(
            account: account,
            library: library,
            collections: collections,
            addons: addons,
            plugins: plugins,
            profiles: profiles,
            settings: settings
        )
    }
}
