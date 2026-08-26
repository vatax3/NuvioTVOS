# Functional parity audit — tvOS 1.0.16 vs Android TV 0.8.9-beta

Audit date: 2026-08-25. Supersedes the audit published with 1.0.15.

## Scope and evidence

Baseline revisions, exact:

- tvOS `v1.0.16` — commit `8ab03e3`, the current `main`;
- Android TV `0.8.9-beta` — commit `f40c422ee`, tagged 2026-08-25.

`0.8.9-beta` is the newest upstream release; `origin/dev` carries 43 further commits.

### The previous audit measured the wrong tree

This pass began by re-fetching upstream, and that immediately invalidated a claim in the
1.0.15 document. That audit named `0.8.7-beta` (`91c1355`) as its baseline, but the local
clone was shallow and its `HEAD` was `3303cd1` — an **ancestor** of `0.8.7-beta`, not the tag.
Every "absent upstream" finding it made was measured against a tree older than the release it
cited. One withdrawal was wrong because of it (see *Corrections*, below).

The lesson is procedural and worth keeping: **fetch before auditing, and check out the tag by
name.** This pass works from `git worktree add --detach <tag>`, so the compared tree is the
tagged release and nothing else.

### What this pass re-derived

Structural comparison, re-run from scratch against `0.8.9-beta`:

- all 300 upstream preference keys against every string literal in `Sources/`;
- the screen/route inventory (40 upstream `*Screen.kt`, 46 settings files, 84 player files);
- the API-client inventory (16 Retrofit interfaces) and their build-time configuration;
- the 139 commits between `0.8.7-beta` and `0.8.9-beta`, for subsystems added since;
- targeted reads of the subsystems those turned up.

Rows below marked ✻ were re-verified in this pass. Unmarked rows are carried from the 1.0.15
audit's screen-by-screen comparison and were not independently re-derived here.

Legend: **Parity** = same viewer outcome; **Adapted** = intentional tvOS implementation;
**Partial** = meaningful behaviour missing; **Missing** = no implementation; **Forced** = the
platform refuses the upstream approach.

## Result by product area

| Area | Status | Difference |
|---|---|---|
| First run | Parity | Three Android screens are one three-step tvOS flow. |
| Profiles | Parity | Avatars, launch selection, create/edit/delete, PIN, restricted profiles. |
| Nuvio account and sync | Adapted | QR sign-in, device codes, linked devices, per-profile sync. |
| Main navigation | Adapted | Same destinations; sidebar focus behaviour is tvOS-native. |
| Home layouts and hero ✻ | Partial | Classic/Grid/Modern, hero, catalog order, collections, focus-hold expansion, the classic focus gradient, and since 1.0.19 the Continue Watching toggle and the rating-visibility control. No inline focused trailers. |
| Poster options dialog ✻ | Partial | Since 1.0.18 a long press on any poster offers library add/remove, watched/unwatched, removal from Continue Watching and the detail screen. Since 1.0.25 the watched row covers series too, walking every aired episode — specials and unaired excluded — with one remote call rather than one per episode. Trakt list management and the removal-impact warning are not built. |
| Addons ✻ | Partial | Install, enable, order, remove, rename and catalog configuration exist. No local config server (below). |
| Search | Parity for the Stremio surface | Debounced results, recent queries, cancellation, paginated See All. The private discovery service is unavailable. |
| Discover | Parity for addon catalogs | Tail pagination, de-duplication, cancellation. |
| Detail and metadata ✻ | Partial | Metadata, cast, companies, trailers, More like this, comments, parental guidance, and since 1.0.19 `videos[].rating` from addon metadata plus the rating-visibility rules including hide-until-watched. Since 1.0.27 the TMDB franchise-collection row. Missing: the episode-options overlay and the ratings tab's IMDb scores. |
| Collections | Parity | Data shape, live folder sources, ordering, sync. `focusGifUrl`/`heroVideoUrl` retained but not rendered. |
| Local library/progress ✻ | Parity | Save/remove, Continue Watching, watched threshold, per-profile persistence, account sync, removal from Continue Watching (1.0.18) and a sort control (1.0.19). |
| Trakt | Parity | OAuth, progress, list reads, comments, related titles, scrobbling, `sync/watchlist` and `sync/history` writes. Upstream has no `sync/collection`; neither do we. |
| Simkl | Parity | Five list states, remote resume points, scrobbling, `add-to-list`/`history` writes, the anime identity model since 1.0.22, and playback-session deletion since 1.0.26. Snapshot reconciliation does not apply here; see *Differences assumed*. |
| Next Up from trackers ✻ | Partial | Since 1.0.21 a series whose last episode was finished is offered its next one, with the airing rules, both anchor modes and per-series dismissal. Previously the rail held only half-watched episodes, so finishing one removed the series from Home entirely. Sibling-id reconciliation across id namespaces is not reproduced, and the projection needs the episode list to have been cached by a visit to the detail screen. |
| Debrid providers ✻ | Parity | Validation, cache checks, resolution, file choice, cloud libraries for all three, TorBox device sign-in, and since 1.0.20 the stream name/description template language with its editor. The DSL is ported rather than reinvented, so a format written on Android pastes in and produces the same rows. |
| Stream filtering/ranking | Parity | Resolution, quality, HDR/DV, codec, audio, channels, language, group, limits and the sort matrix are consumed. |
| Stream badges | Parity | Computed badges from parsed attributes, plus — since 1.0.23 — imported rule packs: named regular expressions with their own colours and logos, matched against every field an addon supplied. Upstream's file format, so a pack written for Android TV imports unchanged. Three packs held, one applied. |
| Stream selection UI | Adapted | Same information and grouping; density and geometry follow tvOS. |
| On-TV configuration servers | Parity | `LocalConfigServer` since 1.0.20, serving the debrid formatter, and since 1.0.23 badge rules and plugin repositories. The addon case was already covered by handing off the addon's *own* remote `configure` URL. |
| Direct torrent playback ✻ | **Forced** | Upstream ships TorrServer as `libtorrserver.so` and starts it with `ProcessBuilder`. tvOS allows neither subprocesses nor downloaded executables, so the upstream design cannot be ported at all. A linked-in engine is a different project, not a port. |
| Parallel chunked streaming ✻ | **Missing** | New since 0.8.7: a 1,352-line range downloader with pipelined prefetch, playhead/moov retention across scatter seeks, adaptive 429/503 handling and a chunk cap on low-RAM devices — plus the non-faststart MP4 path built on it. Five settings drive it. |
| Plugin runtime | Partial | Repository/install/settings, HTML/CSS helpers, fetch, `getStreams`. CryptoJS covers common hashes/HMAC, PBKDF2 and AES, not the legacy DES family. |
| Player transport | Parity | In-place sources, episodes, tracks, subtitle appearance/delay, audio delay, speed, seven display modes, stream info, skip cards, post-play, still-watching, external hand-off — and, since 1.0.17, the hidden-controls seek readout. |
| Player failure recovery | Parity at state-machine level | Decoded-first-frame detection, one bounded retry, AVFoundation→mpv fallback, live-playhead resume. |
| Player audio controls | Parity, less two the platform refuses | Output channels, in-player amplification and — since 1.0.24 — persisted amplification, centre-mix level and downmix normalisation. Keep-original-on-downmix and forced optical passthrough cannot exist here; see *Forced*. |
| Dolby Vision profile 7 ✻ | **Adapted (in our favour)** | Upstream carries a forked Matroska extractor, a libdovi bridge, an RPU stripper and DV5→DV8.1 conversion — ~13 files — because ExoPlayer cannot play dual-layer DV. libmpv with the vendored `Libdovi`/`Libplacebo` handles it in-engine. Their five DV settings have no counterpart because they have no problem to solve here. **Unverified on hardware.** |
| Subtitles ✻ | Partial | Addon and muxed tracks, auto-language/forced rules, style, delay, SDH stripping, charset detection, CJK fallback, and since 1.0.19 mojibake repair. Ours reverses the double encoding rather than tabulating known sequences, so it also covers the Cyrillic, Greek and Japanese cases upstream's table does not. Still no sync-by-line dialog. |
| External players | Parity | Infuse/VLC/nPlayer/Outplayer hand-off with subtitle forwarding. Skip-segment forwarding is absent. Zidoo monitoring is Android-only. |
| Top Shelf / launcher | Adapted | Publishes Continue Watching with deep links. Android channel fingerprinting is N/A. |
| In-app updater ✻ | **Missing** | Upstream polls the GitHub releases API and shows a dismissible update banner. We publish GitHub releases too, so this is available to us — it is simply not built. |
| Localisation ✻ | Partial | 108 strings in 2 languages against **2,865 strings in 36 languages**. Most of our UI text is hardcoded English in the views. |
| Supporter perks | Missing by decision | Monetisation belongs to the official project. |
| Crash/diagnostic reporting ✻ | **Forced** | Sentry DSN, the auth-diagnostic and playback-report endpoints are build-time secrets, blank in public source. |
| Episode IMDb ratings ✻ | **Forced** | Served by `api/shows/{id}/season-ratings` on two hosts read from `IMDB_RATINGS_API_BASE_URL` and `IMDB_TAPFRAME_API_BASE_URL` — both blank in public source, same as `PREMIUMIZE_CLIENT_ID`. We substitute TMDB episode scores. |

## The four lists

### Implemented — same viewer outcome

First run · profiles and PIN · Nuvio account, QR sign-in, device codes, linked devices ·
navigation · the three home layouts and the hero · search and its history · discover with
pagination · collections and live folder sources · Trakt end to end including list writes ·
stream filtering and the ranking matrix · the player transport and its seven display modes ·
player failure recovery · external player hand-off · Top Shelf · parental guidance · MDBList ·
AniSkip · addon catalog ordering.

Two areas where we are ahead, both consequences of the engine: **Dolby Vision profile 7**
needs no workaround stack, and **AV1** decodes through dav1d where the A15 has no hardware
path and AVFoundation refuses.

### Partial — the feature exists, some behaviour is missing

- **Detail**: no episode-options overlay.
- **Poster options**: no series watched walk, no Trakt list management, no removal-impact
  warning.
- **Home**: no inline trailers.
- **Next Up**: no sibling-id reconciliation; the projection needs a cached episode list.
- **Player audio**: five controls absent.
- **Subtitles**: no sync-by-line dialog.
- **External players**: no skip-segment forwarding.
- **Plugins**: CryptoJS legacy DES family.
- **Localisation**: 108 strings against 2,865, 2 languages against 36.

### Missing — nothing implemented

- ~~The **poster options dialog**~~ — shipped in 1.0.18; what is left of it is listed under
  *Partial*.
- The **parallel chunked downloader** and the non-faststart MP4 path built on it.
- ~~The **hidden-controls seek overlay**~~ — shipped in 1.0.17. Horizontal presses now seek
  behind a compact readout instead of revealing the transport over the picture; vertical still
  brings the transport back. See `PlayerSeekOverlayPolicy`.

### Differences assumed or forced

**Assumed — our decision, and we would make it again:**

- **libmpv instead of ExoPlayer.** It costs us their buffer-tuning surface, their decoder
  priority controls and their DV7 stack — and it removes the need for the last of those.
- **Supporter perks omitted.** Monetisation belongs to the official project.
- **tvOS-native focus and geometry** rather than pixel-identical Compose.
- **No cached tracking snapshot.** Upstream holds a Simkl snapshot and applies a receipt to it
  after each write, so the interface reflects a mutation before the next sync. Our Trakt and
  Simkl list screens fetch when they appear, so there is no snapshot to reconcile — the same
  outcome by a shorter route, at the cost of a request the cached design would not make.
- **Storage shape**: JSON files and Keychain where upstream uses DataStore. Of the 154
  upstream keys absent from our tree, roughly half are this or ExoPlayer internals; about 45
  correspond to a control a viewer can actually see.

**Forced — the platform or the source refuses:**

- **Direct torrent**, as established above: no subprocess, no downloaded binary.
- **Inline focused trailers**: no supported YouTube playback path on tvOS.
- **Addon configuration pages**: no web view, hence the QR hand-off.
- **Episode IMDb ratings, Premiumize device auth, crash and playback reports**: build-time
  secrets, blank in public source. Guessing endpoint shapes would create silent data loss.
- **The official discovery service**: same.
- **Keep original audio on downmix** and **forced optical passthrough**. The first is an
  ExoPlayer arrangement — its decoder emits a downmix while the multichannel track stays
  selectable — and libmpv has one output chain, not two. The second needs a bitstream
  passthrough API, and tvOS 26 has none: `AVAudioContentSource` is an *encoder* settings key
  (`AVEncoderContentSourceKey`), not a playback path. Passthrough on this platform is what the
  Apple TV's own audio settings decide, which is what the Audio card says.

## Corrections to the 1.0.15 audit

1. **Rating visibility was withdrawn in error.** `home_imdb_ratings_visibility` and
   `detail_imdb_ratings_visibility` were added upstream on 2026-08-13 (`93ff6eea6`) and ship in
   `0.8.7-beta` — the very tag that audit claimed to measure. It measured `3303cd1` instead.
   **The item is reinstated.**
2. **"No Stremio addon publishes a per-episode score"** — the comment at
   [Models.swift:365](Sources/Domain/Models.swift#L365) is falsified by upstream issue #3129 and
   commit `855593afe`, which reads `meta.videos[].rating`. The comment should go and the field
   should be decoded.
3. **"Resume points cannot be deleted, but no affordance asks to"** — upstream's affordance is
   the poster options dialog, which we lack entirely. The gap is the dialog, not the deletion.
4. **The torrent P0 is not a strategy choice.** Upstream's implementation cannot be ported;
   only a differently-architected one could exist here.
5. **Episode IMDb ratings are confirmed unobtainable**, which retroactively justifies shipping
   TMDB scores instead. Upstream's *second* source — addon metadata — is obtainable, and is now
   the cheapest real win on the list.

## Findings this pass turned up in our own tree

Five settings enums are defined and never referenced anywhere: `DecoderPriority`,
`LibassRenderType`, `DolbyVision7HandlingMode`, `VodCacheSizeMode`, `FocusedPosterTrailerTarget`
— all in [SettingsModels.swift](Sources/Domain/SettingsModels.swift). They are the shape of
parity without the substance. Two should be deleted as N/A under mpv; `FocusedPosterTrailerTarget`
tracks a forced gap and can stay only if it is commented as such.

Also: our preference keys were documented as matching the Android names, and mostly do — but
`hero_catalog_keys` and `remember_last_profile` diverge from upstream's `hero_catalog_key` and
`remember_last_profile_enabled`, which breaks the wire compatibility that comment promises.

## Priorities

### P0 — decisions, not code

1. ~~**Direct torrent**: declare debrid a requirement, or scope a linked-in engine as its own
   project~~ — **decided: debrid is required**, stated in the README. Upstream starts TorrServer
   as a subprocess, which tvOS forbids outright, so there was never a port to choose between.
   A linked-in engine would be a separate project and is not planned. This line is closed.
2. **Backend contracts** remain unavailable; keep those controls absent.

### P1 — real gaps, buildable here, ordered by value per line

Every item in this tier has shipped. What is left of the poster dialog — Trakt list management
and the removal-impact warning — and the Next Up sibling-id reconciliation are the two threads
still open, both recorded against their entries below.

1. **Poster options dialog.** Reaches library and watched state from Home, Discover, Search and
   Detail at once, and is the only route to removing a Continue Watching item.
2. ~~**`videos[].rating` from addon metadata**~~ — **shipped in 1.0.19.**
3. ~~**Mojibake repair for subtitles**~~ — **shipped in 1.0.19**, by inverting the double
   encoding rather than tabulating sequences.
4. ~~**Rating visibility, Continue Watching toggle, addon renaming, library sort**~~ —
   **shipped in 1.0.19.**
5. ~~**Debrid formatter**, with the local HTTP server the editors need~~ — **shipped in
   1.0.20.** Stream badge rules and repository config followed in **1.0.23**, a page each on
   the same server.
6. ~~**Simkl anime identity model**~~ — **shipped in 1.0.22.** Snapshot reconciliation and
   `delete-playback` remain.
7. ~~**Next Up projection and dismissal**~~ — **shipped in 1.0.21**, and the episode cache is
   seeded from Continue Watching since **1.0.25**, bounded to the front of the rail. What
   remains is sibling-id reconciliation: a series watched under one addon's id and listed under
   another's is two rows to us and one show to the viewer.

### P2 — larger, or lower value

1. **Parallel chunked downloader.** 1,352 lines upstream. Worth measuring before building:
   mpv's own cache and `--stream-lavf-o` may already close most of the gap on debrid links.
2. **Localisation.** Mechanical and large, but not blocked: `L10n` and the `en`/`fr` tables
   are wired and in use at 209 call sites covering 115 keys — the shell and player
   vocabulary. Roughly 700 prose literals remain, 636 of them in `Sources/Features`. It is
   extended screen by screen, and no mechanism has to be built first.
3. ~~**In-app update banner**~~ — **shipped in 1.0.24**, on the About screen and reading the
   sideloading feed rather than the releases API: it is the artefact that has to be right for
   anyone to install an update at all. It tells and does not install, because a sideloaded app
   on tvOS has no way to replace itself.
4. ~~**Player audio controls**~~ — **shipped in 1.0.24**, and the estimate was wrong: three of
   the five are mpv options, and the other two are ExoPlayer and Android AudioTrack concepts
   with no tvOS equivalent. They moved to *Forced* rather than being built.
5. **Visual snapshot tests.** Current UI tests prove navigation and focus, not appearance.

### Resolved since this document was written

The **hidden-controls seek overlay** was parked because it failed
`testEveryDirectionBringsTheTransportBack`, a test whose comment records a real bug report. The
invariant turned out to be about the *response*, not the transport: what the report asked for is
that a press with the controls down does something visible, and the split keeps that true —
vertical answers with the transport, horizontal with the readout. The test was renamed to
`testEveryDirectionAnswersWhileTheTransportIsDown` and now asserts both halves, plus a second
test that the readout never takes the remote.

## Verification

- Unit suite at 1.0.27: **427 tests, 0 failures**. UI suite: **9 tests, 0 failures**.
- Test density is ahead of upstream per line — 436 tests over ~42k lines against 983 over 201k —
  so the 1.0.12 plan's "tests too thin" framing was wrong on volume. It was right about
  *placement*: the network clients still carry the least of it, though the five releases since
  1.0.22 have each added a testable policy type in front of one.

Not verified: a physical Apple TV, live Trakt/Simkl/debrid/Nuvio accounts, every third-party
addon, or a side-by-side against a running 0.8.9 installation. In particular **the Dolby Vision
and AV1 advantages claimed above are architectural, not measured.** They remain the largest
untested assertion in this document.
