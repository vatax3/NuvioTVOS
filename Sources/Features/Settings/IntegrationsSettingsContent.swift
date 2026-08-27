import SwiftUI

// MARK: - Tracking (port of TrackingSettingsScreen + TraktViewModel)

struct TrackingSettingsContent: View {
    @Environment(\.nuvioColors) private var colors
    @Environment(AppSettings.self) private var settings

    @State private var deviceCode: TraktClient.DeviceCode?
    @State private var authTask: Task<Void, Never>?
    @State private var statusMessage: String?
    @State private var simklPin: SimklClient.PinCode?
    @State private var simklTask: Task<Void, Never>?
    @State private var simklStatus: String?

    private var tracking: TrackingSettingsStore { settings.tracking }
    private var connectedProviders: Set<TrackingProviderId> { settings.connectedTrackingProviders }

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
                        title: L10n.text("settings.integrations.signed_in_as", fallback: "Signed in as"),
                        value: tracking.traktUsername.nilIfBlank ?? L10n.text("settings.integrations.trakt_account", fallback: "Trakt account"),
                        tint: colors.success
                    )
                    SettingsToggle(
                        title: L10n.text("settings.integrations.scrobble", fallback: "Scrobble playback"),
                        subtitle: L10n.text("settings.integrations.scrobble_sub", fallback: "Report progress so Trakt marks episodes watched"),
                        systemImage: "dot.radiowaves.up.forward",
                        isOn: $tracking.traktScrobbleEnabled
                    )
                    SettingsOptionRow(
                        title: L10n.text("settings.integrations.anime_seasons", fallback: "Anime seasons"),
                        subtitle: tracking.simklAnimeIdPreference.summary,
                        systemImage: "square.stack.3d.up",
                        selection: $tracking.simklAnimeIdPreference
                    )
                    SettingsRow(
                        title: L10n.text("settings.integrations.sign_out", fallback: "Sign out"),
                        subtitle: L10n.text("settings.integrations.sign_out_sub", fallback: "Remove the token from this device"),
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
                        title: L10n.text("settings.integrations.client_id", fallback: "Client ID"),
                        placeholder: L10n.text("settings.integrations.trakt_client_id_hint", fallback: "Trakt application client id"),
                        text: $tracking.traktClientId
                    )
                    SettingsTextFieldRow(
                        title: L10n.text("settings.integrations.client_secret", fallback: "Client secret"),
                        masked: true,
                        text: $tracking.traktClientSecret
                    )

                    if let deviceCode {
                        SettingsInfoRow(title: L10n.text("settings.integrations.go_to", fallback: "Go to"), value: deviceCode.verificationURL, tint: colors.secondary)
                        SettingsInfoRow(title: L10n.text("settings.integrations.enter_code", fallback: "Enter code"), value: deviceCode.userCode, tint: colors.textPrimary)
                        SettingsInfoRow(title: L10n.text("settings.integrations.status", fallback: "Status"), value: statusMessage ?? L10n.text("settings.integrations.waiting_approval", fallback: "Waiting for approval…"))
                    } else {
                        SettingsRow(
                            title: L10n.text("settings.integrations.connect_trakt", fallback: "Connect Trakt"),
                            subtitle: tracking.canStartTraktAuth
                                ? L10n.text("settings.integrations.connect_trakt_sub", fallback: "Get a pairing code for trakt.tv/activate")
                                : L10n.text("settings.integrations.need_id_and_secret", fallback: "Enter a client id and secret first"),
                            systemImage: "link.badge.plus",
                            action: { startAuth() }
                        )
                        .disabled(!tracking.canStartTraktAuth)
                        .opacity(tracking.canStartTraktAuth ? 1 : NuvioTheme.effects.disabledAlpha)
                    }

                    if let statusMessage, deviceCode == nil {
                        SettingsInfoRow(title: L10n.text("settings.integrations.status", fallback: "Status"), value: statusMessage, tint: colors.error)
                    }
                }
            }

            SettingsCard(
                title: "Simkl",
                footnote: """
                Create an app at simkl.com/settings/developer and paste its client id. Playback \
                progress, pauses and completed titles can then be synchronised with Simkl.
                """
            ) {
                if tracking.isSimklAuthenticated {
                    SettingsInfoRow(
                        title: L10n.text("settings.integrations.signed_in_as", fallback: "Signed in as"),
                        value: tracking.simklUsername.nilIfBlank ?? L10n.text("settings.integrations.simkl_account", fallback: "Simkl account"),
                        tint: colors.success
                    )
                    SettingsToggle(
                        title: L10n.text("settings.integrations.report_watched", fallback: "Report watched"),
                        subtitle: L10n.text("settings.integrations.report_watched_sub", fallback: "Synchronise playback progress and history"),
                        systemImage: "dot.radiowaves.up.forward",
                        isOn: $tracking.simklScrobbleEnabled
                    )
                    SettingsRow(
                        title: L10n.text("settings.integrations.sign_out", fallback: "Sign out"),
                        subtitle: L10n.text("settings.integrations.sign_out_sub", fallback: "Remove the token from this device"),
                        systemImage: "rectangle.portrait.and.arrow.right",
                        action: {
                            simklTask?.cancel()
                            simklPin = nil
                            simklStatus = nil
                            tracking.clearSimklSession()
                        }
                    )
                } else {
                    SettingsTextFieldRow(
                        title: L10n.text("settings.integrations.client_id", fallback: "Client ID"),
                        placeholder: L10n.text("settings.integrations.simkl_client_id_hint", fallback: "Simkl application client id"),
                        text: $tracking.simklClientId
                    )

                    if let simklPin {
                        SettingsInfoRow(title: L10n.text("settings.integrations.go_to", fallback: "Go to"), value: simklPin.verificationURL, tint: colors.secondary)
                        SettingsInfoRow(title: L10n.text("settings.integrations.enter_code", fallback: "Enter code"), value: simklPin.userCode, tint: colors.textPrimary)
                        SettingsInfoRow(title: L10n.text("settings.integrations.status", fallback: "Status"), value: simklStatus ?? L10n.text("settings.integrations.waiting_approval", fallback: "Waiting for approval…"))
                    } else {
                        SettingsRow(
                            title: L10n.text("settings.integrations.connect_simkl", fallback: "Connect Simkl"),
                            subtitle: tracking.canStartSimklAuth
                                ? L10n.text("settings.integrations.connect_simkl_sub", fallback: "Get a PIN for simkl.com/pin")
                                : L10n.text("settings.integrations.need_id", fallback: "Enter a client id first"),
                            systemImage: "link.badge.plus",
                            action: { startSimklAuth() }
                        )
                        .disabled(!tracking.canStartSimklAuth)
                        .opacity(tracking.canStartSimklAuth ? 1 : NuvioTheme.effects.disabledAlpha)
                    }

                    if let simklStatus, simklPin == nil {
                        SettingsInfoRow(title: L10n.text("settings.integrations.status", fallback: "Status"), value: simklStatus, tint: colors.error)
                    }
                }
            }

            SettingsCard(
                title: L10n.text("settings.integrations.sources", fallback: "Sources"),
                footnote: L10n.text("settings.integrations.sources_footnote", fallback: "Where Nuvio reads watch state and your library from.")
            ) {
                // Only the accounts actually signed in are offered. Listing Trakt to someone who
                // never connected it is offering a choice that silently does nothing — and the
                // preference can also arrive from another device through account sync, which is
                // why the readers use `settings.effective…` rather than the raw value.
                SettingsOptionRow(
                    title: L10n.text("settings.integrations.watch_progress", fallback: "Watch progress"),
                    subtitle: connectedProviders.isEmpty
                        ? L10n.text("settings.integrations.watch_progress_sub", fallback: "Connect Trakt or Simkl above to read progress from an account")
                        : nil,
                    systemImage: "clock.arrow.circlepath",
                    options: TrackingSources.availableWatchProgressSources(connected: connectedProviders),
                    selection: $tracking.watchProgressSource
                )
                SettingsOptionRow(
                    title: L10n.text("settings.integrations.library", fallback: "Library"),
                    systemImage: "bookmark",
                    options: TrackingSources.availableLibrarySourceModes(connected: connectedProviders),
                    selection: $tracking.librarySourceMode
                )
                SettingsOptionRow(
                    title: L10n.text("settings.integrations.more_like_this", fallback: "More like this"),
                    systemImage: "square.stack.3d.up",
                    selection: $tracking.moreLikeThisSource
                )
            }

            SettingsCard(title: L10n.text("settings.integrations.continue_watching", fallback: "Continue Watching")) {
                SettingsStepperRow(
                    title: L10n.text("settings.integrations.drop_older_than", fallback: "Drop items older than"),
                    value: $tracking.continueWatchingDaysCap,
                    range: 7...365, step: 7,
                    format: { "\($0) days" }
                )
                SettingsToggle(
                    title: L10n.text("settings.integrations.next_up_furthest", fallback: "Next up from furthest episode"),
                    subtitle: L10n.text("settings.integrations.next_up_furthest_sub", fallback: "Rather than the earliest unwatched one"),
                    isOn: $tracking.nextUpFromFurthestEpisode
                )
                SettingsToggle(
                    title: L10n.text("settings.integrations.show_unaired", fallback: "Show unaired next up"),
                    isOn: $tracking.showUnairedNextUp
                )
            }

            SettingsCard(
                title: L10n.text("settings.integrations.detail_page", fallback: "Detail page"),
                footnote: L10n.text("settings.integrations.comments_footnote", fallback: "Comments are public Trakt data — a client id is enough, signing in is not required.")
            ) {
                SettingsToggle(
                    title: L10n.text("settings.integrations.show_comments", fallback: "Show Trakt comments"),
                    subtitle: tracking.traktClientId.isEmpty
                        ? L10n.text("settings.integrations.needs_trakt_id", fallback: "Needs a Trakt client id")
                        : L10n.text("settings.integrations.show_comments_sub", fallback: "Adds a Comments action to the detail screen, with spoilers hidden until revealed"),
                    systemImage: "text.bubble",
                    isOn: $tracking.showMetaComments
                )
                .disabled(tracking.traktClientId.isEmpty)
                .opacity(tracking.traktClientId.isEmpty ? NuvioTheme.effects.disabledAlpha : 1)
            }
        }
        .onDisappear {
            authTask?.cancel()
            simklTask?.cancel()
        }
    }

    private func startSimklAuth() {
        let clientId = tracking.simklClientId.trimmingCharacters(in: .whitespaces)
        simklStatus = nil

        simklTask?.cancel()
        simklTask = Task {
            do {
                let pin = try await SimklClient.shared.startPinAuth(clientId: clientId)
                simklPin = pin
                simklStatus = L10n.text("settings.integrations.waiting_approval", fallback: "Waiting for approval…")

                let token = await SimklClient.shared.pollForToken(
                    userCode: pin.userCode,
                    clientId: clientId,
                    interval: pin.interval,
                    expiresIn: pin.expiresIn
                )
                guard let token else {
                    simklPin = nil
                    simklStatus = L10n.text("settings.integrations.pin_expired", fallback: "The PIN expired. Try again.")
                    return
                }
                tracking.simklAccessToken = token
                tracking.simklUsername = await SimklClient.shared.username(
                    clientId: clientId, token: token
                ) ?? ""
                simklPin = nil
                simklStatus = nil
            } catch {
                simklPin = nil
                simklStatus = error.localizedDescription
            }
        }
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
                statusMessage = L10n.text("settings.integrations.waiting_approval", fallback: "Waiting for approval…")

                let tokens = await TraktClient.shared.pollForToken(
                    deviceCode: code.deviceCode,
                    clientId: clientId,
                    clientSecret: clientSecret,
                    interval: code.interval,
                    expiresIn: code.expiresIn
                )
                guard let tokens else {
                    deviceCode = nil
                    statusMessage = L10n.text("settings.integrations.code_expired", fallback: "The pairing code expired. Try again.")
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

/// TMDB and MDBList, each opened from the Integrations hub the way Android splits them.
struct TmdbSettingsCard: View {
    @Environment(\.nuvioColors) private var colors
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var tmdb = settings.tmdb

        VStack(alignment: .leading, spacing: NuvioTheme.components.settings.rowGap) {
            SettingsCard(
                title: "TMDB",
                footnote: """
                Fills in artwork, logos, cast photos and recommendations that most Stremio \
                catalogs do not carry. Create a free API key at themoviedb.org.
                """
            ) {
                SettingsToggle(
                    title: L10n.text("settings.integrations.enable_tmdb", fallback: "Enable TMDB enrichment"),
                    systemImage: "photo.stack",
                    isOn: $tmdb.enabled
                )
                if tmdb.enabled {
                    SettingsTextFieldRow(
                        title: L10n.text("settings.integrations.api_key", fallback: "API key"),
                        placeholder: L10n.text("settings.integrations.tmdb_key_hint", fallback: "TMDB v3 API key"),
                        masked: true,
                        text: $tmdb.apiKey
                    )
                    SettingsTextFieldRow(
                        title: L10n.text("settings.integrations.language", fallback: "Language"),
                        subtitle: L10n.text("settings.integrations.language_hint", fallback: "BCP-47, e.g. en-US or fr-FR"),
                        placeholder: "en-US",
                        text: $tmdb.language
                    )
                    SettingsToggle(title: L10n.text("settings.integrations.artwork_logos", fallback: "Artwork and logos"), isOn: $tmdb.useArtwork)
                    SettingsToggle(title: L10n.text("settings.integrations.overview_rating", fallback: "Overview and rating"), isOn: $tmdb.useBasicInfo)
                    SettingsToggle(title: L10n.text("settings.integrations.runtime_details", fallback: "Runtime and details"), isOn: $tmdb.useDetails)
                    SettingsToggle(title: L10n.text("settings.integrations.cast", fallback: "Cast"), isOn: $tmdb.useCredits)
                    SettingsToggle(title: L10n.text("settings.integrations.episode_data", fallback: "Episode data"), isOn: $tmdb.useEpisodes)
                    SettingsToggle(title: L10n.text("settings.integrations.trailers", fallback: "Trailers"), isOn: $tmdb.useTrailers)
                    SettingsToggle(title: L10n.text("settings.integrations.networks", fallback: "Networks"), isOn: $tmdb.useNetworks)
                    SettingsToggle(title: L10n.text("settings.integrations.production_companies", fallback: "Production companies"), isOn: $tmdb.useProductions)
                    SettingsToggle(title: L10n.text("settings.integrations.certifications", fallback: "Certifications"), isOn: $tmdb.useReleaseDates)
                    SettingsToggle(title: L10n.text("settings.integrations.more_like_this", fallback: "More like this"), isOn: $tmdb.useMoreLikeThis)
                    SettingsToggle(
                        title: L10n.text("settings.integrations.enrich_cw", fallback: "Enrich Continue Watching"),
                        subtitle: L10n.text("settings.integrations.enrich_cw_sub", fallback: "Use TMDB stills for in-progress episodes"),
                        isOn: $tmdb.enrichContinueWatching
                    )
                }
            }

        }
    }
}

struct MDBListSettingsCard: View {
    @Environment(\.nuvioColors) private var colors
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var mdblist = settings.mdblist

        VStack(alignment: .leading, spacing: NuvioTheme.components.settings.rowGap) {
            SettingsCard(
                title: "MDBList",
                footnote: L10n.text("settings.integrations.mdblist_footnote", fallback: "Aggregated ratings from IMDb, TMDB, Rotten Tomatoes and others.")
            ) {
                SettingsToggle(
                    title: L10n.text("settings.integrations.enable_mdblist", fallback: "Enable MDBList ratings"),
                    systemImage: "star.square.on.square",
                    isOn: $mdblist.enabled
                )
                if mdblist.enabled {
                    SettingsTextFieldRow(
                        title: L10n.text("settings.integrations.api_key", fallback: "API key"),
                        placeholder: L10n.text("settings.integrations.mdblist_key_hint", fallback: "mdblist.com API key"),
                        masked: true,
                        text: $mdblist.apiKey
                    )
                    SettingsToggle(title: "IMDb", isOn: $mdblist.showImdb)
                    SettingsToggle(title: "TMDB", isOn: $mdblist.showTmdb)
                    SettingsToggle(title: L10n.text("settings.integrations.rotten_tomatoes", fallback: "Rotten Tomatoes"), isOn: $mdblist.showTomatoes)
                    SettingsToggle(title: L10n.text("settings.integrations.audience_score", fallback: "Audience score"), isOn: $mdblist.showAudience)
                    SettingsToggle(title: "Metacritic", isOn: $mdblist.showMetacritic)
                    SettingsToggle(title: "Trakt", isOn: $mdblist.showTrakt)
                    SettingsToggle(title: "Letterboxd", isOn: $mdblist.showLetterboxd)
                    SettingsToggle(title: "MyAnimeList", isOn: $mdblist.showMal)
                }
            }
        }
    }
}

// MARK: - Anime-Skip (port of AnimeSkipSettingsScreen)

struct AnimeSkipSettingsCard: View {
    @Environment(\.nuvioColors) private var colors
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var skip = settings.skipIntro

        VStack(alignment: .leading, spacing: NuvioTheme.components.settings.rowGap) {
            SettingsCard(
                title: L10n.text("settings.integrations.skip_segments", fallback: "Skip segments"),
                footnote: """
                Nothing here needs configuring. IntroDB and AniSkip are queried together for \
                every episode and neither wants an account — each kind of segment is taken from \
                whichever knows it. Anime-Skip is an optional third source, and the only one that \
                needs a client id, from anime-skip.com.
                """
            ) {
                SettingsTextFieldRow(
                    title: L10n.text("settings.integrations.introdb_endpoint", fallback: "IntroDB endpoint"),
                    subtitle: L10n.text("settings.integrations.introdb_endpoint_sub", fallback: "Leave empty for the public endpoint; set one to use your own instance"),
                    text: $skip.introDbApiUrl
                )
                SettingsToggle(
                    title: "Anime-Skip",
                    subtitle: L10n.text("settings.integrations.anime_skip_sub", fallback: "A third source for anime; needs a client id"),
                    systemImage: "forward.frame",
                    isOn: $skip.animeSkipEnabled
                )
                if skip.animeSkipEnabled {
                    SettingsTextFieldRow(
                        title: L10n.text("settings.integrations.anime_skip_id_hint", fallback: "Anime-Skip client id"),
                        masked: true,
                        text: $skip.animeSkipClientId
                    )
                }
                autoSkipToggle(
                    .intro, title: L10n.text("settings.integrations.skip_intros_auto", fallback: "Skip intros automatically"),
                    subtitle: L10n.text("settings.integrations.skip_intros_auto_sub", fallback: "Jump without waiting for the button")
                )
                autoSkipToggle(
                    .recap, title: L10n.text("settings.integrations.skip_recaps_auto", fallback: "Skip recaps automatically"),
                    subtitle: L10n.text("settings.integrations.skip_recaps_auto_sub", fallback: "Jump past the previously-on")
                )
                autoSkipToggle(
                    .outro, title: L10n.text("settings.integrations.skip_outros_auto", fallback: "Skip outros automatically"),
                    subtitle: L10n.text("settings.integrations.skip_outros_auto_sub", fallback: "Jumps to the end of the episode as the credits begin")
                )
            }

        }
    }

    /// The store keeps a set rather than a toggle per kind, so each row binds through it.
    private func autoSkipToggle(
        _ kind: SkipSegment.Kind, title: String, subtitle: String
    ) -> some View {
        let skip = settings.skipIntro
        return SettingsToggle(
            title: title,
            subtitle: subtitle,
            isOn: Binding(
                get: { skip.autoSkips(kind) },
                set: { skip.setAutoSkip(kind, $0) }
            )
        )
    }
}

/// Stream-list badges — presentation of the source list, so it sits with Playback.
struct StreamBadgeSettingsCard: View {
    @Environment(AppSettings.self) private var settings
    @Environment(Router.self) private var router

    var body: some View {
        @Bindable var badges = settings.streamBadges

        Group {
            SettingsCard(title: L10n.text("settings.integrations.source_list", fallback: "Source list")) {
                SettingsOptionRow(
                    title: L10n.text("settings.integrations.badge_placement", fallback: "Badge placement"),
                    systemImage: "tag",
                    selection: $badges.placement
                )
                SettingsToggle(title: L10n.text("settings.integrations.addon_logos", fallback: "Addon logos"), isOn: $badges.showAddonLogo)
                SettingsToggle(title: L10n.text("settings.integrations.file_size", fallback: "File size"), isOn: $badges.showFileSizeBadges)
                SettingsToggle(title: L10n.text("settings.integrations.seeders", fallback: "Seeders"), isOn: $badges.showSeederBadges)
                SettingsToggle(title: L10n.text("settings.integrations.cache_status", fallback: "Cache status"), isOn: $badges.showCacheBadges)
                SettingsRow(
                    title: L10n.text("settings.integrations.badge_rules", fallback: "Badge rules"),
                    subtitle: ruleSubtitle,
                    systemImage: "checkerboard.rectangle",
                    trailing: { SettingsValueLabel(value: "") },
                    action: { router.push(.streamBadgeRules) }
                )
            }
        }
    }

    private var ruleSubtitle: String {
        let rules = settings.streamBadges.rules
        guard rules.hasImport else {
            return L10n.text("settings.integrations.badge_rules_sub", fallback: "Import a badge pack — managed from a phone")
        }
        let count = rules.enabledFilterCount
        return count == 1 ? "1 rule applied" : "\(count) rules applied"
    }
}
