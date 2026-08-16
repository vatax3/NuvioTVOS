import SwiftUI

@main
struct NuvioApp: App {
    @State private var settings = SettingsStore()
    @State private var addons = AddonStore()
    @State private var library = LibraryStore()
    @State private var router = Router()

    init() {
        NuvioFontRegistrar.registerIfNeeded()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(settings)
                .environment(addons)
                .environment(library)
                .environment(router)
                .environment(\.nuvioColors, settings.colors)
                .environment(\.nuvioFont, settings.font)
                .preferredColorScheme(.dark)
        }
    }
}
