import Foundation

/// Which tracking account a preference points at, and what happens when it points at one the
/// viewer never connected.
///
/// Port of upstream's `TrackingSources.kt`. The rule it encodes is the reason this file exists:
/// a source preference is a *request*, not a fact. Choosing Trakt and then signing out — or
/// having the preference arrive from another device through account sync — must fall back to the
/// local data rather than render an empty screen, which is what happened here before.
enum TrackingProviderId: String, Hashable, Sendable, CaseIterable {
    case trakt
    case simkl
}

extension WatchProgressSource {
    /// `nil` for the local case: there is no provider to be authenticated against.
    var providerId: TrackingProviderId? {
        switch self {
        case .local: return nil
        case .trakt: return .trakt
        case .simkl: return .simkl
        }
    }
}

extension LibrarySourceMode {
    var providerId: TrackingProviderId? {
        switch self {
        case .local: return nil
        case .trakt: return .trakt
        case .simkl: return .simkl
        }
    }
}

enum TrackingSources {
    static func effectiveWatchProgressSource(
        _ requested: WatchProgressSource,
        connected: Set<TrackingProviderId>
    ) -> WatchProgressSource {
        guard let provider = requested.providerId else { return .local }
        return connected.contains(provider) ? requested : .local
    }

    static func effectiveLibrarySourceMode(
        _ requested: LibrarySourceMode,
        connected: Set<TrackingProviderId>
    ) -> LibrarySourceMode {
        guard let provider = requested.providerId else { return .local }
        return connected.contains(provider) ? requested : .local
    }

    /// What the picker should offer. Listing a provider the viewer has not signed into would be
    /// offering a choice that silently does nothing.
    static func availableWatchProgressSources(
        connected: Set<TrackingProviderId>
    ) -> [WatchProgressSource] {
        var out: [WatchProgressSource] = [.local]
        if connected.contains(.trakt) { out.append(.trakt) }
        if connected.contains(.simkl) { out.append(.simkl) }
        return out
    }

    static func availableLibrarySourceModes(
        connected: Set<TrackingProviderId>
    ) -> [LibrarySourceMode] {
        var out: [LibrarySourceMode] = [.local]
        if connected.contains(.trakt) { out.append(.trakt) }
        if connected.contains(.simkl) { out.append(.simkl) }
        return out
    }
}
