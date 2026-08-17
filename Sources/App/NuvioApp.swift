import SwiftUI

@main
struct NuvioApp: App {
    @State private var profiles = ProfileStore()

    init() {
        NuvioFontRegistrar.registerIfNeeded()
    }

    var body: some Scene {
        WindowGroup {
            ProfileGate(profiles: profiles)
        }
    }
}

/// Owns the per-profile store graph. Every store below is scoped to the active profile, so a
/// switch has to rebuild all of them — `.id(activeProfileId)` does exactly that, and also
/// guarantees no view keeps a reference to the previous profile's data.
private struct ProfileGate: View {
    let profiles: ProfileStore

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
        .preferredColorScheme(.dark)
    }
}

private struct ProfileScopedRoot: View {
    @State private var settings = AppSettings()
    @State private var addons = AddonStore()
    @State private var library = LibraryStore()
    @State private var collections = CollectionStore()
    @State private var router = Router()

    var body: some View {
        RootView()
            .environment(settings)
            .environment(addons)
            .environment(library)
            .environment(collections)
            .environment(router)
            .environment(\.nuvioColors, settings.app.colors)
            .environment(\.nuvioFont, settings.app.font)
    }
}
