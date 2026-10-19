import SwiftUI

/// The watch party, from inside playback.
///
/// Separate from `PartyView` because the questions are different ones. On the settings screen a
/// viewer is deciding whether to be in a party at all; here they are already watching something,
/// so the useful actions are *start one on this*, *share this link*, and *who is behind*.
struct InPlayerPartyPanel: View {
    @Environment(PartyStore.self) private var store
    @Environment(ProfileStore.self) private var profiles
    @Environment(NuvioAccountStore.self) private var account

    let media: PartyMedia
    /// The resolved link, shared on request so everybody opens the same file.
    let stream: PartyStream
    /// Whether this device has fallen behind on purpose, and how to end that.
    var isBehind = false
    var onCatchUp: () -> Void = {}
    let onDismiss: () -> Void

    var body: some View {
        InPlayerPanel(
            title: L10n.text("party.title", fallback: "Watch party"),
            subtitle: media.title.nilIfBlank,
            handlesExit: true,
            onDismiss: onDismiss
        ) {
            if !account.isSignedIn {
                InPlayerInfoRow(
                    title: L10n.text("common.unavailable"),
                    value: PartyError.signInRequired.message
                )
            } else if !store.isAvailable {
                InPlayerInfoRow(
                    title: L10n.text("common.unavailable"),
                    value: PartyError.unavailable.message
                )
            } else if let party = store.party {
                active(party)
            } else {
                idle
            }
        }
        .task { await store.refreshAvailability(isSignedIn: account.isSignedIn) }
    }

    // MARK: Not in one

    @ViewBuilder
    private var idle: some View {
        InPlayerPanelSection(title: L10n.text("party.start", fallback: "Start a party")) {
            InPlayerPanelRow(
                title: L10n.text("party.start", fallback: "Start a party"),
                subtitle: L10n.text(
                    "party.share_warning",
                    fallback: "Everyone plays the link this device resolved, through your own debrid account."
                ),
                systemImage: "person.2.badge.plus",
                requestsInitialFocus: true,
                revealsSubtitle: true
            ) {
                Task { await store.create(media: media, identity: identity) }
            }
        }
    }

    // MARK: In one

    @ViewBuilder
    private func active(_ party: ActiveParty) -> some View {
        InPlayerPanelSection(title: L10n.format("party.code_is", fallback: "Code: %@", party.code)) {
            InPlayerInfoRow(
                title: L10n.text("party.members", fallback: "Watching"),
                value: party.isConnected
                    ? party.members.map(\.displayName).joined(separator: ", ")
                    : L10n.text("party.reconnecting", fallback: "Reconnecting…")
            )

            // Catching up is the way out of having watched on your own for a while, and it has
            // to be offered: a member who paused while the room played on has no other way back
            // to it, and seeking forward by hand would only land near the party, not on it.
            if isBehind {
                InPlayerPanelRow(
                    title: L10n.text("party.catch_up", fallback: "Catch up"),
                    systemImage: "forward.fill",
                    requestsInitialFocus: true,
                    action: onCatchUp
                )
            }

            if party.isHost {
                // A switch rather than an action, because the question is standing rather than
                // momentary — and because what it turns on routes everybody through this
                // account's debrid, which the subtitle says in as many words.
                InPlayerPanelRow(
                    title: L10n.text("party.share_my_stream", fallback: "Share my stream"),
                    subtitle: L10n.text(
                        "party.share_my_stream_sub",
                        fallback: "Friends can play your link instead of picking their own. It runs through your debrid account."
                    ),
                    systemImage: "link",
                    isSelected: party.isSharing,
                    requestsInitialFocus: !isBehind,
                    revealsSubtitle: true
                ) {
                    Task {
                        await store.setSharing(!party.isSharing)
                        if store.party?.isSharing == true { await store.share(stream: stream) }
                    }
                }
            }

            if !party.canControl {
                InPlayerInfoRow(
                    title: L10n.text("party.host_only", fallback: "Only I control playback"),
                    value: L10n.text(
                        "party.host_only_note", fallback: "Only the host can control playback"
                    )
                )
            }

            if party.isHost {
                InPlayerPanelRow(
                    title: party.hostOnly
                        ? L10n.text("party.everyone_controls", fallback: "Let everyone control")
                        : L10n.text("party.host_only", fallback: "Only I control playback"),
                    systemImage: party.hostOnly
                        ? "person.2"
                        : "person.badge.shield.checkmark",
                    isSelected: party.hostOnly
                ) {
                    Task { await store.setHostOnly(!party.hostOnly) }
                }

                InPlayerPanelRow(
                    title: L10n.text("party.end", fallback: "End party"),
                    systemImage: "xmark"
                ) {
                    Task { await store.end() }
                    onDismiss()
                }
            } else {
                InPlayerPanelRow(
                    title: L10n.text("party.leave", fallback: "Leave party"),
                    systemImage: "rectangle.portrait.and.arrow.right"
                ) {
                    Task { await store.leave() }
                    onDismiss()
                }
            }
        }
    }

    private var identity: PartyIdentity {
        let profile = profiles.activeProfile
        return PartyIdentity(
            deviceId: PartyDevice.id,
            displayName: profile?.name.nilIfBlank
                ?? L10n.text("party.someone", fallback: "Someone"),
            avatarUrl: profile?.avatarUrl,
            avatarColor: profile?.tintHex
        )
    }
}
