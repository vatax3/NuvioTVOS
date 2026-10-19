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
    @Environment(Router.self) private var router

    /// What this device would share if it started a party here. Absent from Settings, where
    /// nothing is playing — then the screen can only join.
    var media: PartyMedia?
    var onDismiss: (() -> Void)?

    @State private var code = ""
    @State private var preview: PartyPreview?

    var body: some View {
        VStack(alignment: .leading, spacing: NuvioTheme.spacing.xl) {
            header

            // The party we are in outranks both notices. A session that lapses mid-party would
            // otherwise replace the roster with "sign in" and take away the only way out of it.
            if let active = party.party {
                PartyRoster(party: active, onWatch: watchWithParty, onFinished: leaveScreen)
            } else if !account.isSignedIn {
                notice(PartyError.signInRequired.message)
            } else if !party.isAvailable {
                notice(PartyError.unavailable.message)
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
        // Only when there is something to call. `onExitCommand` **consumes** the Menu press
        // whether or not its closure does anything, so attaching it unconditionally left the
        // pushed screen with no way out at all — the navigation stack never saw the press.
        .modifier(OptionalExitCommand(action: onDismiss))
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: NuvioTheme.spacing.xs) {
            Text(L10n.text("party.title", fallback: "Watch party"))
                .nuvioText(NuvioTypography.headlineLarge)
                .foregroundStyle(colors.textPrimary)
            Text(L10n.text(
                "party.subtitle",
                fallback: "Everyone plays from their own sources and stays in step."
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
                Button(action: { Task { await joinAndWatch() } }) {
                    rowLabel(
                        L10n.text("party.join", fallback: "Join"), systemImage: "person.badge.plus"
                    )
                }
                .buttonStyle(NuvioPillButtonStyle(emphasis: .primary))
                .disabled(party.isBusy)
            }
        }
    }

    // MARK: Getting to the film

    /// Joins, then takes the viewer to the party's title.
    ///
    /// The second half is the part 1.0.48 was missing altogether: a member who joined landed on
    /// a roster with nothing to press, and `sharedStream` is only read by the player — a screen
    /// they were not on. So the party was joined, correct, and could never start.
    ///
    /// The pause is upstream's and is worth keeping: the roster appears, the viewer sees *who*
    /// they have joined, and only then does the screen move.
    private func joinAndWatch() async {
        await party.join(code: code, identity: identity)
        guard let joined = party.party else { return }
        try? await Task.sleep(for: .milliseconds(1600))
        guard party.party?.id == joined.id else { return }
        watchWithParty(joined.media)
    }

    /// Ending or leaving is the end of this screen's business, so it closes.
    ///
    /// Not cosmetic. Left mounted, the content swaps underneath the button that is still holding
    /// focus — and what replaces it, with nothing playing to start a party from, is a text field
    /// as the only focusable view on screen. Destroying a focused control and pushing the remote
    /// into a text field in the same frame is the kind of thing tvOS is entitled to be unhappy
    /// about, and ending a party reported as a crash is what prompted looking at it. Going back
    /// is also simply what a viewer expects: the party is over, so is the screen.
    private func leaveScreen() {
        if let onDismiss {
            onDismiss()
        } else {
            router.pop()
        }
    }

    /// Opens the stream list for what the party is watching.
    ///
    /// The source list rather than straight into playback, because everybody picks their own:
    /// the host's link is offered at the top of it when they shared one, and the release the
    /// host is on is marked. Upstream's `openPartyMedia` does the same.
    private func watchWithParty(_ media: PartyMedia) {
        router.push(.streams(media.streamRequest))
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

extension PartyMedia {
    /// What the party is watching, in the terms the stream list asks for.
    ///
    /// `videoId` falls back to the meta id: a film has no separate video, and a party started on
    /// one carries only the one identifier.
    var streamRequest: StreamRequest {
        StreamRequest(
            videoId: videoId?.nilIfBlank ?? metaId,
            contentType: metaType,
            title: title,
            contentId: metaId,
            contentName: title,
            poster: poster,
            backdrop: background,
            logo: logo,
            season: season,
            episode: episode,
            episodeName: episodeTitle
        )
    }
}

/// Installs a Menu handler only when there is one, which is not the same as installing one that
/// does nothing.
///
/// `InPlayerPanel` carries the same modifier and the same note, learned the same way: a handler
/// that returns early still swallows the press. Pushed onto the navigation stack with no
/// `onDismiss`, this screen could not be left at all.
private struct OptionalExitCommand: ViewModifier {
    let action: (() -> Void)?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let action {
            content.onExitCommand(perform: action)
        } else {
            content
        }
    }
}

/// Who is in the party, and what the host can do about it.
struct PartyRoster: View {
    @Environment(\.nuvioColors) private var colors
    @Environment(PartyStore.self) private var store

    let party: ActiveParty
    /// Opens what the party is watching. The primary action here: a roster you cannot act on is
    /// a dead end, which is what the first version of this screen was.
    let onWatch: (PartyMedia) -> Void
    /// Called once this device is out of the party, by either route.
    let onFinished: () -> Void

    @FocusState private var watchFocused: Bool

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
        VStack(alignment: .leading, spacing: NuvioTheme.spacing.md) {
            Button(action: { onWatch(party.media) }) {
                label(
                    L10n.text("party.watch_with_party", fallback: "Watch with the party"),
                    systemImage: "play.fill"
                )
            }
            .buttonStyle(NuvioPillButtonStyle(emphasis: .primary))
            .accessibilityIdentifier("party.roster.watch")
            // A deliberate landing point. Without one the remote arrives on whatever the focus
            // engine picks — here, the button that removes a member from the party.
            .focused($watchFocused)
            .onAppear { Task { @MainActor in watchFocused = true } }

            secondaryControls
        }
    }

    @ViewBuilder
    private var secondaryControls: some View {
        HStack(spacing: NuvioTheme.spacing.md) {
            if party.isHost {
                Button(action: { Task { await store.setSharing(!party.isSharing) } }) {
                    label(
                        L10n.text("party.share_my_stream", fallback: "Share my stream"),
                        systemImage: party.isSharing ? "link" : "link.badge.plus"
                    )
                }
                .buttonStyle(NuvioPillButtonStyle(emphasis: .secondary, selected: party.isSharing))
                .accessibilityIdentifier("party.roster.sharing")

                // One title, switched on or off. It used to flip the *title* to the action it
                // would perform while the highlight showed the *state*, so a host who had turned
                // the restriction on saw a lit button reading "Let everyone control" — which says
                // the opposite of what was true.
                Button(action: { Task { await store.setHostOnly(!party.hostOnly) } }) {
                    label(
                        L10n.text("party.host_only", fallback: "Only I control playback"),
                        systemImage: party.hostOnly
                            ? "person.badge.shield.checkmark" : "person.2"
                    )
                }
                .buttonStyle(NuvioPillButtonStyle(emphasis: .secondary, selected: party.hostOnly))
                .accessibilityIdentifier("party.roster.hostOnly")

                Button(action: { Task { await store.end(); onFinished() } }) {
                    label(L10n.text("party.end", fallback: "End party"), systemImage: "xmark")
                }
                .buttonStyle(NuvioPillButtonStyle(emphasis: .secondary))
                .accessibilityIdentifier("party.roster.end")
            } else {
                Button(action: { Task { await store.leave(); onFinished() } }) {
                    label(
                        L10n.text("party.leave", fallback: "Leave party"),
                        systemImage: "rectangle.portrait.and.arrow.right"
                    )
                }
                .buttonStyle(NuvioPillButtonStyle(emphasis: .secondary))
                .accessibilityIdentifier("party.roster.leave")
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
