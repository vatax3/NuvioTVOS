import SwiftUI

/// Port of `DebridSettingsScreen` — provider credentials plus the full stream shaping matrix
/// that `StreamFilterEngine` consumes.
struct DebridSettingsContent: View {
    @Environment(\.nuvioColors) private var colors
    @Environment(AppSettings.self) private var settings

    enum Tab: String, CaseIterable, Identifiable {
        case providers, filters, ranking, limits
        var id: String { rawValue }
        var title: String {
            switch self {
            case .providers: return "Providers"
            case .filters: return "Filters"
            case .ranking: return "Ranking"
            case .limits: return "Limits"
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
                    title: "Enable debrid",
                    subtitle: debrid.canResolvePlayableLinks
                        ? "Resolving through \(debrid.activeResolver?.provider.displayName ?? "—")"
                        : "Add at least one API key below",
                    systemImage: "link",
                    isOn: $debrid.enabled
                )
            }

            ChipRow(title: "Section") {
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
                        title: "API key",
                        subtitle: provider.apiKeyHint,
                        placeholder: "Paste your key",
                        masked: true,
                        text: binding(for: provider),
                        trailingAction: (
                            label: validating == provider ? "Checking…" : "Verify",
                            action: { Task { await validate(provider) } }
                        )
                    )
                    if let message = validationMessages[provider] {
                        SettingsInfoRow(
                            title: "Status",
                            value: message,
                            tint: message.hasPrefix("Connected") ? colors.success : colors.error
                        )
                    }
                    if DebridClient.supportsDeviceAuthorization(provider) {
                        deviceAuthRows(for: provider)
                    }
                    SettingsInfoRow(
                        title: "Capabilities",
                        value: [
                            provider.supportsCacheCheck ? "cache check" : nil,
                            provider.supportsCloudLibrary ? "cloud library" : nil,
                            "link resolution"
                        ].compactMap { $0 }.joined(separator: " · ")
                    )
                }
            }

            SettingsCard(
                title: "Resolver",
                footnote: "Which configured service turns a torrent into a playable link."
            ) {
                if debrid.configuredCredentials.isEmpty {
                    SettingsInfoRow(title: "Configured", value: "None yet", tint: colors.textTertiary)
                } else {
                    ForEach(debrid.configuredCredentials) { credential in
                        SettingsRow(
                            title: credential.provider.displayName,
                            subtitle: debrid.activeResolver?.provider == credential.provider
                                ? "Currently used for resolution" : nil,
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
                    title: "Cloud library",
                    subtitle: "Show files already in your debrid account as sources",
                    systemImage: "cloud",
                    isOn: $debrid.cloudLibraryEnabled
                )
                SettingsStepperRow(
                    title: "Pre-resolve top sources",
                    subtitle: "Warm up links for the first N results so playback starts instantly",
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
            SettingsInfoRow(title: "Code", value: deviceAuth.code.userCode, tint: colors.secondary)
            SettingsInfoRow(
                title: "Enter it at",
                value: deviceAuth.code.friendlyVerificationURL,
                tint: colors.textSecondary
            )
        }
        SettingsRow(
            title: deviceAuth?.provider == provider ? "Waiting for approval…" : "Sign in with a code",
            subtitle: deviceAuth?.provider == provider
                ? "Cancel"
                : "Approve on your phone — nothing to type here",
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
                title: "Status",
                value: deviceAuthMessage,
                tint: deviceAuthMessage.hasPrefix("Connected") ? colors.success : colors.error
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
            deviceAuthMessage = "Connected"
            await validate(provider)
            return
        }
        deviceAuth = nil
        deviceAuthMessage = "The code expired before it was approved."
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
            validationMessages[provider] = "Enter a key first"
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
            SettingsCard(title: "Quick filters") {
                SettingsOptionRow(
                    title: "Minimum quality",
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
                    title: "Codec",
                    systemImage: "film.stack",
                    selection: $debrid.streamCodecFilter
                )
            }

            SettingsCard(
                title: "Resolutions",
                footnote: "Required narrows to only those; excluded removes them entirely."
            ) {
                SettingsMultiSelectRow(
                    title: "Required",
                    options: DebridStreamResolution.defaultOrder,
                    selection: preferencesBinding(\.requiredResolutions)
                )
                SettingsMultiSelectRow(
                    title: "Excluded",
                    options: DebridStreamResolution.defaultOrder,
                    selection: preferencesBinding(\.excludedResolutions)
                )
            }

            SettingsCard(title: "Source quality") {
                SettingsMultiSelectRow(
                    title: "Required",
                    options: DebridStreamQuality.defaultOrder,
                    selection: preferencesBinding(\.requiredQualities)
                )
                SettingsMultiSelectRow(
                    title: "Excluded",
                    options: DebridStreamQuality.defaultOrder,
                    selection: preferencesBinding(\.excludedQualities)
                )
            }

            SettingsCard(title: "Visual tags") {
                SettingsMultiSelectRow(
                    title: "Required",
                    options: DebridStreamVisualTag.defaultOrder,
                    selection: preferencesBinding(\.requiredVisualTags)
                )
                SettingsMultiSelectRow(
                    title: "Excluded",
                    options: DebridStreamVisualTag.defaultOrder,
                    selection: preferencesBinding(\.excludedVisualTags)
                )
            }

            SettingsCard(title: "Audio") {
                SettingsMultiSelectRow(
                    title: "Required formats",
                    options: DebridStreamAudioTag.defaultOrder,
                    selection: preferencesBinding(\.requiredAudioTags)
                )
                SettingsMultiSelectRow(
                    title: "Excluded formats",
                    options: DebridStreamAudioTag.defaultOrder,
                    selection: preferencesBinding(\.excludedAudioTags)
                )
                SettingsMultiSelectRow(
                    title: "Required channels",
                    options: DebridStreamAudioChannel.defaultOrder,
                    selection: preferencesBinding(\.requiredAudioChannels)
                )
                SettingsMultiSelectRow(
                    title: "Excluded channels",
                    options: DebridStreamAudioChannel.defaultOrder,
                    selection: preferencesBinding(\.excludedAudioChannels)
                )
            }

            SettingsCard(title: "Encoding") {
                SettingsMultiSelectRow(
                    title: "Required",
                    options: DebridStreamEncode.defaultOrder,
                    selection: preferencesBinding(\.requiredEncodes)
                )
                SettingsMultiSelectRow(
                    title: "Excluded",
                    options: DebridStreamEncode.defaultOrder,
                    selection: preferencesBinding(\.excludedEncodes)
                )
            }

            SettingsCard(title: "Languages") {
                SettingsMultiSelectRow(
                    title: "Required",
                    selection: preferencesBinding(\.requiredLanguages)
                )
                SettingsMultiSelectRow(
                    title: "Excluded",
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
                footnote: "The ranked criteria below take precedence when any are enabled."
            ) {
                SettingsOptionRow(
                    title: "Simple sort",
                    systemImage: "arrow.up.arrow.down",
                    selection: $debrid.streamSortMode
                )
            }

            SettingsCard(
                title: "Preference order",
                footnote: "Position decides ranking — the first entry scores highest."
            ) {
                SettingsPriorityListRow(
                    title: "Resolutions",
                    order: preferencesBinding(\.preferredResolutions)
                )
                SettingsPriorityListRow(
                    title: "Source quality",
                    order: preferencesBinding(\.preferredQualities)
                )
                SettingsPriorityListRow(
                    title: "Visual tags",
                    order: preferencesBinding(\.preferredVisualTags)
                )
                SettingsPriorityListRow(
                    title: "Audio formats",
                    order: preferencesBinding(\.preferredAudioTags)
                )
                SettingsPriorityListRow(
                    title: "Audio channels",
                    order: preferencesBinding(\.preferredAudioChannels)
                )
                SettingsPriorityListRow(
                    title: "Encoding",
                    order: preferencesBinding(\.preferredEncodes)
                )
            }
        }
    }

    // MARK: Limits

    private var limits: some View {
        @Bindable var debrid = debrid

        return VStack(alignment: .leading, spacing: NuvioTheme.components.settings.rowGap) {
            SettingsCard(title: "Result caps") {
                SettingsStepperRow(
                    title: "Maximum sources",
                    subtitle: "0 shows everything the addons return",
                    value: $debrid.streamMaxResults,
                    range: 0...100, step: 5,
                    format: { $0 == 0 ? "Unlimited" : "\($0)" }
                )
                SettingsStepperRow(
                    title: "Per resolution",
                    value: preferencesBinding(\.maxPerResolution),
                    range: 0...20,
                    format: { $0 == 0 ? "Unlimited" : "\($0)" }
                )
                SettingsStepperRow(
                    title: "Per quality",
                    value: preferencesBinding(\.maxPerQuality),
                    range: 0...20,
                    format: { $0 == 0 ? "Unlimited" : "\($0)" }
                )
            }

            SettingsCard(title: "File size") {
                SettingsStepperRow(
                    title: "Minimum size",
                    value: preferencesBinding(\.sizeMinGb),
                    range: 0...100,
                    format: { $0 == 0 ? "Any" : "\($0) GB" }
                )
                SettingsStepperRow(
                    title: "Maximum size",
                    value: preferencesBinding(\.sizeMaxGb),
                    range: 0...200, step: 5,
                    format: { $0 == 0 ? "Any" : "\($0) GB" }
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
