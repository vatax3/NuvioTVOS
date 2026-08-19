import SwiftUI

/// Account section: backend configuration, the QR sign-in flow, and sync.
struct AccountSettingsContent: View {
    @Environment(\.nuvioColors) private var colors
    @Environment(NuvioAccountStore.self) private var account
    @Environment(Router.self) private var router
    @Environment(NuvioSyncService.self) private var sync
    @Environment(LibraryStore.self) private var library
    @Environment(CollectionStore.self) private var collections
    @Environment(AddonStore.self) private var addons
    @Environment(PluginStore.self) private var plugins
    @Environment(ProfileStore.self) private var profiles
    @Environment(AppSettings.self) private var settings

    @State private var serverAddress = ""
    @State private var backendUrl = ""
    @State private var publishableKey = ""
    @State private var tvLoginWebUrl = ""
    @State private var email = ""
    @State private var password = ""
    @State private var didLoadConfiguration = false
    @State private var discoveryMessage: String?
    @State private var isDiscovering = false
    /// Signing out erases this television's copy of the account. Android asks first, and so
    /// does this — there is no undo, and the row is one press away from Sync now.
    @State private var isConfirmingSignOut = false

    var body: some View {
        VStack(alignment: .leading, spacing: NuvioTheme.components.settings.rowGap) {
            if account.isSignedIn {
                signedInCard
                syncCard
                DeviceLinkingCard()
            } else {
                // Signing in comes first, because that is what someone opening this screen is
                // here to do. The server fields exist only because Nuvio's publishable key is a
                // build secret we cannot ship, and they belong under the thing they unblock —
                // not in front of it.
                signInCard
                serverCard
            }
        }
        .onAppear(perform: loadConfigurationOnce)
    }

    // MARK: Server

    @ViewBuilder
    private var serverCard: some View {
        SettingsCard(
            title: "Server",
            footnote: """
            Nuvio's backend URL is already right; its publishable key is a build-time secret in \
            the official app, absent from its public source, so it has to be pasted in once. A \
            self-hosted server can be found by address instead — Nuvio reads its \
            /.well-known/nuvio document for the rest, the same discovery the official app uses.
            """
        ) {
            SettingsTextFieldRow(
                title: "Publishable key",
                subtitle: "The anon / publishable key — safe to store on the device, it is what every Nuvio client ships",
                masked: true,
                text: $publishableKey
            )
            SettingsRow(
                title: "Save",
                systemImage: "checkmark.circle",
                action: saveConfiguration
            )

            SettingsTextFieldRow(
                title: "Self-hosted server",
                subtitle: "Find one by address instead",
                placeholder: "example.com",
                text: $serverAddress,
                trailingAction: (label: isDiscovering ? "Looking…" : "Connect", action: discover)
            )
            if let discoveryMessage {
                SettingsInfoRow(
                    title: "Status",
                    value: discoveryMessage,
                    tint: discoveryMessage.hasPrefix("Found") ? colors.success : colors.error
                )
            }

            SettingsTextFieldRow(
                title: "Backend URL",
                subtitle: "The Supabase project URL, e.g. https://xyz.supabase.co",
                placeholder: "https://…",
                text: $backendUrl
            )
            SettingsTextFieldRow(
                title: "Sign-in page URL",
                subtitle: "Only if the QR code 404s — the page the phone opens, e.g. https://nuvio.tv/tv-login. Left blank Nuvio derives it from the backend.",
                placeholder: "https://…/tv-login",
                text: $tvLoginWebUrl
            )
        }
    }

    // MARK: Sign in

    @ViewBuilder
    private var signInCard: some View {
        SettingsCard(
            title: "Sign in",
            footnote: account.isConfigured
                ? "Scan the code with a phone, sign in there, and this device is signed in too. Your library, progress, collections, addons and settings arrive straight away."
                : "Add the publishable key below first — without it there is no server to sign in to."
        ) {
            // The code itself lives on its own screen. It has to be large enough to scan from a
            // sofa, and a settings column that also holds a section rail has neither the width
            // nor — with no focusable row to scroll to — a way to bring it fully on screen.
            SettingsRow(
                title: "Sign in with a phone",
                subtitle: "Shows a QR code and a short code",
                systemImage: "qrcode",
                action: { router.push(.qrSignIn) }
            )
            .disabled(!account.isConfigured)
            .opacity(account.isConfigured ? 1 : NuvioTheme.effects.disabledAlpha)

            if case .failed(let message) = account.loginState {
                SettingsInfoRow(title: "Error", value: message, tint: colors.error)
            }
        }

        if account.isConfigured, account.configuration.supportsEmailPassword {
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
                title: isConfirmingSignOut ? "Sign out and erase — press again to confirm" : "Sign out",
                subtitle: isConfirmingSignOut
                    ? "Library, watch progress, collections, profiles, addons, plugins, debrid keys and settings are removed from this Apple TV"
                    : "Removes this account's content from this Apple TV",
                systemImage: "rectangle.portrait.and.arrow.right",
                action: signOut
            )
        }
    }

    /// Two presses, not a dialog: the confirmation has to say what is about to be destroyed,
    /// and saying it in the row itself puts the warning where the viewer is already looking.
    private func signOut() {
        guard isConfirmingSignOut else {
            isConfirmingSignOut = true
            return
        }
        isConfirmingSignOut = false
        sync.cancel()
        account.signOut()
        // Order matters: the session goes first so nothing can push the library back up while
        // it is being removed, and the wipe runs before the store graph is rebuilt around it.
        profiles.resetAfterSignOut()
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
        tvLoginWebUrl = account.configuration.tvLoginWebBaseUrlOverride
    }

    private func saveConfiguration() {
        account.save(configuration: NuvioServerConfiguration(
            backendUrl: backendUrl,
            publishableKey: publishableKey,
            tvLoginWebBaseUrlOverride: tvLoginWebUrl
        ))
    }

    private func discover() {
        let address = serverAddress
        guard !address.trimmingCharacters(in: .whitespaces).isEmpty, !isDiscovering else { return }
        isDiscovering = true
        discoveryMessage = nil
        Task {
            defer { isDiscovering = false }
            do {
                let discovered = try await NuvioServerDiscovery.discover(address)
                account.save(configuration: discovered)
                backendUrl = discovered.backendUrl
                publishableKey = discovered.publishableKey
                discoveryMessage = "Found it — sign in below."
            } catch {
                discoveryMessage = error.localizedDescription
            }
        }
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

// MARK: - Device linking

/// Port of `SyncCodeGenerateScreen` and `SyncCodeClaimScreen`, presented as one card since both
/// halves are short and only one is ever relevant to a given device.
struct DeviceLinkingCard: View {
    @Environment(\.nuvioColors) private var colors
    @Environment(NuvioAccountStore.self) private var account
    @Environment(NuvioSyncService.self) private var sync
    @Environment(LibraryStore.self) private var library
    @Environment(CollectionStore.self) private var collections
    @Environment(AddonStore.self) private var addons
    @Environment(PluginStore.self) private var plugins
    @Environment(ProfileStore.self) private var profiles
    @Environment(AppSettings.self) private var settings

    @State private var linking = DeviceLinkingStore()
    @State private var mode: Mode = .none
    @State private var pin = ""
    @State private var code = ""
    @State private var confirmingUnlink: LinkedDevice?

    private enum Mode { case none, share, join }

    private var deviceName: String {
        UIDevice.current.name.nilIfBlank ?? "Apple TV"
    }

    var body: some View {
        Group {
            SettingsCard(
                title: "Link another device",
                footnote: """
                Sharing gives another device a code so it reads and writes this account's library, \
                watch progress and settings. Joining points this device at somebody else's account \
                instead — its own local library is replaced by theirs.
                """
            ) {
                switch mode {
                case .none:
                    SettingsRow(
                        title: "Share this account",
                        subtitle: "Generate a code for another device",
                        systemImage: "square.and.arrow.up",
                        action: { start(.share) }
                    )
                    SettingsRow(
                        title: "Join another account",
                        subtitle: "Enter a code generated on another device",
                        systemImage: "square.and.arrow.down",
                        action: { start(.join) }
                    )
                case .share:
                    shareRows
                case .join:
                    joinRows
                }

                if case .working(let stage) = linking.phase {
                    SettingsInfoRow(title: "Status", value: stage)
                }
                if case .failed(let message) = linking.phase {
                    SettingsInfoRow(title: "Error", value: message, tint: colors.error)
                }
            }

            if !linking.linkedDevices.isEmpty {
                SettingsCard(
                    title: "Linked devices",
                    footnote: "Unlinking stops a device writing to this account. Its local copy stays on that device."
                ) {
                    ForEach(linking.linkedDevices) { device in
                        SettingsRow(
                            title: device.displayName,
                            subtitle: device.linkedDate.map {
                                "Linked \(DateFormatter.nuvioMediumDate.string(from: $0))"
                            } ?? "Linked",
                            systemImage: "tv.and.mediabox",
                            trailing: { SettingsValueLabel(value: "Unlink") },
                            action: { confirmingUnlink = device }
                        )
                    }
                }
            }
        }
        .task { await linking.loadLinkedDevices(account: account) }
        .alert(
            "Unlink \(confirmingUnlink?.displayName ?? "this device")?",
            isPresented: Binding(
                get: { confirmingUnlink != nil },
                set: { if !$0 { confirmingUnlink = nil } }
            )
        ) {
            Button("Unlink", role: .destructive) {
                if let device = confirmingUnlink {
                    Task { await linking.unlink(device, account: account) }
                }
                confirmingUnlink = nil
            }
            Button("Keep", role: .cancel) { confirmingUnlink = nil }
        } message: {
            Text("It stops syncing with this account. Nothing is deleted.")
        }
    }

    // MARK: Share

    @ViewBuilder
    private var shareRows: some View {
        if case .generated(let generated) = linking.phase {
            VStack(alignment: .leading, spacing: NuvioTheme.spacing.sm) {
                Text("Enter this code on the other device")
                    .nuvioText(NuvioTextStyles.metadata)
                    .foregroundStyle(colors.textTertiary)
                Text(generated)
                    .nuvioText(NuvioTextStyles.display)
                    .foregroundStyle(colors.secondary)
                Text("It also needs the PIN you just chose.")
                    .nuvioText(NuvioTextStyles.metadata)
                    .foregroundStyle(colors.textSecondary)
            }
            .padding(.horizontal, NuvioTheme.spacing.lg)
            .padding(.vertical, NuvioTheme.spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)

            SettingsRow(title: "Done", systemImage: "checkmark", action: { finish() })
        } else {
            SettingsTextFieldRow(
                title: "Choose a PIN",
                subtitle: "At least four digits. The other device has to type it with the code.",
                placeholder: "····",
                masked: true,
                text: $pin
            )
            SettingsRow(
                title: "Generate code",
                subtitle: "Uploads this device's data first, so the other one receives a complete account",
                systemImage: "number",
                action: {
                    Task {
                        await linking.generateCode(
                            pin: pin, account: account, sync: sync, library: library,
                            collections: collections, addons: addons, plugins: plugins,
                            profiles: profiles, settings: settings
                        )
                    }
                }
            )
            SettingsRow(
                title: "Show my existing code",
                subtitle: "If you already made one, this shows it again instead of replacing it",
                systemImage: "arrow.clockwise",
                action: { Task { await linking.fetchExistingCode(pin: pin) } }
            )
            SettingsRow(title: "Cancel", systemImage: "xmark", action: { finish() })
        }
    }

    // MARK: Join

    @ViewBuilder
    private var joinRows: some View {
        if case .claimed = linking.phase {
            SettingsInfoRow(
                title: "Linked",
                value: "This device now shares that account.",
                tint: colors.success
            )
            SettingsRow(title: "Done", systemImage: "checkmark", action: { finish() })
        } else {
            SettingsTextFieldRow(
                title: "Code",
                placeholder: "From the other device",
                text: $code
            )
            SettingsTextFieldRow(
                title: "PIN",
                placeholder: "····",
                masked: true,
                text: $pin
            )
            SettingsRow(
                title: "Link this device",
                subtitle: "Replaces this device's library with the account's",
                systemImage: "link",
                action: {
                    Task {
                        await linking.claim(
                            code: code, pin: pin, deviceName: deviceName,
                            account: account, sync: sync, library: library,
                            collections: collections, addons: addons, plugins: plugins,
                            profiles: profiles, settings: settings
                        )
                    }
                }
            )
            SettingsRow(title: "Cancel", systemImage: "xmark", action: { finish() })
        }
    }

    private func start(_ target: Mode) {
        pin = ""
        code = ""
        linking.reset()
        mode = target
    }

    private func finish() {
        pin = ""
        code = ""
        linking.reset()
        mode = .none
        Task { await linking.loadLinkedDevices(account: account) }
    }
}
