import SwiftUI

/// Port of `DebridSettingsScreen` — provider credentials plus the full stream shaping matrix
/// that `StreamFilterEngine` consumes.
struct DebridSettingsContent: View {
    @Environment(\.nuvioColors) private var colors
    @Environment(AppSettings.self) private var settings
    @Environment(Router.self) private var router

    enum Tab: String, CaseIterable, Identifiable {
        case providers, filters, ranking, limits
        var id: String { rawValue }
        var title: String {
            switch self {
            case .providers: return L10n.text("settings.debrid.tab_providers", fallback: "Providers")
            case .filters: return L10n.text("settings.debrid.tab_filters", fallback: "Filters")
            case .ranking: return L10n.text("settings.debrid.tab_ranking", fallback: "Ranking")
            case .limits: return L10n.text("settings.debrid.tab_limits", fallback: "Limits")
            }
        }
    }

    @State private var tab: Tab = .providers
    @State private var validationMessages: [DebridProvider: String] = [:]
    @State private var validating: DebridProvider?
    /// The device-code sign-in in flight, if any. One at a time: two codes on screen would be
    /// two things to type and only one of them right.
    @State private var deviceAuth: (provider: DebridProvider, code: DebridDeviceAuthorization)?
    @State private var deviceAuthMessage: String?
    @State private var deviceAuthTask: Task<Void, Never>?

    private var debrid: DebridSettingsStore { settings.debrid }

    var body: some View {
        @Bindable var debrid = debrid

        VStack(alignment: .leading, spacing: NuvioTheme.components.settings.rowGap) {
            SettingsCard(
                title: "Debrid",
                footnote: """
                A debrid service turns torrent sources into direct HTTP links. Without one, \
                torrent-only sources cannot play on Apple TV.
                """
            ) {
                SettingsToggle(
                    title: L10n.text("settings.debrid.enable", fallback: "Enable debrid"),
                    subtitle: debrid.canResolvePlayableLinks
                        ? "Resolving through \(debrid.activeResolver?.provider.displayName ?? "—")"
                        : L10n.text("settings.debrid.enable_hint", fallback: "Add at least one API key below"),
                    systemImage: "link",
                    isOn: $debrid.enabled
                )
                SettingsRow(
                    title: L10n.text("settings.debrid.stream_format", fallback: "Stream format"),
                    subtitle: L10n.text("settings.debrid.stream_format_sub", fallback: "Choose what each result is labelled — edited from a phone"),
                    systemImage: "textformat",
                    trailing: { SettingsValueLabel(value: "") },
                    action: { router.push(.streamFormat) }
                )
            }

            ChipRow(title: L10n.text("settings.debrid.section", fallback: "Section")) {
                ForEach(Tab.allCases) { option in
                    NuvioChip(label: option.title, isSelected: tab == option, action: { tab = option })
                }
            }

            switch tab {
            case .providers: providers
            case .filters: filters
            case .ranking: ranking
            case .limits: limits
            }
        }
    }

    // MARK: Providers

    private var providers: some View {
        @Bindable var debrid = debrid

        return VStack(alignment: .leading, spacing: NuvioTheme.components.settings.rowGap) {
            ForEach(DebridProvider.allCases) { provider in
                SettingsCard(title: provider.displayName) {
                    SettingsTextFieldRow(
                        title: L10n.text("settings.debrid.api_key", fallback: "API key"),
                        subtitle: provider.apiKeyHint,
                        placeholder: L10n.text("settings.debrid.paste_key", fallback: "Paste your key"),
                        masked: true,
                        text: binding(for: provider),
                        trailingAction: (
                            label: validating == provider ? L10n.text("settings.debrid.checking", fallback: "Checking…") : L10n.text("settings.debrid.verify", fallback: "Verify"),
                            action: { Task { await validate(provider) } }
                        )
                    )
                    if let message = validationMessages[provider] {
                        SettingsInfoRow(
                            title: L10n.text("settings.debrid.status", fallback: "Status"),
                            value: message,
                            tint: message.hasPrefix(L10n.text("settings.debrid.connected", fallback: "Connected")) ? colors.success : colors.error
                        )
                    }
                    if DebridClient.supportsDeviceAuthorization(provider) {
                        deviceAuthRows(for: provider)
                    }
                    SettingsInfoRow(
                        title: L10n.text("settings.debrid.capabilities", fallback: "Capabilities"),
                        value: [
                            provider.supportsCacheCheck ? L10n.text("settings.debrid.cap_cache", fallback: "cache check") : nil,
                            provider.supportsCloudLibrary ? L10n.text("settings.debrid.cap_cloud", fallback: "cloud library") : nil,
                            L10n.text("settings.debrid.cap_resolve", fallback: "link resolution")
                        ].compactMap { $0 }.joined(separator: " · ")
                    )
                }
            }

            SettingsCard(
                title: L10n.text("settings.debrid.resolver", fallback: "Resolver"),
                footnote: L10n.text("settings.debrid.resolver_footnote", fallback: "Which configured service turns a torrent into a playable link.")
            ) {
                if debrid.configuredCredentials.isEmpty {
                    SettingsInfoRow(title: L10n.text("settings.debrid.configured", fallback: "Configured"), value: L10n.text("settings.debrid.none_yet", fallback: "None yet"), tint: colors.textTertiary)
                } else {
                    ForEach(debrid.configuredCredentials) { credential in
                        SettingsRow(
                            title: credential.provider.displayName,
                            subtitle: debrid.activeResolver?.provider == credential.provider
                                ? L10n.text("settings.debrid.currently_resolver", fallback: "Currently used for resolution") : nil,
                            trailing: {
                                Image(systemName: debrid.activeResolver?.provider == credential.provider
                                      ? "checkmark.circle.fill" : "circle")
                                    .font(.system(size: NuvioTheme.sizes.icons.md))
                                    .foregroundStyle(debrid.activeResolver?.provider == credential.provider
                                                     ? colors.secondary : colors.textTertiary)
                            },
                            action: { debrid.preferredResolverProviderId = credential.provider.rawValue }
                        )
                    }
                }
                SettingsToggle(
                    title: L10n.text("settings.debrid.cloud_library", fallback: "Cloud library"),
                    subtitle: L10n.text("settings.debrid.cloud_library_sub", fallback: "Show files already in your debrid account as sources"),
                    systemImage: "cloud",
                    isOn: $debrid.cloudLibraryEnabled
                )
                SettingsStepperRow(
                    title: L10n.text("settings.debrid.preresolve", fallback: "Pre-resolve top sources"),
                    subtitle: L10n.text("settings.debrid.preresolve_sub", fallback: "Warm up links for the first N results so playback starts instantly"),
                    value: $debrid.instantPlaybackPreparationLimit,
                    range: 0...5
                )
            }
        }
    }

    /// Sign in by approving a code on a phone instead of typing a forty-character key with a
    /// remote control. TorBox only — see `DebridClient.supportsDeviceAuthorization`.
    @ViewBuilder
    private func deviceAuthRows(for provider: DebridProvider) -> some View {
        if let deviceAuth, deviceAuth.provider == provider {
            SettingsInfoRow(title: L10n.text("settings.debrid.code", fallback: "Code"), value: deviceAuth.code.userCode, tint: colors.secondary)
            SettingsInfoRow(
                title: L10n.text("settings.debrid.enter_it_at", fallback: "Enter it at"),
                value: deviceAuth.code.friendlyVerificationURL,
                tint: colors.textSecondary
            )
        }
        SettingsRow(
            title: deviceAuth?.provider == provider ? "Waiting for approval…" : L10n.text("settings.debrid.sign_in_code", fallback: "Sign in with a code"),
            subtitle: deviceAuth?.provider == provider
                ? L10n.text("settings.debrid.cancel", fallback: "Cancel")
                : L10n.text("settings.debrid.approve_on_phone", fallback: "Approve on your phone — nothing to type here"),
            systemImage: "qrcode",
            action: {
                if deviceAuth?.provider == provider {
                    cancelDeviceAuth()
                } else {
                    startDeviceAuth(provider)
                }
            }
        )
        if let deviceAuthMessage, deviceAuth?.provider == provider || deviceAuth == nil {
            SettingsInfoRow(
                title: L10n.text("settings.debrid.status", fallback: "Status"),
                value: deviceAuthMessage,
                tint: deviceAuthMessage.hasPrefix(L10n.text("settings.debrid.connected", fallback: "Connected")) ? colors.success : colors.error
            )
        }
    }

    private func startDeviceAuth(_ provider: DebridProvider) {
        cancelDeviceAuth()
        deviceAuthMessage = nil
        deviceAuthTask = Task {
            do {
                let code = try await DebridClient.shared.startDeviceAuthorization(provider: provider)
                deviceAuth = (provider, code)
                try await pollDeviceAuth(provider: provider, code: code)
            } catch is CancellationError {
            } catch {
                deviceAuth = nil
                deviceAuthMessage = error.localizedDescription
            }
        }
    }

    /// Polls at the interval the server asked for, for ten minutes. A `nil` redemption means the
    /// viewer has not approved yet, which is the normal case for most of that time; only a throw
    /// stops the loop.
    private func pollDeviceAuth(provider: DebridProvider, code: DebridDeviceAuthorization) async throws {
        let deadline = Date().addingTimeInterval(600)
        while !Task.isCancelled, Date() < deadline {
            try await Task.sleep(for: .seconds(code.intervalSeconds))
            let key = try? await DebridClient.shared.redeemDeviceAuthorization(
                provider: provider, deviceCode: code.deviceCode
            )
            guard let key, !key.isEmpty else { continue }
            debrid.setApiKey(key, for: provider)
            deviceAuth = nil
            deviceAuthMessage = L10n.text("settings.debrid.connected", fallback: "Connected")
            await validate(provider)
            return
        }
        deviceAuth = nil
        deviceAuthMessage = L10n.text("settings.debrid.code_expired", fallback: "The code expired before it was approved.")
    }

    private func cancelDeviceAuth() {
        deviceAuthTask?.cancel()
        deviceAuthTask = nil
        deviceAuth = nil
    }

    private func binding(for provider: DebridProvider) -> Binding<String> {
        Binding(
            get: { debrid.apiKey(for: provider) },
            set: { debrid.setApiKey($0, for: provider) }
        )
    }

    private func validate(_ provider: DebridProvider) async {
        let key = debrid.apiKey(for: provider).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            validationMessages[provider] = L10n.text("settings.debrid.need_key", fallback: "Enter a key first")
            return
        }
        validating = provider
        defer { validating = nil }
        let result = await DebridClient.shared.validate(
            credential: DebridCredential(provider: provider, apiKey: key)
        )
        switch result {
        case .success(let detail): validationMessages[provider] = "Connected — \(detail)"
        case .failure(let error): validationMessages[provider] = error.localizedDescription
        }
    }

    // MARK: Filters

    private var filters: some View {
        @Bindable var debrid = debrid

        return VStack(alignment: .leading, spacing: NuvioTheme.components.settings.rowGap) {
            SettingsCard(title: L10n.text("settings.debrid.quick_filters", fallback: "Quick filters")) {
                SettingsOptionRow(
                    title: L10n.text("settings.debrid.min_quality", fallback: "Minimum quality"),
                    systemImage: "arrow.up.right.square",
                    selection: $debrid.streamMinimumQuality
                )
                SettingsOptionRow(
                    title: "Dolby Vision",
                    systemImage: "sparkles.tv",
                    selection: $debrid.streamDolbyVisionFilter
                )
                SettingsOptionRow(
                    title: "HDR",
                    systemImage: "sun.max",
                    selection: $debrid.streamHdrFilter
                )
                SettingsOptionRow(
                    title: L10n.text("settings.debrid.codec", fallback: "Codec"),
                    systemImage: "film.stack",
                    selection: $debrid.streamCodecFilter
                )
            }

            SettingsCard(
                title: L10n.text("settings.debrid.resolutions", fallback: "Resolutions"),
                footnote: L10n.text("settings.debrid.required_footnote", fallback: "Required narrows to only those; excluded removes them entirely.")
            ) {
                SettingsMultiSelectRow(
                    title: L10n.text("settings.debrid.required", fallback: "Required"),
                    options: DebridStreamResolution.defaultOrder,
                    selection: preferencesBinding(\.requiredResolutions)
                )
                SettingsMultiSelectRow(
                    title: L10n.text("settings.debrid.excluded", fallback: "Excluded"),
                    options: DebridStreamResolution.defaultOrder,
                    selection: preferencesBinding(\.excludedResolutions)
                )
            }

            SettingsCard(title: L10n.text("settings.debrid.source_quality", fallback: "Source quality")) {
                SettingsMultiSelectRow(
                    title: L10n.text("settings.debrid.required", fallback: "Required"),
                    options: DebridStreamQuality.defaultOrder,
                    selection: preferencesBinding(\.requiredQualities)
                )
                SettingsMultiSelectRow(
                    title: L10n.text("settings.debrid.excluded", fallback: "Excluded"),
                    options: DebridStreamQuality.defaultOrder,
                    selection: preferencesBinding(\.excludedQualities)
                )
            }

            SettingsCard(title: L10n.text("settings.debrid.visual_tags", fallback: "Visual tags")) {
                SettingsMultiSelectRow(
                    title: L10n.text("settings.debrid.required", fallback: "Required"),
                    options: DebridStreamVisualTag.defaultOrder,
                    selection: preferencesBinding(\.requiredVisualTags)
                )
                SettingsMultiSelectRow(
                    title: L10n.text("settings.debrid.excluded", fallback: "Excluded"),
                    options: DebridStreamVisualTag.defaultOrder,
                    selection: preferencesBinding(\.excludedVisualTags)
                )
            }

            SettingsCard(title: L10n.text("settings.debrid.audio", fallback: "Audio")) {
                SettingsMultiSelectRow(
                    title: L10n.text("settings.debrid.required_formats", fallback: "Required formats"),
                    options: DebridStreamAudioTag.defaultOrder,
                    selection: preferencesBinding(\.requiredAudioTags)
                )
                SettingsMultiSelectRow(
                    title: L10n.text("settings.debrid.excluded_formats", fallback: "Excluded formats"),
                    options: DebridStreamAudioTag.defaultOrder,
                    selection: preferencesBinding(\.excludedAudioTags)
                )
                SettingsMultiSelectRow(
                    title: L10n.text("settings.debrid.required_channels", fallback: "Required channels"),
                    options: DebridStreamAudioChannel.defaultOrder,
                    selection: preferencesBinding(\.requiredAudioChannels)
                )
                SettingsMultiSelectRow(
                    title: L10n.text("settings.debrid.excluded_channels", fallback: "Excluded channels"),
                    options: DebridStreamAudioChannel.defaultOrder,
                    selection: preferencesBinding(\.excludedAudioChannels)
                )
            }

            SettingsCard(title: L10n.text("settings.debrid.encoding", fallback: "Encoding")) {
                SettingsMultiSelectRow(
                    title: L10n.text("settings.debrid.required", fallback: "Required"),
                    options: DebridStreamEncode.defaultOrder,
                    selection: preferencesBinding(\.requiredEncodes)
                )
                SettingsMultiSelectRow(
                    title: L10n.text("settings.debrid.excluded", fallback: "Excluded"),
                    options: DebridStreamEncode.defaultOrder,
                    selection: preferencesBinding(\.excludedEncodes)
                )
            }

            SettingsCard(title: L10n.text("settings.debrid.languages", fallback: "Languages")) {
                SettingsMultiSelectRow(
                    title: L10n.text("settings.debrid.required", fallback: "Required"),
                    selection: preferencesBinding(\.requiredLanguages)
                )
                SettingsMultiSelectRow(
                    title: L10n.text("settings.debrid.excluded", fallback: "Excluded"),
                    selection: preferencesBinding(\.excludedLanguages)
                )
            }
        }
    }

    // MARK: Ranking

    private var ranking: some View {
        @Bindable var debrid = debrid

        return VStack(alignment: .leading, spacing: NuvioTheme.components.settings.rowGap) {
            SettingsCard(
                title: "Sort",
                footnote: L10n.text("settings.debrid.ranking_footnote", fallback: "The ranked criteria below take precedence when any are enabled.")
            ) {
                SettingsOptionRow(
                    title: L10n.text("settings.debrid.simple_sort", fallback: "Simple sort"),
                    systemImage: "arrow.up.arrow.down",
                    selection: $debrid.streamSortMode
                )
            }

            SettingsCard(
                title: L10n.text("settings.debrid.preference_order", fallback: "Preference order"),
                footnote: L10n.text("settings.debrid.preference_order_footnote", fallback: "Position decides ranking — the first entry scores highest.")
            ) {
                SettingsPriorityListRow(
                    title: L10n.text("settings.debrid.resolutions", fallback: "Resolutions"),
                    order: preferencesBinding(\.preferredResolutions)
                )
                SettingsPriorityListRow(
                    title: L10n.text("settings.debrid.source_quality", fallback: "Source quality"),
                    order: preferencesBinding(\.preferredQualities)
                )
                SettingsPriorityListRow(
                    title: L10n.text("settings.debrid.visual_tags", fallback: "Visual tags"),
                    order: preferencesBinding(\.preferredVisualTags)
                )
                SettingsPriorityListRow(
                    title: L10n.text("settings.debrid.audio_formats", fallback: "Audio formats"),
                    order: preferencesBinding(\.preferredAudioTags)
                )
                SettingsPriorityListRow(
                    title: L10n.text("settings.debrid.audio_channels", fallback: "Audio channels"),
                    order: preferencesBinding(\.preferredAudioChannels)
                )
                SettingsPriorityListRow(
                    title: L10n.text("settings.debrid.encoding", fallback: "Encoding"),
                    order: preferencesBinding(\.preferredEncodes)
                )
            }
        }
    }

    // MARK: Limits

    private var limits: some View {
        @Bindable var debrid = debrid

        return VStack(alignment: .leading, spacing: NuvioTheme.components.settings.rowGap) {
            SettingsCard(title: L10n.text("settings.debrid.result_caps", fallback: "Result caps")) {
                SettingsStepperRow(
                    title: L10n.text("settings.debrid.max_sources", fallback: "Maximum sources"),
                    subtitle: L10n.text("settings.debrid.max_sources_sub", fallback: "0 shows everything the addons return"),
                    value: $debrid.streamMaxResults,
                    range: 0...100, step: 5,
                    format: { $0 == 0 ? L10n.text("settings.debrid.unlimited", fallback: "Unlimited") : "\($0)" }
                )
                SettingsStepperRow(
                    title: L10n.text("settings.debrid.per_resolution", fallback: "Per resolution"),
                    value: preferencesBinding(\.maxPerResolution),
                    range: 0...20,
                    format: { $0 == 0 ? L10n.text("settings.debrid.unlimited", fallback: "Unlimited") : "\($0)" }
                )
                SettingsStepperRow(
                    title: L10n.text("settings.debrid.per_quality", fallback: "Per quality"),
                    value: preferencesBinding(\.maxPerQuality),
                    range: 0...20,
                    format: { $0 == 0 ? L10n.text("settings.debrid.unlimited", fallback: "Unlimited") : "\($0)" }
                )
            }

            SettingsCard(title: L10n.text("settings.debrid.file_size", fallback: "File size")) {
                SettingsStepperRow(
                    title: L10n.text("settings.debrid.min_size", fallback: "Minimum size"),
                    value: preferencesBinding(\.sizeMinGb),
                    range: 0...100,
                    format: { $0 == 0 ? L10n.text("settings.debrid.any", fallback: "Any") : "\($0) GB" }
                )
                SettingsStepperRow(
                    title: L10n.text("settings.debrid.max_size", fallback: "Maximum size"),
                    value: preferencesBinding(\.sizeMaxGb),
                    range: 0...200, step: 5,
                    format: { $0 == 0 ? L10n.text("settings.debrid.any", fallback: "Any") : "\($0) GB" }
                )
            }
        }
    }

    // MARK: Preference binding helper

    /// Reads and writes one field of the persisted `DebridStreamPreferences` blob.
    private func preferencesBinding<Value>(
        _ keyPath: WritableKeyPath<DebridStreamPreferences, Value>
    ) -> Binding<Value> {
        Binding(
            get: { debrid.streamPreferences[keyPath: keyPath] },
            set: { newValue in
                var preferences = debrid.streamPreferences
                preferences[keyPath: keyPath] = newValue
                debrid.streamPreferences = preferences
            }
        )
    }
}
