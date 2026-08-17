import SwiftUI

// MARK: - Tracking (port of TrackingSettingsScreen + TraktViewModel)

struct TrackingSettingsContent: View {
    @Environment(\.nuvioColors) private var colors
    @Environment(AppSettings.self) private var settings

    @State private var deviceCode: TraktClient.DeviceCode?
    @State private var authTask: Task<Void, Never>?
    @State private var statusMessage: String?

    private var tracking: TrackingSettingsStore { settings.tracking }

    var body: some View {
        @Bindable var tracking = tracking

        VStack(alignment: .leading, spacing: NuvioTheme.components.settings.rowGap) {
            SettingsCard(
                title: "Trakt",
                footnote: """
                Nuvio's own Trakt application id ships inside the official builds and cannot be \
                redistributed, so this client uses one you create at trakt.tv/oauth/applications. \
                Set the redirect URI to urn:ietf:wg:oauth:2.0:oob.
                """
            ) {
                if tracking.isTraktAuthenticated {
                    SettingsInfoRow(
                        title: "Signed in as",
                        value: tracking.traktUsername.nilIfBlank ?? "Trakt account",
                        tint: colors.success
                    )
                    SettingsToggle(
                        title: "Scrobble playback",
                        subtitle: "Report progress so Trakt marks episodes watched",
                        systemImage: "dot.radiowaves.up.forward",
                        isOn: $tracking.traktScrobbleEnabled
                    )
                    SettingsRow(
                        title: "Sign out",
                        subtitle: "Remove the token from this device",
                        systemImage: "rectangle.portrait.and.arrow.right",
                        action: {
                            authTask?.cancel()
                            deviceCode = nil
                            statusMessage = nil
                            tracking.clearTraktSession()
                        }
                    )
                } else {
                    SettingsTextFieldRow(
                        title: "Client ID",
                        placeholder: "Trakt application client id",
                        text: $tracking.traktClientId
                    )
                    SettingsTextFieldRow(
                        title: "Client secret",
                        masked: true,
                        text: $tracking.traktClientSecret
                    )

                    if let deviceCode {
                        SettingsInfoRow(title: "Go to", value: deviceCode.verificationURL, tint: colors.secondary)
                        SettingsInfoRow(title: "Enter code", value: deviceCode.userCode, tint: colors.textPrimary)
                        SettingsInfoRow(title: "Status", value: statusMessage ?? "Waiting for approval…")
                    } else {
                        SettingsRow(
                            title: "Connect Trakt",
                            subtitle: tracking.canStartTraktAuth
                                ? "Get a pairing code for trakt.tv/activate"
                                : "Enter a client id and secret first",
                            systemImage: "link.badge.plus",
                            action: { startAuth() }
                        )
                        .disabled(!tracking.canStartTraktAuth)
                        .opacity(tracking.canStartTraktAuth ? 1 : NuvioTheme.effects.disabledAlpha)
                    }

                    if let statusMessage, deviceCode == nil {
                        SettingsInfoRow(title: "Status", value: statusMessage, tint: colors.error)
                    }
                }
            }

            SettingsCard(
                title: "Sources",
                footnote: "Where Nuvio reads watch state and your library from."
            ) {
                SettingsOptionRow(
                    title: "Watch progress",
                    systemImage: "clock.arrow.circlepath",
                    selection: $tracking.watchProgressSource
                )
                SettingsOptionRow(
                    title: "Library",
                    systemImage: "bookmark",
                    selection: $tracking.librarySourceMode
                )
                SettingsOptionRow(
                    title: "More like this",
                    systemImage: "square.stack.3d.up",
                    selection: $tracking.moreLikeThisSource
                )
            }

            SettingsCard(title: "Continue Watching") {
                SettingsStepperRow(
                    title: "Drop items older than",
                    value: $tracking.continueWatchingDaysCap,
                    range: 7...365, step: 7,
                    format: { "\($0) days" }
                )
                SettingsToggle(
                    title: "Next up from furthest episode",
                    subtitle: "Rather than the earliest unwatched one",
                    isOn: $tracking.nextUpFromFurthestEpisode
                )
                SettingsToggle(
                    title: "Show unaired next up",
                    isOn: $tracking.showUnairedNextUp
                )
            }

            SettingsCard(title: "Detail page") {
                SettingsToggle(
                    title: "Show Trakt comments",
                    subtitle: "Community reviews under the title",
                    systemImage: "text.bubble",
                    isOn: $tracking.showMetaComments
                )
            }
        }
        .onDisappear { authTask?.cancel() }
    }

    private func startAuth() {
        let clientId = tracking.traktClientId.trimmingCharacters(in: .whitespaces)
        let clientSecret = tracking.traktClientSecret.trimmingCharacters(in: .whitespaces)
        statusMessage = nil

        authTask?.cancel()
        authTask = Task {
            do {
                let code = try await TraktClient.shared.startDeviceAuth(clientId: clientId)
                deviceCode = code
                statusMessage = "Waiting for approval…"

                let tokens = await TraktClient.shared.pollForToken(
                    deviceCode: code.deviceCode,
                    clientId: clientId,
                    clientSecret: clientSecret,
                    interval: code.interval,
                    expiresIn: code.expiresIn
                )
                guard let tokens else {
                    deviceCode = nil
                    statusMessage = "The pairing code expired. Try again."
                    return
                }
                tracking.traktAccessToken = tokens.accessToken
                tracking.traktRefreshToken = tokens.refreshToken
                tracking.traktUsername = await TraktClient.shared.username(
                    clientId: clientId, token: tokens.accessToken
                ) ?? ""
                deviceCode = nil
                statusMessage = nil
            } catch {
                deviceCode = nil
                statusMessage = error.localizedDescription
            }
        }
    }
}

// MARK: - Metadata (port of TmdbSettingsScreen + MDBListSettingsScreen)

struct MetadataSettingsContent: View {
    @Environment(\.nuvioColors) private var colors
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var tmdb = settings.tmdb
        @Bindable var mdblist = settings.mdblist

        VStack(alignment: .leading, spacing: NuvioTheme.components.settings.rowGap) {
            SettingsCard(
                title: "TMDB",
                footnote: """
                Fills in artwork, logos, cast photos and recommendations that most Stremio \
                catalogs do not carry. Create a free API key at themoviedb.org.
                """
            ) {
                SettingsToggle(
                    title: "Enable TMDB enrichment",
                    systemImage: "photo.stack",
                    isOn: $tmdb.enabled
                )
                if tmdb.enabled {
                    SettingsTextFieldRow(
                        title: "API key",
                        placeholder: "TMDB v3 API key",
                        masked: true,
                        text: $tmdb.apiKey
                    )
                    SettingsTextFieldRow(
                        title: "Language",
                        subtitle: "BCP-47, e.g. en-US or fr-FR",
                        placeholder: "en-US",
                        text: $tmdb.language
                    )
                    SettingsToggle(title: "Artwork and logos", isOn: $tmdb.useArtwork)
                    SettingsToggle(title: "Overview and rating", isOn: $tmdb.useBasicInfo)
                    SettingsToggle(title: "Runtime and details", isOn: $tmdb.useDetails)
                    SettingsToggle(title: "Cast", isOn: $tmdb.useCredits)
                    SettingsToggle(title: "Episode data", isOn: $tmdb.useEpisodes)
                    SettingsToggle(title: "Trailers", isOn: $tmdb.useTrailers)
                    SettingsToggle(title: "Networks", isOn: $tmdb.useNetworks)
                    SettingsToggle(title: "Production companies", isOn: $tmdb.useProductions)
                    SettingsToggle(title: "Certifications", isOn: $tmdb.useReleaseDates)
                    SettingsToggle(title: "More like this", isOn: $tmdb.useMoreLikeThis)
                    SettingsToggle(
                        title: "Enrich Continue Watching",
                        subtitle: "Use TMDB stills for in-progress episodes",
                        isOn: $tmdb.enrichContinueWatching
                    )
                }
            }

            SettingsCard(
                title: "MDBList",
                footnote: "Aggregated ratings from IMDb, TMDB, Rotten Tomatoes and others."
            ) {
                SettingsToggle(
                    title: "Enable MDBList ratings",
                    systemImage: "star.square.on.square",
                    isOn: $mdblist.enabled
                )
                if mdblist.enabled {
                    SettingsTextFieldRow(
                        title: "API key",
                        placeholder: "mdblist.com API key",
                        masked: true,
                        text: $mdblist.apiKey
                    )
                    SettingsToggle(title: "IMDb", isOn: $mdblist.showImdb)
                    SettingsToggle(title: "TMDB", isOn: $mdblist.showTmdb)
                    SettingsToggle(title: "Rotten Tomatoes", isOn: $mdblist.showTomatoes)
                    SettingsToggle(title: "Audience score", isOn: $mdblist.showAudience)
                    SettingsToggle(title: "Metacritic", isOn: $mdblist.showMetacritic)
                    SettingsToggle(title: "Trakt", isOn: $mdblist.showTrakt)
                    SettingsToggle(title: "Letterboxd", isOn: $mdblist.showLetterboxd)
                    SettingsToggle(title: "MyAnimeList", isOn: $mdblist.showMal)
                }
            }
        }
    }
}

// MARK: - Skip intro & trailers (port of AnimeSkipSettingsScreen + TrailerSettings)

struct ExtrasSettingsContent: View {
    @Environment(\.nuvioColors) private var colors
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var skip = settings.skipIntro
        @Bindable var trailers = settings.trailers
        @Bindable var badges = settings.streamBadges

        VStack(alignment: .leading, spacing: NuvioTheme.components.settings.rowGap) {
            SettingsCard(
                title: "Skip segments",
                footnote: """
                AniSkip covers anime and needs no account. Anime-Skip needs a client id from \
                anime-skip.com.
                """
            ) {
                SettingsToggle(
                    title: "AniSkip",
                    subtitle: "Community intro/outro timings",
                    systemImage: "forward.fill",
                    isOn: $skip.aniSkipEnabled
                )
                SettingsToggle(
                    title: "Anime-Skip",
                    systemImage: "forward.frame",
                    isOn: $skip.animeSkipEnabled
                )
                if skip.animeSkipEnabled {
                    SettingsTextFieldRow(
                        title: "Anime-Skip client id",
                        masked: true,
                        text: $skip.animeSkipClientId
                    )
                }
                SettingsToggle(
                    title: "Skip intros automatically",
                    subtitle: "Jump without waiting for the button",
                    isOn: $skip.autoSkipIntro
                )
                SettingsToggle(
                    title: "Skip outros automatically",
                    isOn: $skip.autoSkipOutro
                )
            }

            SettingsCard(
                title: "Trailers",
                footnote: "Plays a trailer behind the hero after the card stays focused."
            ) {
                SettingsToggle(
                    title: "Hero trailers",
                    systemImage: "play.tv",
                    isOn: $trailers.enabled
                )
                if trailers.enabled {
                    SettingsStepperRow(
                        title: "Start after",
                        value: $trailers.delaySeconds,
                        range: 0...15,
                        format: { "\($0)s" }
                    )
                }
            }

            SettingsCard(title: "Source list") {
                SettingsOptionRow(
                    title: "Badge placement",
                    systemImage: "tag",
                    selection: $badges.placement
                )
                SettingsToggle(title: "Addon logos", isOn: $badges.showAddonLogo)
                SettingsToggle(title: "File size", isOn: $badges.showFileSizeBadges)
                SettingsToggle(title: "Seeders", isOn: $badges.showSeederBadges)
                SettingsToggle(title: "Cache status", isOn: $badges.showCacheBadges)
            }
        }
    }
}
