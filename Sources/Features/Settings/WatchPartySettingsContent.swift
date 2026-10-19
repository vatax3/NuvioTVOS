import SwiftUI

/// The Watch party entry in Settings.
///
/// Deliberately thin: the section exists so the feature is *where someone would look for it*
/// rather than filed under Content & discovery, which is where 1.0.48 put it. Everything a
/// viewer actually does — the code, the roster, the host's controls — is on `PartyView`, one
/// press away.
struct WatchPartySettingsContent: View {
    @Environment(PartyStore.self) private var party
    @Environment(NuvioAccountStore.self) private var account
    @Environment(Router.self) private var router

    var body: some View {
        VStack(alignment: .leading, spacing: NuvioTheme.components.settings.rowGap) {
            SettingsCard(
                title: L10n.text("party.title", fallback: "Watch party"),
                footnote: L10n.text(
                    "party.settings_description", fallback: "Join friends with a party code."
                )
            ) {
                if let active = party.party {
                    SettingsRow(
                        title: active.media.title.nilIfBlank
                            ?? L10n.text("party.unknown_title", fallback: "A party"),
                        subtitle: L10n.format(
                            "party.seats", fallback: "%@ of %@ seats",
                            String(active.members.count), String(active.maxMembers)
                        ),
                        systemImage: "person.2.wave.2.fill",
                        trailing: { SettingsValueLabel(value: active.code) },
                        action: { router.push(.watchParty) }
                    )
                } else {
                    SettingsRow(
                        title: L10n.text("party.join_title", fallback: "Join a watch party"),
                        subtitle: account.isSignedIn
                            ? L10n.text(
                                "party.join_description",
                                fallback: "Enter the six-character code a friend shared."
                            )
                            : PartyError.signInRequired.message,
                        systemImage: "person.2.wave.2.fill",
                        trailing: { SettingsValueLabel(value: "") },
                        action: { router.push(.watchParty) }
                    )
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task { await party.refreshAvailability(isSignedIn: account.isSignedIn) }
    }
}
