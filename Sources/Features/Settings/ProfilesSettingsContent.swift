import SwiftUI

/// Profiles section: switch, create, edit and lock. Each profile owns its own library, watch
/// progress, addons and settings — switching rebuilds the whole store graph.
struct ProfilesSettingsContent: View {
    @Environment(\.nuvioColors) private var colors
    @Environment(ProfileStore.self) private var profiles

    @State private var isSwitching = false
    @State private var editing: Profile?
    @State private var isCreating = false

    var body: some View {
        Group {
            SettingsCard(
                title: "Profiles",
                footnote: "Each profile keeps its own library, watch progress, addons and settings."
            ) {
                ForEach(profiles.profiles) { profile in
                    SettingsRow(
                        title: profile.name,
                        subtitle: subtitle(for: profile),
                        systemImage: profile.symbol,
                        trailing: {
                            SettingsValueLabel(
                                value: profile.id == profiles.activeProfileId ? "Current" : ""
                            )
                        },
                        action: { editing = profile }
                    )
                }
            }

            SettingsCard(title: "Manage") {
                SettingsRow(
                    title: "Switch profile",
                    subtitle: "\(profiles.profiles.count) profile\(profiles.profiles.count == 1 ? "" : "s")",
                    systemImage: "arrow.left.arrow.right",
                    action: { isSwitching = true }
                )
                SettingsRow(
                    title: "Add profile",
                    subtitle: "Create a separate library and settings",
                    systemImage: "plus.circle",
                    action: { isCreating = true }
                )
            }
        }
        .sheet(isPresented: $isSwitching) { ProfileSwitcherView() }
        .sheet(isPresented: $isCreating) { ProfileEditorView(profile: nil) }
        .sheet(item: $editing) { profile in ProfileEditorView(profile: profile) }
    }

    private func subtitle(for profile: Profile) -> String {
        var parts: [String] = []
        if profile.isLocked { parts.append("PIN protected") }
        if profile.isRestricted { parts.append("Restricted") }
        if profile.id == ProfileScope.primaryProfileId { parts.append("Primary") }
        return parts.isEmpty ? "No restrictions" : parts.joined(separator: " · ")
    }
}

/// Create / edit one profile. A nil `profile` means "create".
struct ProfileEditorView: View {
    @Environment(\.nuvioColors) private var colors
    @Environment(ProfileStore.self) private var profiles
    @Environment(\.dismiss) private var dismiss

    let profile: Profile?

    @State private var name = ""
    @State private var symbol = Profile.availableSymbols[0]
    @State private var tintHex = Profile.availableTints[0]
    @State private var isRestricted = false
    @State private var pin = ""
    @State private var didLoad = false
    @State private var isConfirmingDelete = false

    private var isEditing: Bool { profile != nil }
    private var isPrimary: Bool { profile?.id == ProfileScope.primaryProfileId }

    var body: some View {
        NuvioScreenBackground {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: NuvioTheme.components.settings.rowGap) {
                    Text(isEditing ? "Edit profile" : "New profile")
                        .nuvioText(NuvioTextStyles.display)
                        .foregroundStyle(colors.textPrimary)

                    SettingsCard(title: "Identity") {
                        SettingsTextFieldRow(
                            title: "Name",
                            placeholder: "Profile name",
                            text: $name
                        )
                        symbolPicker
                        tintPicker
                    }

                    SettingsCard(
                        title: "Lock",
                        footnote: isPrimary
                            ? "The primary profile can be locked, but anyone can still switch back to it from the lock screen — a profile PIN separates libraries, it is not a device passcode."
                            : "Leave empty for no PIN. Four digits."
                    ) {
                        SettingsTextFieldRow(
                            title: "PIN",
                            subtitle: profile?.isLocked == true ? "A PIN is already set — type a new one to replace it, or clear the field to remove it." : nil,
                            placeholder: "····",
                            masked: true,
                            text: $pin
                        )
                    }

                    SettingsCard(
                        title: "Restrictions",
                        footnote: "A restricted profile cannot open Playback, Debrid or Addon settings."
                    ) {
                        SettingsToggle(
                            title: "Restricted profile",
                            systemImage: "hand.raised.fill",
                            isOn: $isRestricted
                        )
                    }

                    actions
                }
                .padding(.bottom, NuvioTheme.spacing.xxxl)
            }
            .scrollClipDisabled()
        }
        .onAppear(perform: loadOnce)
        .alert("Delete this profile?", isPresented: $isConfirmingDelete) {
            Button("Delete", role: .destructive) {
                if let profile { profiles.delete(profile) }
                dismiss()
            }
            Button("Keep", role: .cancel) {}
        } message: {
            Text("Its library, watch history, addons and settings are erased. This cannot be undone.")
        }
    }

    private var symbolPicker: some View {
        VStack(alignment: .leading, spacing: NuvioTheme.spacing.sm) {
            Text("Icon")
                .nuvioText(NuvioTextStyles.cardTitle)
                .foregroundStyle(colors.textPrimary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: NuvioTheme.spacing.md) {
                    ForEach(Profile.availableSymbols, id: \.self) { candidate in
                        Button(action: { symbol = candidate }) {
                            Image(systemName: candidate)
                                .font(.system(size: NuvioTheme.sizes.icons.md))
                                .foregroundStyle(.white)
                                .frame(width: dp(64), height: dp(64))
                                .background {
                                    Circle().fill(
                                        Color(argbHex: tintHex).opacity(candidate == symbol ? 0.9 : 0.25)
                                    )
                                }
                        }
                        .buttonStyle(NuvioCardButtonStyle(cornerRadius: dp(32), showsRing: true, elevated: false))
                    }
                }
                .padding(.vertical, NuvioTheme.spacing.xs)
            }
            .scrollClipDisabled()
        }
        .padding(.horizontal, NuvioTheme.spacing.lg)
        .padding(.vertical, NuvioTheme.spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .focusSection()
    }

    private var tintPicker: some View {
        VStack(alignment: .leading, spacing: NuvioTheme.spacing.sm) {
            Text("Colour")
                .nuvioText(NuvioTextStyles.cardTitle)
                .foregroundStyle(colors.textPrimary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: NuvioTheme.spacing.md) {
                    ForEach(Profile.availableTints, id: \.self) { candidate in
                        Button(action: { tintHex = candidate }) {
                            Circle()
                                .fill(Color(argbHex: candidate))
                                .frame(width: dp(48), height: dp(48))
                                .overlay {
                                    if candidate == tintHex {
                                        Image(systemName: "checkmark")
                                            .font(.system(size: NuvioTheme.sizes.icons.xs, weight: .bold))
                                            .foregroundStyle(.black)
                                    }
                                }
                                .frame(width: dp(64), height: dp(64))
                        }
                        .buttonStyle(NuvioCardButtonStyle(cornerRadius: dp(32), showsRing: true, elevated: false))
                    }
                }
                .padding(.vertical, NuvioTheme.spacing.xs)
            }
            .scrollClipDisabled()
        }
        .padding(.horizontal, NuvioTheme.spacing.lg)
        .padding(.vertical, NuvioTheme.spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .focusSection()
    }

    private var actions: some View {
        HStack(spacing: NuvioTheme.spacing.md) {
            Button(action: save) {
                Text(isEditing ? "Save" : "Create")
                    .nuvioText(NuvioTextStyles.button)
                    .padding(.horizontal, NuvioTheme.spacing.xl)
                    .frame(height: NuvioTheme.components.buttonHeight)
            }
            .buttonStyle(NuvioPillButtonStyle(emphasis: .primary))
            .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)

            Button(action: { dismiss() }) {
                Text("Cancel")
                    .nuvioText(NuvioTextStyles.button)
                    .padding(.horizontal, NuvioTheme.spacing.xl)
                    .frame(height: NuvioTheme.components.buttonHeight)
            }
            .buttonStyle(NuvioPillButtonStyle(emphasis: .secondary))

            if isEditing, !isPrimary {
                Button(action: { isConfirmingDelete = true }) {
                    Text("Delete")
                        .nuvioText(NuvioTextStyles.button)
                        .padding(.horizontal, NuvioTheme.spacing.xl)
                        .frame(height: NuvioTheme.components.buttonHeight)
                }
                .buttonStyle(NuvioPillButtonStyle(emphasis: .ghost))
            }
        }
        .focusSection()
    }

    /// Populate from the edited profile once; re-running would stomp the viewer's typing.
    private func loadOnce() {
        guard !didLoad else { return }
        didLoad = true
        guard let profile else { return }
        name = profile.name
        symbol = profile.symbol
        tintHex = profile.tintHex
        isRestricted = profile.isRestricted
    }

    private func save() {
        let digits = pin.filter(\.isNumber)
        if var existing = profile {
            existing.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
            existing.symbol = symbol
            existing.tintHex = tintHex
            existing.isRestricted = isRestricted
            profiles.update(existing)
            // An untouched field leaves the existing PIN alone; clearing it removes the lock.
            if pin.isEmpty, existing.isLocked {
                profiles.setPin(nil, for: existing)
            } else if digits.count == 4 {
                profiles.setPin(digits, for: existing)
            }
        } else {
            profiles.add(
                name: name,
                symbol: symbol,
                tintHex: tintHex,
                pin: digits.count == 4 ? digits : nil,
                isRestricted: isRestricted
            )
        }
        dismiss()
    }
}
