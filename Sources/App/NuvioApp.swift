import SwiftUI

@main
struct NuvioApp: App {
    @State private var profiles = ProfileStore()
    /// Account and sync are device-wide, not per-profile: one signed-in account owns every
    /// profile's rows, and switching profiles must not drop the session.
    @State private var account = NuvioAccountStore()
    @State private var sync = NuvioSyncService()

    init() {
        NuvioFontRegistrar.registerIfNeeded()
    }

    var body: some Scene {
        WindowGroup {
            ProfileGate(profiles: profiles, account: account, sync: sync)
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

    var body: some View {
        Group {
            if profiles.isLocked, let profile = profiles.activeProfile {
                ProfileLockView(profile: profile, profiles: profiles)
            } else {
                ProfileScopedRoot()
                    .id(profiles.activeProfileId)
            }
        }
        .environment(profiles)
        .environment(account)
        .environment(sync)
        .preferredColorScheme(.dark)
    }
}

private struct ProfileScopedRoot: View {
    @State private var settings = AppSettings()
    @State private var addons = AddonStore()
    @State private var library = LibraryStore()
    @State private var collections = CollectionStore()
    @State private var plugins = PluginStore()
    @State private var router = Router()

    var body: some View {
        RootView()
            .environment(settings)
            .environment(addons)
            .environment(library)
            .environment(collections)
            .environment(plugins)
            .environment(router)
            .environment(\.nuvioColors, settings.app.colors)
            .environment(\.nuvioFont, settings.app.font)
    }
}
