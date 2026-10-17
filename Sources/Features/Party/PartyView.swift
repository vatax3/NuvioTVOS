import SwiftUI

/// Starting or joining a watch party.
///
/// Reached from Settings while nothing is playing, and from the player's own panel while
/// something is. Three states and no more: not in one, looking one up, in one.
struct PartyView: View {
    @Environment(\.nuvioColors) private var colors
    @Environment(PartyStore.self) private var party
    @Environment(ProfileStore.self) private var profiles
    @Environment(NuvioAccountStore.self) private var account

    /// What this device would share if it started a party here. Absent from Settings, where
    /// nothing is playing — then the screen can only join.
    var media: PartyMedia?
    var onDismiss: (() -> Void)?

    @State private var code = ""
    @State private var preview: PartyPreview?

    var body: some View {
        VStack(alignment: .leading, spacing: NuvioTheme.spacing.xl) {
            header

            if !account.isSignedIn {
                notice(PartyError.signInRequired.message)
            } else if !party.isAvailable {
                notice(PartyError.unavailable.message)
            } else if let active = party.party {
                PartyRoster(party: active)
            } else {
                joining
            }

            if let error = party.error {
                notice(error.message)
            }
        }
        .padding(NuvioTheme.spacing.xxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task { await party.refreshAvailability(isSignedIn: account.isSignedIn) }
        .onExitCommand { onDismiss?() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: NuvioTheme.spacing.xs) {
            Text(L10n.text("party.title", fallback: "Watch together"))
                .nuvioText(NuvioTypography.headlineLarge)
                .foregroundStyle(colors.textPrimary)
            Text(L10n.text(
                "party.subtitle",
                fallback: "Play in step with other people, each on their own television."
            ))
            .nuvioText(NuvioTextStyles.metadata)
            .foregroundStyle(colors.textSecondary)
        }
    }

    // MARK: Not in one yet

    @ViewBuilder
    private var joining: some View {
        VStack(alignment: .leading, spacing: NuvioTheme.spacing.lg) {
            if let media {
                Button(action: { Task { await party.create(media: media, identity: identity) } }) {
                    rowLabel(
                        L10n.text("party.start", fallback: "Start a party"),
                        systemImage: "person.2.badge.plus"
                    )
                }
                .buttonStyle(NuvioPillButtonStyle(emphasis: .primary))
                .disabled(party.isBusy)

                // The one thing a viewer should be told rather than discover: the link that
                // reaches the others is this device's own resolved stream, which for a debrid
                // setup is tied to this account.
                notice(L10n.text(
                    "party.share_warning",
                    fallback: "Everyone plays the link this device resolved, through your own debrid account."
                ))
            }

            VStack(alignment: .leading, spacing: NuvioTheme.spacing.sm) {
                Text(L10n.text("party.join_with_code", fallback: "Join with a code"))
                    .nuvioText(NuvioTextStyles.sectionTitle)
                    .foregroundStyle(colors.textPrimary)

                TextField(
                    L10n.text("party.code_placeholder", fallback: "Party code"), text: $code
                )
                .autocorrectionDisabled()
                .frame(maxWidth: dp(360))
                .onChange(of: code) { _, value in
                    let cleaned = PartyStore.normalise(value)
                    if cleaned != value { code = cleaned }
                    preview = nil
                }

                if let preview {
                    previewRow(preview)
                } else if code.count >= 4 {
                    Button(action: {
                        Task { preview = await party.preview(code: code) }
                    }) {
                        rowLabel(
                            L10n.text("party.look_up", fallback: "Look it up"),
                            systemImage: "magnifyingglass"
                        )
                    }
                    .buttonStyle(NuvioPillButtonStyle(emphasis: .secondary))
                }
            }
        }
    }

    /// What the code points at, so nobody joins blind.
    @ViewBuilder
    private func previewRow(_ preview: PartyPreview) -> some View {
        VStack(alignment: .leading, spacing: NuvioTheme.spacing.xs) {
            Text(preview.media?.title.nilIfBlank ?? L10n.text("party.unknown_title", fallback: "A party"))
                .nuvioText(NuvioTextStyles.cardTitle)
                .foregroundStyle(colors.textPrimary)
            Text(L10n.format(
                "party.member_count", fallback: "%@ of %@ watching",
                String(preview.members), String(max(preview.maxMembers, preview.members))
            ))
            .nuvioText(NuvioTextStyles.metadata)
            .foregroundStyle(colors.textSecondary)

            if preview.isFull {
                notice(PartyError.full.message)
            } else {
                Button(action: { Task { await party.join(code: code, identity: identity) } }) {
                    rowLabel(
                        L10n.text("party.join", fallback: "Join"), systemImage: "person.badge.plus"
                    )
                }
                .buttonStyle(NuvioPillButtonStyle(emphasis: .primary))
                .disabled(party.isBusy)
            }
        }
    }

    // MARK: Plumbing

    /// The profile's own name and avatar, so a party shows the household's names rather than
    /// device identifiers.
    private var identity: PartyIdentity {
        let profile = profiles.activeProfile
        return PartyIdentity(
            deviceId: PartyDevice.id,
            displayName: profile?.name.nilIfBlank ?? L10n.text("party.someone", fallback: "Someone"),
            avatarUrl: profile?.avatarUrl,
            avatarColor: profile?.tintHex
        )
    }

    private func rowLabel(_ title: String, systemImage: String) -> some View {
        HStack(spacing: NuvioTheme.spacing.sm) {
            Image(systemName: systemImage)
            Text(title)
        }
        .nuvioText(NuvioTextStyles.button)
        .padding(.horizontal, NuvioTheme.spacing.xl)
        .frame(height: NuvioTheme.components.buttonHeight)
    }

    private func notice(_ message: String) -> some View {
        Text(message)
            .nuvioText(NuvioTypography.bodySmall)
            .foregroundStyle(colors.textSecondary)
            .frame(maxWidth: dp(520), alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Who is in the party, and what the host can do about it.
struct PartyRoster: View {
    @Environment(\.nuvioColors) private var colors
    @Environment(PartyStore.self) private var store

    let party: ActiveParty

    var body: some View {
        VStack(alignment: .leading, spacing: NuvioTheme.spacing.lg) {
            VStack(alignment: .leading, spacing: NuvioTheme.spacing.xxs) {
                Text(L10n.format("party.code_is", fallback: "Code: %@", party.code))
                    .nuvioText(NuvioTypography.headlineLarge)
                    .foregroundStyle(colors.textPrimary)
                    .monospaced()
                Text(connectionLabel)
                    .nuvioText(NuvioTextStyles.metadata)
                    .foregroundStyle(colors.textSecondary)
            }

            VStack(alignment: .leading, spacing: NuvioTheme.spacing.xs) {
                ForEach(party.members) { member in
                    memberRow(member)
                }
            }

            controls
        }
    }

    @ViewBuilder
    private var controls: some View {
        HStack(spacing: NuvioTheme.spacing.md) {
            if party.isHost {
                Button(action: { Task { await store.setHostOnly(!party.hostOnly) } }) {
                    label(
                        party.hostOnly
                            ? L10n.text("party.everyone_controls", fallback: "Let everyone control")
                            : L10n.text("party.host_only", fallback: "Only I control playback"),
                        systemImage: party.hostOnly ? "person.2" : "person.badge.shield.checkmark"
                    )
                }
                .buttonStyle(NuvioPillButtonStyle(emphasis: .secondary, selected: party.hostOnly))

                Button(action: { Task { await store.end() } }) {
                    label(L10n.text("party.end", fallback: "End party"), systemImage: "xmark")
                }
                .buttonStyle(NuvioPillButtonStyle(emphasis: .secondary))
            } else {
                Button(action: { Task { await store.leave() } }) {
                    label(
                        L10n.text("party.leave", fallback: "Leave party"),
                        systemImage: "rectangle.portrait.and.arrow.right"
                    )
                }
                .buttonStyle(NuvioPillButtonStyle(emphasis: .secondary))
            }
        }
    }

    /// Said out loud, because a party that looks joined and is not is the worst state to be in
    /// silently: the roster is right and nothing moves.
    private var connectionLabel: String {
        party.isConnected
            ? L10n.format(
                "party.member_count", fallback: "%@ of %@ watching",
                String(party.members.count), String(party.maxMembers)
            )
            : L10n.text("party.reconnecting", fallback: "Reconnecting…")
    }

    private func memberRow(_ member: PartyMember) -> some View {
        HStack(spacing: NuvioTheme.spacing.md) {
            Image(systemName: member.id == party.hostMemberId ? "star.fill" : "person.fill")
                .frame(width: dp(22))
                .foregroundStyle(
                    member.id == party.hostMemberId ? colors.secondary : colors.textSecondary
                )
            Text(member.displayName)
                .nuvioText(NuvioTextStyles.button)
                .foregroundStyle(colors.textPrimary)
            if let status = statusLabel(for: member) {
                Text(status)
                    .nuvioText(NuvioTextStyles.metadata)
                    .foregroundStyle(colors.textSecondary)
            }
            Spacer(minLength: 0)
            if party.isHost, member.id != party.memberId {
                Button(action: { Task { await store.remove(memberId: member.id) } }) {
                    Image(systemName: "minus.circle")
                        .padding(NuvioTheme.spacing.sm)
                }
                .buttonStyle(NuvioRowButtonStyle(cornerRadius: NuvioTheme.radii.md))
            }
        }
        .frame(maxWidth: dp(520), alignment: .leading)
    }

    private func statusLabel(for member: PartyMember) -> String? {
        switch party.presence[member.id]?.status {
        case .buffering, .loading:
            return L10n.text("party.status_buffering", fallback: "buffering")
        case .behind:
            return L10n.text("party.status_behind", fallback: "behind")
        case .browsing:
            return L10n.text("party.status_browsing", fallback: "browsing")
        case .ready, .none:
            return nil
        }
    }

    private func label(_ title: String, systemImage: String) -> some View {
        HStack(spacing: NuvioTheme.spacing.sm) {
            Image(systemName: systemImage)
            Text(title)
        }
        .nuvioText(NuvioTextStyles.button)
        .padding(.horizontal, NuvioTheme.spacing.xl)
        .frame(height: NuvioTheme.components.buttonHeight)
    }
}
