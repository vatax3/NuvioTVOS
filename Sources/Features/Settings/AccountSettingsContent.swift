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
                // here to do. Nuvio's own backend is filled in and ready, so the server fields
                // are for a self-hosted instance — under the thing they unblock, not in front
                // of it.
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
            title: L10n.text("settings.account.server", fallback: "Server"),
            footnote: """
            Nuvio's own backend and key are already filled in — nothing to do here to use a \
            Nuvio account. A self-hosted server can be found by address instead: Nuvio reads its \
            /.well-known/nuvio document for the rest, the same discovery the official app uses.
            """
        ) {
            SettingsTextFieldRow(
                title: L10n.text("settings.account.publishable_key", fallback: "Publishable key"),
                subtitle: L10n.text("settings.account.publishable_key_sub", fallback: "The anon / publishable key — safe to store on the device, it is what every Nuvio client ships"),
                masked: true,
                text: $publishableKey
            )
            SettingsRow(
                title: L10n.text("settings.account.save", fallback: "Save"),
                systemImage: "checkmark.circle",
                action: saveConfiguration
            )

            SettingsTextFieldRow(
                title: L10n.text("settings.account.self_hosted", fallback: "Self-hosted server"),
                subtitle: L10n.text("settings.account.find_by_address", fallback: "Find one by address instead"),
                placeholder: "example.com",
                text: $serverAddress,
                trailingAction: (label: isDiscovering ? L10n.text("settings.account.looking", fallback: "Looking…") : L10n.text("settings.account.connect", fallback: "Connect"), action: discover)
            )
            if let discoveryMessage {
                SettingsInfoRow(
                    title: L10n.text("settings.account.status", fallback: "Status"),
                    value: discoveryMessage,
                    tint: discoveryMessage.hasPrefix(L10n.text("settings.account.found", fallback: "Found")) ? colors.success : colors.error
                )
            }

            SettingsTextFieldRow(
                title: L10n.text("settings.account.backend_url", fallback: "Backend URL"),
                subtitle: L10n.text("settings.account.backend_url_sub", fallback: "The Supabase project URL, e.g. https://xyz.supabase.co"),
                placeholder: "https://…",
                text: $backendUrl
            )
            SettingsTextFieldRow(
                title: L10n.text("settings.account.signin_url", fallback: "Sign-in page URL"),
                subtitle: L10n.text("settings.account.signin_url_sub", fallback: "Only if the QR code 404s — the page the phone opens, e.g. https://nuvio.tv/tv-login. Left blank Nuvio derives it from the backend."),
                placeholder: "https://…/tv-login",
                text: $tvLoginWebUrl
            )
        }
    }

    // MARK: Sign in

    @ViewBuilder
    private var signInCard: some View {
        SettingsCard(
            title: L10n.text("settings.account.sign_in", fallback: "Sign in"),
            footnote: account.isConfigured
                ? L10n.text("settings.account.sign_in_footnote", fallback: "Scan the code with a phone, sign in there, and this device is signed in too. Your library, progress, collections, addons and settings arrive straight away.")
                : L10n.text("settings.account.no_key_footnote", fallback: "This server has no publishable key, so there is nothing to sign in to. Fill it in below, or clear the backend URL to go back to Nuvio's.")
        ) {
            // The code itself lives on its own screen. It has to be large enough to scan from a
            // sofa, and a settings column that also holds a section rail has neither the width
            // nor — with no focusable row to scroll to — a way to bring it fully on screen.
            SettingsRow(
                title: L10n.text("settings.account.sign_in_phone", fallback: "Sign in with a phone"),
                subtitle: L10n.text("settings.account.sign_in_phone_sub", fallback: "Shows a QR code and a short code"),
                systemImage: "qrcode",
                action: { router.push(.qrSignIn) }
            )
            .disabled(!account.isConfigured)
            .opacity(account.isConfigured ? 1 : NuvioTheme.effects.disabledAlpha)

            if case .failed(let message) = account.loginState {
                SettingsInfoRow(title: L10n.text("settings.account.error", fallback: "Error"), value: message, tint: colors.error)
            }
        }

        if account.isConfigured, account.configuration.supportsEmailPassword {
            SettingsCard(
                title: L10n.text("settings.account.or_email", fallback: "Or use email and password"),
                footnote: L10n.text("settings.account.or_email_footnote", fallback: "The official deployment prefers phone sign-in; a self-hosted server may allow this.")
            ) {
                SettingsTextFieldRow(title: L10n.text("settings.account.email", fallback: "Email"), placeholder: "you@example.com", text: $email)
                SettingsTextFieldRow(title: L10n.text("settings.account.password", fallback: "Password"), masked: true, text: $password)
                SettingsRow(
                    title: L10n.text("settings.account.sign_in", fallback: "Sign in"),
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
        SettingsCard(title: L10n.text("settings.account.nuvio_account", fallback: "Nuvio account")) {
            SettingsInfoRow(
                title: L10n.text("settings.account.signed_in_as", fallback: "Signed in as"),
                value: account.accountLabel,
                tint: colors.success
            )
            if let owner = account.syncOwnerId, owner != account.session?.userId {
                SettingsInfoRow(
                    title: L10n.text("settings.account.linked_to", fallback: "Linked to"),
                    value: String(owner.prefix(8)),
                    tint: colors.textSecondary
                )
            }
            SettingsRow(
                title: isConfirmingSignOut ? L10n.text("settings.account.sign_out_confirm", fallback: "Sign out and erase — press again to confirm") : L10n.text("settings.account.sign_out", fallback: "Sign out"),
                subtitle: isConfirmingSignOut
                    ? L10n.text("settings.account.sign_out_sub", fallback: "Library, watch progress, collections, profiles, addons, plugins, debrid keys and settings are removed from this Apple TV")
                    : L10n.text("settings.account.sign_out_short", fallback: "Removes this account's content from this Apple TV"),
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
            title: L10n.text("settings.account.sync", fallback: "Sync"),
            footnote: """
            Library, watch progress, collections, addons, plugin repositories and settings sync \
            per profile. Watch progress resolves per item by which device watched it most \
            recently, so the furthest-along position wins.
            """
        ) {
            SettingsToggle(
                title: L10n.text("settings.account.sync_enabled", fallback: "Sync with my account"),
                systemImage: "arrow.triangle.2.circlepath",
                isOn: $sync.isEnabled
            )
            SettingsRow(
                title: L10n.text("settings.account.sync_now", fallback: "Sync now"),
                subtitle: statusText,
                systemImage: "arrow.clockwise",
                action: runSync
            )
            .disabled(isSyncing)
            .opacity(isSyncing ? NuvioTheme.effects.disabledAlpha : 1)

            if case .failed(let message) = sync.status {
                SettingsInfoRow(title: L10n.text("settings.account.error", fallback: "Error"), value: message, tint: colors.error)
            }
        }
    }

    private var isSyncing: Bool {
        if case .syncing = sync.status { return true }
        return false
    }

    private var statusText: String {
        switch sync.status {
        case .idle: return L10n.text("settings.account.never_synced", fallback: "Never synced on this device")
        case .syncing(let stage): return "Syncing \(stage.lowercased())…"
        case .succeeded(let date):
            return "Last synced \(date.formatted(date: .abbreviated, time: .shortened))"
        case .failed: return L10n.text("settings.account.last_failed", fallback: "Last attempt failed")
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
                discoveryMessage = L10n.text("settings.account.found_it", fallback: "Found it — sign in below.")
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
                title: L10n.text("settings.account.link_another", fallback: "Link another device"),
                footnote: """
                Sharing gives another device a code so it reads and writes this account's library, \
                watch progress and settings. Joining points this device at somebody else's account \
                instead — its own local library is replaced by theirs.
                """
            ) {
                switch mode {
                case .none:
                    SettingsRow(
                        title: L10n.text("settings.account.share_account", fallback: "Share this account"),
                        subtitle: L10n.text("settings.account.share_account_sub", fallback: "Generate a code for another device"),
                        systemImage: "square.and.arrow.up",
                        action: { start(.share) }
                    )
                    SettingsRow(
                        title: L10n.text("settings.account.join_account", fallback: "Join another account"),
                        subtitle: L10n.text("settings.account.join_account_sub", fallback: "Enter a code generated on another device"),
                        systemImage: "square.and.arrow.down",
                        action: { start(.join) }
                    )
                case .share:
                    shareRows
                case .join:
                    joinRows
                }

                if case .working(let stage) = linking.phase {
                    SettingsInfoRow(title: L10n.text("settings.account.status", fallback: "Status"), value: stage)
                }
                if case .failed(let message) = linking.phase {
                    SettingsInfoRow(title: L10n.text("settings.account.error", fallback: "Error"), value: message, tint: colors.error)
                }
            }

            if !linking.linkedDevices.isEmpty {
                SettingsCard(
                    title: L10n.text("settings.account.linked_devices", fallback: "Linked devices"),
                    footnote: L10n.text("settings.account.linked_devices_footnote", fallback: "Unlinking stops a device writing to this account. Its local copy stays on that device.")
                ) {
                    ForEach(linking.linkedDevices) { device in
                        SettingsRow(
                            title: device.displayName,
                            subtitle: device.linkedDate.map {
                                "Linked \(DateFormatter.nuvioMediumDate.string(from: $0))"
                            } ?? L10n.text("settings.account.linked", fallback: "Linked"),
                            systemImage: "tv.and.mediabox",
                            trailing: { SettingsValueLabel(value: L10n.text("settings.account.unlink", fallback: "Unlink")) },
                            action: { confirmingUnlink = device }
                        )
                    }
                }
            }
        }
        .task { await linking.loadLinkedDevices(account: account) }
        .alert(
            "Unlink \(confirmingUnlink?.displayName ?? L10n.text("settings.account.this_device", fallback: "this device"))?",
            isPresented: Binding(
                get: { confirmingUnlink != nil },
                set: { if !$0 { confirmingUnlink = nil } }
            )
        ) {
            Button(L10n.text("settings.account.unlink", fallback: "Unlink"), role: .destructive) {
                if let device = confirmingUnlink {
                    Task { await linking.unlink(device, account: account) }
                }
                confirmingUnlink = nil
            }
            Button(L10n.text("settings.account.keep", fallback: "Keep"), role: .cancel) { confirmingUnlink = nil }
        } message: {
            Text(L10n.text("settings.account.unlink_message", fallback: "It stops syncing with this account. Nothing is deleted."))
        }
    }

    // MARK: Share

    @ViewBuilder
    private var shareRows: some View {
        if case .generated(let generated) = linking.phase {
            VStack(alignment: .leading, spacing: NuvioTheme.spacing.sm) {
                Text(L10n.text("settings.account.enter_code_other", fallback: "Enter this code on the other device"))
                    .nuvioText(NuvioTextStyles.metadata)
                    .foregroundStyle(colors.textTertiary)
                Text(generated)
                    .nuvioText(NuvioTextStyles.display)
                    .foregroundStyle(colors.secondary)
                Text(L10n.text("settings.account.needs_pin_too", fallback: "It also needs the PIN you just chose."))
                    .nuvioText(NuvioTextStyles.metadata)
                    .foregroundStyle(colors.textSecondary)
            }
            .padding(.horizontal, NuvioTheme.spacing.lg)
            .padding(.vertical, NuvioTheme.spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)

            SettingsRow(title: L10n.text("settings.account.done", fallback: "Done"), systemImage: "checkmark", action: { finish() })
        } else {
            SettingsTextFieldRow(
                title: L10n.text("settings.account.choose_pin", fallback: "Choose a PIN"),
                subtitle: L10n.text("settings.account.choose_pin_sub", fallback: "At least four digits. The other device has to type it with the code."),
                placeholder: "····",
                masked: true,
                text: $pin
            )
            SettingsRow(
                title: L10n.text("settings.account.generate_code", fallback: "Generate code"),
                subtitle: L10n.text("settings.account.generate_code_sub", fallback: "Uploads this device's data first, so the other one receives a complete account"),
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
                title: L10n.text("settings.account.show_existing", fallback: "Show my existing code"),
                subtitle: L10n.text("settings.account.show_existing_sub", fallback: "If you already made one, this shows it again instead of replacing it"),
                systemImage: "arrow.clockwise",
                action: { Task { await linking.fetchExistingCode(pin: pin) } }
            )
            SettingsRow(title: L10n.text("settings.account.cancel", fallback: "Cancel"), systemImage: "xmark", action: { finish() })
        }
    }

    // MARK: Join

    @ViewBuilder
    private var joinRows: some View {
        if case .claimed = linking.phase {
            SettingsInfoRow(
                title: L10n.text("settings.account.linked", fallback: "Linked"),
                value: L10n.text("settings.account.now_shared", fallback: "This device now shares that account."),
                tint: colors.success
            )
            SettingsRow(title: L10n.text("settings.account.done", fallback: "Done"), systemImage: "checkmark", action: { finish() })
        } else {
            SettingsTextFieldRow(
                title: L10n.text("settings.account.code", fallback: "Code"),
                placeholder: L10n.text("settings.account.from_other_device", fallback: "From the other device"),
                text: $code
            )
            SettingsTextFieldRow(
                title: "PIN",
                placeholder: "····",
                masked: true,
                text: $pin
            )
            SettingsRow(
                title: L10n.text("settings.account.link_this_device", fallback: "Link this device"),
                subtitle: L10n.text("settings.account.link_this_device_sub", fallback: "Replaces this device's library with the account's"),
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
            SettingsRow(title: L10n.text("settings.account.cancel", fallback: "Cancel"), systemImage: "xmark", action: { finish() })
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
