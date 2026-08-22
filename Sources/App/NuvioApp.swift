import SwiftUI

@main
struct NuvioApp: App {
    @State private var profiles = ProfileStore()
    /// Account and sync are device-wide, not per-profile: one signed-in account owns every
    /// profile's rows, and switching profiles must not drop the session.
    @State private var account = NuvioAccountStore()
    @State private var sync = NuvioSyncService()
    /// Profile pictures are account-wide, like the account itself.
    @State private var avatars = AvatarCatalog()

    init() {
        NuvioFontRegistrar.registerIfNeeded()
    }

    var body: some Scene {
        WindowGroup {
            ProfileGate(profiles: profiles, account: account, sync: sync, avatars: avatars)
        }
    }
}

/// Owns the per-profile store graph. Every store below is scoped to the active profile, so a
/// switch has to rebuild all of them — `.id(activeProfileId)` does exactly that, and also
/// guarantees no view keeps a reference to the previous profile's data.
private struct ProfileGate: View {
    let profiles: ProfileStore
    let account: NuvioAccountStore
    let sync: NuvioSyncService
    let avatars: AvatarCatalog

    var body: some View {
        Group {
            // "Who's watching?" comes before everything else, exactly as on Android: a
            // household picks who they are, and only then does the app — and its per-profile
            // store graph — come up.
            if profiles.shouldPresentSelection {
                ProfileSelectionView(profiles: profiles)
                    .environment(\.nuvioColors, NuvioColorScheme(palette: ThemeColors.crimson))
            } else if profiles.isLocked, let profile = profiles.activeProfile {
                ProfileLockView(profile: profile, profiles: profiles)
            } else {
                ProfileScopedRoot()
                    .id("\(profiles.activeProfileId)#\(profiles.resetToken)")
            }
        }
        .environment(profiles)
        .environment(account)
        .environment(sync)
        .environment(avatars)
        .preferredColorScheme(.dark)
        .task { avatars.loadIfNeeded(configuration: account.configuration) }
        // On a first-run QR sign-in the initial task ran before a server configuration existed.
        // Reloading here is what makes the Android/iOS avatar photographs appear in the very
        // next profile chooser instead of leaving the household with generic symbols.
        .onChange(of: account.isSignedIn) { _, signedIn in
            guard signedIn else { return }
            avatars.loadIfNeeded(configuration: account.configuration)
        }
    }
}

private struct ProfileScopedRoot: View {
    @State private var settings = AppSettings()
    @State private var addons = AddonStore()
    @State private var library = LibraryStore()
    @State private var collections = CollectionStore()
    @State private var plugins = PluginStore()
    @State private var router = Router()
    @State private var remoteProgress = RemoteProgressService()

    var body: some View {
        RootView()
            .environment(settings)
            .environment(addons)
            .environment(library)
            .environment(collections)
            .environment(plugins)
            .environment(router)
            .environment(remoteProgress)
            .environment(\.nuvioColors, settings.app.colors)
            .environment(\.nuvioFont, settings.app.font)
    }
}
