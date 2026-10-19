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
            focusCloseOnAppear: store.party == nil && !account.isSignedIn,
            handlesExit: true,
            onDismiss: onDismiss
        ) {
            // The party we are in outranks both notices, for the same reason the settings screen
            // orders them this way: a lapsed session must not take away the way out of a party.
            if let party = store.party {
                active(party)
            } else if !account.isSignedIn {
                unavailable(PartyError.signInRequired.message)
            } else if !store.isAvailable {
                unavailable(PartyError.unavailable.message)
            } else {
                idle
            }
        }
        .task { await store.refreshAvailability(isSignedIn: account.isSignedIn) }
    }

    /// A panel with nothing to press in it still has to be readable and leavable, so the close
    /// control is where focus lands.
    @ViewBuilder
    private func unavailable(_ message: String) -> some View {
        InPlayerInfoRow(title: L10n.text("common.unavailable"), value: message)
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
                revealsSubtitle: true,
                identifier: "party.panel.start"
            ) {
                Task { await store.create(media: media, identity: identity) }
            }
        }
    }

    // MARK: In one

    /// The rows are deliberately **not** conditional on anything that changes while the panel is
    /// open.
    ///
    /// `InPlayerPanel` stacks its content positionally, so a row that appears or disappears
    /// re-identifies every row below it — and the status line here updates several times a second
    /// while somebody is buffering. Focus jumping out from under the remote mid-press is what
    /// that looks like to a viewer. So the host's controls and the guest's note sit in fixed
    /// places and change their *state*, never their presence; only *Catch up*, which exists for
    /// a condition the viewer deliberately created, is allowed to come and go — and it is first,
    /// so nothing below it can be re-identified by its arrival.
    @ViewBuilder
    private func active(_ party: ActiveParty) -> some View {
        InPlayerPanelSection(title: L10n.format("party.code_is", fallback: "Code: %@", party.code)) {
            if isBehind {
                InPlayerPanelRow(
                    title: L10n.text("party.catch_up", fallback: "Catch up"),
                    subtitle: L10n.text(
                        "party.watching_alone",
                        fallback: "Watching on your own — catch up when you like"
                    ),
                    systemImage: "forward.fill",
                    requestsInitialFocus: true,
                    identifier: "party.panel.catchUp",
                    action: onCatchUp
                )
            }

            InPlayerInfoRow(
                title: L10n.text("party.members", fallback: "Watching"),
                value: party.isConnected
                    ? party.members.map(\.displayName).joined(separator: ", ")
                    : L10n.text("party.reconnecting", fallback: "Reconnecting…")
            )

            if party.isHost {
                // A switch: one title, on or off. What it turns on routes everybody through this
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
                    revealsSubtitle: true,
                    identifier: "party.panel.sharing"
                ) {
                    Task {
                        await store.setSharing(!party.isSharing)
                        if store.party?.isSharing == true { await store.share(stream: stream) }
                    }
                }

                InPlayerPanelRow(
                    title: L10n.text("party.host_only", fallback: "Only I control playback"),
                    systemImage: party.hostOnly
                        ? "person.badge.shield.checkmark" : "person.2",
                    isSelected: party.hostOnly,
                    identifier: "party.panel.hostOnly"
                ) {
                    Task { await store.setHostOnly(!party.hostOnly) }
                }

                InPlayerPanelRow(
                    title: L10n.text("party.end", fallback: "End party"),
                    systemImage: "xmark",
                    identifier: "party.panel.end"
                ) {
                    Task { await store.end() }
                    onDismiss()
                }
            } else {
                // Shown to a guest whatever the setting is, so the row count does not change
                // under the remote when the host flips it. The value is the state.
                InPlayerInfoRow(
                    title: L10n.text("party.playback", fallback: "Playback"),
                    value: party.canControl
                        ? L10n.text("party.everyone_controls", fallback: "Let everyone control")
                        : L10n.text(
                            "party.host_only_note", fallback: "Only the host can control playback"
                        )
                )

                InPlayerPanelRow(
                    title: L10n.text("party.leave", fallback: "Leave party"),
                    systemImage: "rectangle.portrait.and.arrow.right",
                    requestsInitialFocus: !isBehind,
                    identifier: "party.panel.leave"
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
