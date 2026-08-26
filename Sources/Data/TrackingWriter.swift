import Foundation
import os

/// Where a library or watched write goes.
///
/// The complement of [`TrackingSources`](TrackingSources.swift), which decides where a *read*
/// comes from. Until this existed only reads were routed, and the asymmetry was not cosmetic:
/// `LibraryView` shows Trakt's list and nothing else when the library source is Trakt, while the
/// detail screen's Add button wrote to `LibraryStore`. So a viewer on Trakt pressed Add and
/// watched the title vanish — written locally, read from a list it was never sent to.
///
/// The rule, chosen deliberately: **the local store is always written, and the remote provider is
/// written in addition.** The local copy is what survives a flight-mode launch and an expired
/// token, and it is the only record if the remote write fails. Writing only where the read comes
/// from would leave nothing at all behind a failed request.
enum TrackingWrites {
    /// The provider a write should also reach, or `nil` when the write is local only.
    ///
    /// A source pointing at an account nobody signed into resolves to local, exactly as reads do
    /// — the preference is a request, not a fact.
    static func remoteDestination(
        librarySource requested: LibrarySourceMode,
        connected: Set<TrackingProviderId>
    ) -> TrackingProviderId? {
        TrackingSources.effectiveLibrarySourceMode(requested, connected: connected).providerId
    }

    /// What the viewer is told. A write that reached the device but not the account is the case
    /// worth naming: it is not a failure — the title is saved — but it is not what they asked
    /// for either, and silence is how the original bug hid.
    enum Result: Equatable, Sendable {
        case local
        case synced(TrackingProviderId)
        case remoteFailed(TrackingProviderId, reason: String)

        var isRemoteFailure: Bool {
            if case .remoteFailed = self { return true }
            return false
        }
    }
}

/// Performs the write decided by `TrackingWrites`.
///
/// Deliberately not part of `LibraryStore`: that store is a pure local model with no network and
/// no credentials, and the sync tests depend on it staying that way.
@MainActor
@Observable
final class TrackingWriteService {
    /// The outcome of the most recent write, for the UI to surface. Cleared when the viewer
    /// leaves the screen or starts another write.
    private(set) var lastResult: TrackingWrites.Result?

    @ObservationIgnored private let log = Logger(subsystem: "com.nuvio.tvos", category: "TrackingWrite")

    func clear() { lastResult = nil }

    /// Adding or removing a title from the viewer's library.
    ///
    /// `added` is the state the local store has already moved to, so this reports rather than
    /// decides: the local write is immediate and never waits on the network.
    func library(
        _ preview: MetaPreview,
        added: Bool,
        settings: AppSettings
    ) async {
        guard let provider = TrackingWrites.remoteDestination(
            librarySource: settings.tracking.librarySourceMode,
            connected: settings.connectedTrackingProviders
        ) else {
            lastResult = .local
            return
        }
        lastResult = await perform(provider: provider, settings: settings) {
            switch provider {
            case .trakt:
                guard let imdb = preview.imdbId else { throw TrackingWriteError.noUsableId }
                let outcome = try await TraktClient.shared.write(
                    .watchlist,
                    removing: !added,
                    imdbId: imdb,
                    type: preview.type,
                    clientId: settings.tracking.traktClientId,
                    token: settings.tracking.traktAccessToken
                )
                guard outcome.didChangeAnything else { throw TrackingWriteError.notRecognised }
            case .simkl:
                try await SimklClient.shared.write(
                    list: added ? .planToWatch : nil,
                    removing: !added,
                    ids: preview.trackingIds,
                    title: preview.name,
                    year: preview.year,
                    type: preview.type,
                    clientId: settings.tracking.simklClientId,
                    token: settings.tracking.simklAccessToken
                )
            }
        }
    }

    /// Marking an episode or film watched, or taking that mark back. Both accounts call it
    /// history, and both express "unwatched" as removing the history entry rather than as a
    /// state of its own.
    func watched(
        imdbId: String,
        trackingIds: [String: String],
        title: String?,
        year: Int?,
        type: ContentType,
        season: Int?,
        episode: Int?,
        removing: Bool = false,
        settings: AppSettings
    ) async {
        guard let provider = TrackingWrites.remoteDestination(
            librarySource: settings.tracking.librarySourceMode,
            connected: settings.connectedTrackingProviders
        ) else {
            lastResult = .local
            return
        }
        lastResult = await perform(provider: provider, settings: settings) {
            switch provider {
            case .trakt:
                let outcome = try await TraktClient.shared.write(
                    .history,
                    removing: removing,
                    imdbId: imdbId,
                    type: type,
                    season: season,
                    episode: episode,
                    clientId: settings.tracking.traktClientId,
                    token: settings.tracking.traktAccessToken
                )
                guard outcome.didChangeAnything else { throw TrackingWriteError.notRecognised }
            case .simkl:
                try await SimklClient.shared.write(
                    list: nil,
                    removing: removing,
                    ids: trackingIds,
                    title: title,
                    year: year,
                    type: type,
                    clientId: settings.tracking.simklClientId,
                    token: settings.tracking.simklAccessToken
                )
            }
        }
    }

    private func perform(
        provider: TrackingProviderId,
        settings: AppSettings,
        _ body: () async throws -> Void
    ) async -> TrackingWrites.Result {
        do {
            try await body()
            return .synced(provider)
        } catch {
            let reason = (error as? TrackingWriteError)?.message ?? error.localizedDescription
            log.error("\(provider.rawValue, privacy: .public) write failed: \(reason, privacy: .public)")
            return .remoteFailed(provider, reason: reason)
        }
    }
}

enum TrackingWriteError: Error {
    /// No id the provider could match the title on. Trakt needs IMDb; Simkl takes several.
    case noUsableId
    /// The request succeeded and the provider recognised nothing in it. Trakt answers 201 for
    /// this, so a status-code check alone would call it a success.
    case notRecognised

    var message: String {
        switch self {
        case .noUsableId: return "This title has no id the account recognises"
        case .notRecognised: return "The account did not recognise this title"
        }
    }
}

extension MetaPreview {
    /// Every id a tracking provider might match this title on.
    ///
    /// Trakt only takes IMDb, but Simkl keys on whatever it recognises, and our own ids arrive
    /// in the `prefix:value` form `SimklClient` already projects — `tmdb:329865`, `mal:437`. A
    /// show carrying only a MAL id is precisely the anime case that gets silently dropped when
    /// IMDb is treated as the only key.
    var trackingIds: [String: String] {
        var ids: [String: String] = [:]
        if let imdbId = imdbId?.nilIfBlank { ids["imdb"] = imdbId }
        if id.hasPrefix("tt") {
            ids["imdb"] = id
        } else if let separator = id.firstIndex(of: ":") {
            let key = String(id[id.startIndex..<separator])
            let value = String(id[id.index(after: separator)...])
            if !key.isEmpty, !value.isEmpty { ids[key] = value }
        }
        return ids
    }

    /// The first four-digit run in `releaseInfo`, which carries "2019" and "2019–2022" alike.
    /// Simkl uses it to disambiguate a title match; nothing depends on it being present.
    var year: Int? {
        guard let releaseInfo else { return nil }
        var digits = ""
        for character in releaseInfo {
            if character.isNumber {
                digits.append(character)
                if digits.count == 4 { return Int(digits) }
            } else {
                digits = ""
            }
        }
        return nil
    }
}
