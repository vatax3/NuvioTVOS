#if DEBUG
import Foundation

/// Stages a watch party with nothing behind it.
///
/// The party screens are the least reachable surface in the app: they need a signed-in account, a
/// live backend with the feature switched on, and a *second device* on the other end. So the two
/// questions this harness exists to answer have been answered by hand, on a television, by the
/// person who reported them — twice:
///
/// - does the player's panel take the remote, and can it be left;
/// - and what happens when a host ends a party from the roster, which has been reported as a
///   crash and has no stack trace this side of the room.
///
/// Both are runtime facts about focus, view identity and teardown ordering. No policy test can
/// see either, which is the same reasoning that put `PlayerHarness` and `LibraryHarness` in the
/// tree. Compiled out of release builds; inert without the launch argument.
enum PartyHarness {
    static let launchArgument = "-nuvioPartyHarness"
    /// Set `NUVIO_HARNESS_PARTY_GUEST` to stage the party as somebody else's, which is a
    /// different screen: no host controls, a *leave* rather than an *end*, and the host-only
    /// restriction actually applying.
    static let guestVariable = "NUVIO_HARNESS_PARTY_GUEST"
    /// Set `NUVIO_HARNESS_PARTY_HOST_ONLY` to stage it with the host's restriction on.
    static let hostOnlyVariable = "NUVIO_HARNESS_PARTY_HOST_ONLY"

    /// Set `NUVIO_HARNESS_PARTY_PANEL` to open the player's party panel with playback.
    ///
    /// Same reasoning as the staged episodes panel: walking the transport to find the control is
    /// incidental to the question, and it is also the fragile part — `hasFocus` on those buttons
    /// is an unreliable witness. Put the subject on screen and test the subject.
    static var opensPanel: Bool {
        isActive && flag("NUVIO_HARNESS_PARTY_PANEL")
    }

    static var isActive: Bool {
        ProcessInfo.processInfo.arguments.contains(launchArgument)
    }

    private static func flag(_ name: String) -> Bool {
        ProcessInfo.processInfo.environment[name]?.nilIfBlank != nil
    }

    static let selfMemberId = "harness-me"
    static let otherMemberId = "harness-them"

    /// The staged party, or nil when the harness is off.
    ///
    /// Read from `PartyStore`'s own initialiser rather than seeded from a view's `task`: the
    /// settings rail decides which sections exist the first time it is laid out, and a party
    /// that arrives a moment later has already missed that decision.
    @MainActor
    static func staged() -> ActiveParty? {
        guard isActive else { return nil }
        let isGuest = flag(guestVariable)
        return ActiveParty(
                id: "harness-party",
                code: "8JNMYZ",
                memberId: selfMemberId,
                hostMemberId: isGuest ? otherMemberId : selfMemberId,
                members: [
                    PartyMember(id: selfMemberId, displayName: "Val"),
                    PartyMember(id: otherMemberId, displayName: "Orane")
                ],
                presence: [
                    otherMemberId: PartyPresence(memberId: otherMemberId, status: .ready)
                ],
                media: PartyMedia(
                    type: "movie",
                    metaId: "harness",
                    metaType: "movie",
                    videoId: "harness",
                    title: "Harness"
                ),
                maxMembers: 8,
                isConnected: true,
                hostOnly: flag(hostOnlyVariable)
            )
    }
}
#endif
