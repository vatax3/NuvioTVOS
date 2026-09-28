# Functional parity audit — tvOS 1.0.39 vs Android TV 1.1.0-beta.2

Audit date: 2026-08-25, re-derived against 1.0.31 on 2026-08-26, tracked forward since.
Supersedes the audit published with 1.0.15. Twenty releases landed while it was open, so the
table below is the live record and the lists that follow are kept in step with it.

## Scope and evidence

Baseline revisions, exact:

- tvOS `v1.0.31` — commit `19aef3d`, where the table below was derived;
- Android TV `0.8.9-beta` — commit `f40c422ee`, tagged 2026-08-25, the same;
- Android TV `1.0.0` — commit `9f17e8bf4`, tagged 2026-09-19, the current upstream release and
  its first non-beta tag.

Upstream has since tagged `0.8.10-beta` through `1.0.0`; each window is triaged in its own
section below rather than folded into the table, so what was measured against which tree stays
readable.

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
| Nuvio account and sync | Adapted | QR sign-in, device codes, linked devices, per-profile sync. Library and — since 1.0.36 — watch-progress deletions are pushed before each pull; upstream replays a mutation log instead, which is a different shape for the same guarantee. |
| Main navigation | Adapted | Same destinations; sidebar focus behaviour is tvOS-native. |
| Home layouts and hero ✻ | Partial | Classic/Grid/Modern, hero, catalog order, collections, focus-hold expansion, the classic focus gradient, and since 1.0.19 the Continue Watching toggle and the rating-visibility control. No inline focused trailers. |
| Poster options dialog | Parity | Since 1.0.18 a long press on any poster offers library add/remove, watched/unwatched, removal from Continue Watching and the detail screen. Since 1.0.25 the watched row covers series too, walking every aired episode — specials and unaired excluded — with one remote call rather than one per episode. Since 1.0.30 the viewer's own Trakt lists are managed from it, and removing a title from Simkl asks first — that removal calls `sync/history/remove`, so it erases every episode marked watched there. Trakt's removal touches only the watchlist and is not warned about, which is narrower than upstream's generic warning and checked against our own writes. **None of it was reachable until 1.0.32** — see below. |
| Addons | Parity | Install, enable, order, remove, rename and catalog configuration. An addon's own settings are reached by handing off its remote `configure` URL to a phone, which is what upstream's addon config server exists to avoid needing — see *Forced*. |
| Search | Parity for the Stremio surface | Debounced results, recent queries, cancellation, paginated See All. The private discovery service is unavailable. |
| Discover | Parity for addon catalogs | Tail pagination, de-duplication, cancellation. |
| Detail and metadata ✻ | Partial | Metadata, cast, companies, trailers, More like this, comments, parental guidance, and since 1.0.19 `videos[].rating` from addon metadata plus the rating-visibility rules including hide-until-watched. Since 1.0.27 the TMDB franchise-collection row and since 1.0.29 the episode-options overlay — which was the only route to marking a single episode watched without playing it, and there was none. Missing: the ratings tab's IMDb scores. |
| Collections | Parity | Data shape, live folder sources, ordering, sync. `focusGifUrl`/`heroVideoUrl` retained but not rendered. |
| Local library/progress ✻ | Parity | Save/remove, Continue Watching, watched threshold, per-profile persistence, account sync, removal from Continue Watching (1.0.18) and a sort control (1.0.19). **Until 1.0.36 neither a removal nor an un-marking survived an account sync** — see the 1.0.0 triage below. |
| Trakt | Parity | OAuth, progress, list reads, comments, related titles, scrobbling, `sync/watchlist` and `sync/history` writes. Upstream has no `sync/collection`; neither do we. |
| MDBList | Parity for the viewer-visible surface | Was ratings only. Since 1.0.39 a third tracking account: device authorisation, watchlist and static lists in the Library, resume points, watched marks, watchlist writes and scrobbling — and the ratings now come from the account when no API key is set. Upstream's snapshot-and-journal delta engine is not ported; see below. |
| Simkl | Parity | Five list states, remote resume points, scrobbling, `add-to-list`/`history` writes, the anime identity model since 1.0.22, and playback-session deletion since 1.0.26. Snapshot reconciliation does not apply here; see *Differences assumed*. |
| Next Up from trackers ✻ | Parity | Since 1.0.21 a series whose last episode was finished is offered its next one, with the airing rules, both anchor modes and per-series dismissal. Previously the rail held only half-watched episodes, so finishing one removed the series from Home entirely. Since 1.0.25 the episode list is seeded from Continue Watching rather than waiting on a detail-screen visit, bounded to the front of the rail. Since 1.0.29 sibling ids are reconciled where rows are emitted: two addons keying one show differently produced two rows in the rail, each offering a different next episode. Bridged on the IMDb id, which the metadata carries even when the addon's own id is in another namespace. |
| Debrid providers ✻ | Parity | Validation, cache checks, resolution, file choice, cloud libraries for all three, TorBox device sign-in, and since 1.0.20 the stream name/description template language with its editor. The DSL is ported rather than reinvented, so a format written on Android pastes in and produces the same rows. |
| Stream filtering/ranking | Parity | Resolution, quality, HDR/DV, codec, audio, channels, language, group, limits and the sort matrix are consumed. |
| Stream badges | Parity | Computed badges from parsed attributes, plus — since 1.0.23 — imported rule packs: named regular expressions with their own colours and logos, matched against every field an addon supplied. Upstream's file format, so a pack written for Android TV imports unchanged. Three packs held, one applied. |
| Stream selection UI | Adapted | Same information and grouping; density and geometry follow tvOS. |
| On-TV configuration servers | Parity | `LocalConfigServer` since 1.0.20, serving the debrid formatter, and since 1.0.23 badge rules and plugin repositories. The addon case was already covered by handing off the addon's *own* remote `configure` URL. |
| Direct torrent playback ✻ | **Forced** | Upstream ships TorrServer as `libtorrserver.so` and starts it with `ProcessBuilder`. tvOS allows neither subprocesses nor downloaded executables, so the upstream design cannot be ported at all. A linked-in engine is a different project, not a port. |
| Parallel chunked streaming | Missing, and declined | A 1,352-line range downloader: 2–4 HTTP connections each fetching a different byte range, to get past a per-connection throughput ceiling. Its prefetch window, its two pinned side chunks and its 429 backoff all exist to make the parallelism behave — the feature buys throughput and nothing else. Upstream ships it **off by default** with a speed tester to justify enabling it. Not worth 1,352 lines without a measurement showing a real per-connection ceiling; see P2. |
| Plugin runtime | Partial | Repository/install/settings, HTML/CSS helpers, fetch, `getStreams`. CryptoJS covers common hashes/HMAC, PBKDF2 and AES, not the legacy DES family. |
| Player transport | Parity | In-place sources, episodes, tracks, subtitle appearance/delay, audio delay, speed, seven display modes, stream info, skip cards, post-play, still-watching, external hand-off — and, since 1.0.17, the hidden-controls seek readout. Since 1.0.36 a film's end credits carry a skip card of their own, from IntroDB's film route, and a marked post-credits scene is never skipped past. |
| Player failure recovery | Parity at state-machine level | Decoded-first-frame detection, one bounded retry, AVFoundation→mpv fallback, live-playhead resume. |
| Player audio controls | Parity, less two the platform refuses | Output channels, in-player amplification and — since 1.0.24 — persisted amplification, centre-mix level and downmix normalisation. Keep-original-on-downmix and forced optical passthrough cannot exist here as *controls*; see *Forced*, where the second entry also corrects an over-broad claim about passthrough in general. |
| Dolby Vision profile 7 ✻ | **Adapted (in our favour)** | Upstream carries a forked Matroska extractor, a libdovi bridge, an RPU stripper and DV5→DV8.1 conversion — ~13 files — because ExoPlayer cannot play dual-layer DV. libmpv with the vendored `Libdovi`/`Libplacebo` handles it in-engine. Their five DV settings have no counterpart because they have no problem to solve here. **Unverified on hardware.** |
| Subtitles ✻ | Partial | Addon and muxed tracks, auto-language/forced rules, style, delay, SDH stripping, charset detection, CJK fallback, and since 1.0.19 mojibake repair. Ours reverses the double encoding rather than tabulating known sequences, so it also covers the Cyrillic, Greek and Japanese cases upstream's table does not. Still no sync-by-line dialog. |
| External players | Parity | Infuse/VLC/nPlayer/Outplayer hand-off with subtitle forwarding. Skip-segment forwarding is absent. Zidoo monitoring is Android-only. |
| Top Shelf / launcher | Adapted | Publishes Continue Watching with deep links. Android channel fingerprinting is N/A. |
| In-app updater | Parity | Shipped in 1.0.24, on the About screen. Reads the sideloading feed rather than the releases API — the feed is the artefact that has to be right for anyone to install an update at all, so a check that reads it fails loudly when it is wrong. Versions compare numerically, because `1.0.9` sorts after `1.0.23` as a string. It tells and does not install: nothing sideloaded on tvOS can replace itself. |
| Localisation ✻ | Parity for two languages | 231 keys in 2 languages against **2,865 strings in 36 languages**. Since 1.0.31 the whole viewing surface is translated — home, search, discover, library, detail, comments, streams, the player chrome and its overlays, profiles — and `Scripts/check-localisation-keys.sh` fails the build on a key missing from either table, present in only one, or defined twice. What remains is **571 literals in `Sources/Features/Settings`** and 46 scattered elsewhere, most of the latter interpolated. **Closed in 1.0.35.** Settings, every settings *option value*, and first run are translated — 1,116 keys in each table against 231 when this audit opened. The **in-app language picker** shipped with it: `L10n` resolves against a chosen bundle, so switching takes effect in place, where upstream restarts its activity and a tvOS app cannot restart itself. What is left in English is brand names, format specifiers and the HTML the three on-TV configuration pages serve to a phone. Previously recorded as missing: Upstream's `ThemeSettingsScreen` holds a language dialog, stores `locale_tag` in an `app_locale` preference and applies it in `MainActivity.attachBaseContext`. This audit previously treated language as a platform matter — tvOS takes it from the system — which is true of tvOS and beside the point about the app being matched. Found by comparing against a second, independent tvOS port that ported it. |
| Supporter perks | Missing by decision | Monetisation belongs to the official project. |
| Crash/diagnostic reporting ✻ | **Forced** | Sentry DSN, the auth-diagnostic and playback-report endpoints are build-time secrets, blank in public source. |
| Episode IMDb ratings ✻ | **Forced** | Served by `api/shows/{id}/season-ratings` on two hosts read from `IMDB_RATINGS_API_BASE_URL` and `IMDB_TAPFRAME_API_BASE_URL` — both blank in public source, same as `PREMIUMIZE_CLIENT_ID`. We substitute TMDB episode scores. |

## The four lists

### Implemented — same viewer outcome

First run · profiles and PIN · Nuvio account, QR sign-in, device codes, linked devices ·
navigation · the three home layouts and the hero · search and its history · discover with
pagination · collections and live folder sources · Trakt end to end including list writes ·
stream filtering and the ranking matrix · the player transport and its seven display modes ·
player failure recovery · external player hand-off · Top Shelf · parental guidance ·
AniSkip · addon catalog ordering.

Two areas where we are ahead, both consequences of the engine: **Dolby Vision profile 7**
needs no workaround stack, and **AV1** decodes through dav1d where the A15 has no hardware
path and AVFoundation refuses.

### Partial — the feature exists, some behaviour is missing

- ~~**Poster options**~~ — the series watched walk shipped in **1.0.25**, Trakt list
  management and the Simkl removal warning in **1.0.30**. This entry is closed.
- **Home**: no inline trailers. Forced, not missing — see below.
- ~~**Next Up**~~ — the episode cache is seeded from Continue Watching since **1.0.25** and
  sibling ids are reconciled since **1.0.29**. This entry is closed. *The table above carried
  `Partial` for it until 1.0.36; that status was stale from the day this line was written.*
- ~~**Player audio**~~ — three of the five shipped in **1.0.24**; the other two moved to
  *Forced*, having no tvOS equivalent to build.
- **Subtitles**: no sync-by-line dialog.
- **External players**: no skip-segment forwarding.
- **Plugins**: CryptoJS legacy DES family.
- ~~**Localisation**~~ — closed in **1.0.35**. The viewing surface was translated in 1.0.31;
  Settings, every settings *option value* and first run followed, with an in-app language
  picker. **1,161 keys in each of two tables** against the 231 this audit opened with. What is
  left in English is brand names, format specifiers and the HTML the three on-TV configuration
  pages serve to a phone. *This entry read `Partial` with the pre-1.0.35 numbers until 1.0.39;
  the table row above was stale in the same way.* The remaining gap is **languages, not
  coverage**: two against upstream's thirty-six.

### Missing — nothing implemented

- ~~The **poster options dialog**~~ — shipped in 1.0.18; what is left of it is listed under
  *Partial*.
- The **parallel chunked downloader**.
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
- **Keep original audio on downmix**. An ExoPlayer arrangement — its decoder emits a downmix
  while the multichannel track stays selectable — and libmpv has one output chain, not two.
- **Forced optical passthrough**, *as a control*. There is no bitstream API a custom engine can
  drive: `AVAudioContentSource` is an *encoder* settings key (`AVEncoderContentSourceKey`), not a
  playback path. A setting that promises to force passthrough cannot be honoured, so it stays
  out, and the Audio card says passthrough is what the Apple TV's own settings decide.

  **What this entry used to imply is wrong, and it is corrected here.** It read as though a
  bitstream could never reach the receiver from this app. AVPlayer passes EAC3 — including the
  JOC extension Atmos rides on — straight through, and AVPlayer is already our default engine:
  `MPVEngineSupport.requiresMPV` sends only the containers AVFoundation cannot demux to libmpv
  (`mkv`, `avi`, `ts`, `webm` and friends). So an MP4 may well be passing Atmos today, untested,
  while an MKV certainly is not — mpv decodes to PCM, which is where the bitstream is lost.

  The gap is therefore narrower and more specific than "no passthrough": it is **MKV**, which is
  most of what a debrid setup serves. Closing it would mean remuxing the audio to a path AVPlayer
  can play, not replacing the engine. Found by reading a second, independent tvOS port whose whole
  design is FFmpeg-demux plus AVPlayer-playback, precisely to keep the bitstream intact.

  Two things bound how much this matters. It is unverified — nobody has read a receiver's display.
  And Atmos is a height format: on a 5.1 system with no height channels there is nothing for it to
  add that the decoded 5.1 bed does not already carry, and mpv's PCM output of a lossless TrueHD or
  DTS-HD MA track is bit-identical to what the receiver would decode itself.

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

## The long press did not work, and had not since it shipped

Recorded at the top of its own section because it is the most expensive thing this audit missed,
and because of *how* it was missed.

`.onLongPressGesture` was attached to the card's `Button`. On tvOS a focused `Button` consumes a
held Select and fires its **primary** action on release, so the gesture never ran: holding Select
on a poster opened the title, on a Continue Watching card opened the title, on an episode played
the episode, and on a profile chose the profile. The poster options dialog shipped in 1.0.18 and
was unreachable for thirteen releases. The episode options overlay shipped in 1.0.29 and was
unreachable for three.

Nothing in the tree could have caught it. `PosterOptionsPolicyTests` has twenty tests and
`EpisodeOptionsPolicyTests` more; every one of them asks what the dialog *offers*, and none of
them presses anything. The audit read the same way — the feature was in the source, its rows were
correct, its strings were translated, so it was marked Parity.

Fixed in 1.0.32 by `SelectHoldGate`, which is the idiom the player already used for the same class
of problem: a `UILongPressGestureRecognizer` filtered on `UIPress.PressType.select`, hung off the
hosting controller's view, outside the focus graph. It deliberately does **not** cancel the press —
that would break Select everywhere else — so the card that answered the hold drops the press that
follows, and only that card.

The lasting change is `PosterOptionsUITests`: three tests that hold a real Select through
`XCUIRemote` and assert the dialog opens, in both places, **and that the press is not also
delivered as an ordinary one**. That third test is the regression. The lesson generalises past this
bug — a gesture is not covered by testing the policy behind it, and this codebase now has two
features that were only ever proven by driving the remote.

## Upstream moved: 0.8.9-beta → 0.8.12-beta

270 commits, three releases (27 August, 29 August, 1 September). Read from a detached worktree at
the tag, per the procedural fix above. The eight new preference keys are the useful index —
upstream adds a key for anything a viewer can see.

| Upstream | Ours |
|---|---|
| `player_stats_hud_enabled` — live buffer, network, bitrate, CPU, memory, thermal | **Ported in 1.0.33.** Sampling rewritten: upstream reads `/proc/self/stat` and a Linux paging counter, neither of which exists here, so CPU and memory come from `task_info` and the paging row is dropped rather than approximated. Thermal is `ProcessInfo.thermalState`, four levels, against upstream's 0–1 headroom float — mapped, not faked. |
| `post_play_recommendations_enabled`, `post_play_movie_threshold_percent` — recommendations at the end of a *film* | **Ported in 1.0.35**, thresholds kept exactly. Two departures: the cards are not drawn behind an autoplaying trailer, because tvOS has no supported YouTube path; and choosing one opens the title rather than starting it, because a recommendation has no chosen stream. |
| `episode_options_overlay_style` — appearance options for the episode overlay | **Ported in 1.0.35**: none, artwork, blur. The still sits *under* the scrim rather than replacing it — some episode stills are nearly white and the dialog has to stay readable. |
| `update_channel` — stable and beta channels | Open. Our updater reads the sideloading feed, which has one channel; this needs a second feed or a flag in the existing one before the setting means anything. |
| `confirm_exit_enabled` — "Full exit on close" | **Forced.** It terminates the process to free memory and requires a double Back to confirm. tvOS neither lets an app kill itself nor wants it to; the system reclaims a suspended app on its own. |
| Custom launcher icon and banner | **Forced.** A tvOS app icon is a build-time asset in the bundle, not something an app rewrites at runtime. |
| Six-character login codes; self-hosted discovery endpoint | **Forced**, same reason as every other backend contract: blank in public source. |
| Simkl for anime id resolution in skip-intro, replacing ARM | **Ported in 1.0.35**, and it was a real defect here too. ARM returns one MAL id per season as a flat array indexed by season number; anime and TVDB numbering disagree on most long shows, so the index lands on the wrong title *and* the wrong episode. Upstream removed ARM; ours keeps it as a fallback, because the Simkl client id is the viewer's here rather than shipped. |
| HLS segment 404 fallback; mpv stuck on last frame | Player robustness, both plausibly ours too. Neither reproduced here yet, so neither is claimed fixed. |
| Player strings read from the app language, not the system one | **Closed in 1.0.35** with the picker itself. `L10n` resolves against a chosen bundle rather than `Bundle.main`, so there is one app language and the player reads it like everything else. |

## Upstream moved again: 0.8.12-beta → 1.0.0

320 commits and seven releases in eighteen days (4–19 September), ending in upstream's first
non-beta tag. Read from a detached worktree at `1.0.0`, per the procedural fix above. Seven new
preference keys, but the keys understate this window: most of its weight is in a feature that
needed none, and in a sync fix that only added bookkeeping keys.

| Upstream | Ours |
|---|---|
| IntroDB **film** segments — `is_movie=true`, end credits and post-credits scene, plus a *Skip to Post-Credits* label | **Ported in 1.0.36**, and it closes a gap we shipped ourselves last release. Films had no marks at all: `loadSkipSegmentsIfNeeded` required an episode number, so it returned early on every film. |
| Post-play film recommendations fired from the credits instead of a percentage | **Ported in 1.0.36.** This replaces what 1.0.35 shipped. Credits run from ninety seconds to eight minutes, so a flat 90% lands deep inside them on a long film and before the last scene on a short one. A marked post-credits scene now holds the card until the scene has *played*. |
| Post-credits detection extended to series outros | **Declined, deliberately.** Their series route cannot return an explicit `post_credits` mark, so on series the change is a five-second-tail heuristic and nothing else — and almost every episode has more than five seconds of black, a studio card or a next-episode preview after its ending. Ported for films, where a tail past the credits does mean something. |
| `progress_upserts` / `progress_deletes` / `watched_upserts` / `watched_deletes` — an offline queue of watch-state mutations | **The matching defect was ours, and worse.** See below. Fixed in 1.0.36; the queue itself is not ported — our sync pushes deletions and reconciles by timestamp rather than replaying a mutation log. |
| `custom_theme_colors` — a three-colour custom theme with a hex dialog and colour picker | Open. We ship seven preset palettes and AMOLED; this adds a viewer-defined one. A colour picker driven by a remote is the bulk of the work, not the palette derivation. |
| `startup_splash_enabled` — a branded splash gated by destination | Open, and small. Worth doing with the icon work rather than alone. |
| `PlaybackAvailability` — grey out *Play* when no enabled addon or scraper can serve a stream for that id | **Ported in 1.0.39.** Reads `resources`/`idPrefixes` off installed addons, which we already parsed. |
| `mpv_hi10p_gnext_software_fallback_enabled` — force software decoding for 10-bit H.264 | Open, and **unverified**. Their heuristic matches `hi10`/`10bit` against the stream *name*, which is guesswork; VideoToolbox also refuses H.264 High 10, but mpv's `hwdec` fallback may already cover it in-engine. Needs a Hi10p file on the real device before anything is added. |
| Letterbox left transparent so HDR bars stay true black | Open, **unverified**, and hardware-only. Their fix is for an ExoPlayer SurfaceView; ours is an mpv Metal layer, so the question transfers but the answer does not. |
| Stream dedup no longer collapsing two differently-named streams on one URL | **N/A.** We do not dedup streams at all — the dedup in `StreamsView` is for subtitle tracks. Their fix repairs machinery we never built. |
| 4:3 1080p no longer matched down to 720p | **N/A.** We hand tvOS a `CMFormatDescription` with the real dimensions and let `AVDisplayManager` choose; their bug is in their own resolution bucketing. |
| FFmpeg downmix distortion and buffer growth | **N/A.** Their own JNI FFmpeg decoder extension for ExoPlayer. mpv does its own downmix, and normalisation shipped in 1.0.24. |
| A watched tick on episodes in the in-player panel | **Ported in 1.0.36**, adapted: their tick sits on the still and ours has no still, so the leading icon carries three states instead of one. |
| Turning subtitles off by long-pressing the selected track | **N/A.** Their track list has no *Off* row and ours does. |
| RTL layout and text direction, ~25 commits | **N/A** while the app ships English and French. Becomes real the day a RTL table is added. |
| Search suggestions and catalog paging tied to the search run | Open. Worth a read on its own; roughly a dozen focus fixes ride along with it. |
| Custom theme previews, recomposition profiling, moov caching, chunk eviction, memory budget | **N/A.** Compose and ExoPlayer internals, and most of the memory work serves the parallel chunked downloader we declined. |

### The defect this window exposed in our tree

Upstream's four new sync keys are bookkeeping for an offline mutation queue. Reading why they
needed it pointed straight at `NuvioSyncService.syncWatchProgress`, which **had no deletion path
at all** — while `syncLibrary`, six lines above it, has one, and carries a comment explaining
exactly the hazard: *"Deletions go first: otherwise the pull would hand back the rows this device
removed and they would be re-adopted before the delete was ever sent."*

Watch progress never got that treatment, and two viewer actions delete a progress row, not one:

- **removing a title from Continue Watching**, and
- **marking a film or an episode unwatched** — our watched state *is* a progress row at full
  duration, so un-marking is `clearProgress`.

For anyone signed into a Nuvio account with sync on, both were reverted by the next sync: the
pull found no local row, called `adoptProgress`, and put it back. Silently, and with no way to
tell it had happened other than watching the title reappear. The account even exposes the RPC —
`sync_delete_watch_progress` — we simply never called it.

It is also a convergence worth recording. The poster-options dialog that performs both actions
was unreachable from 1.0.18 to 1.0.32; the release that finally made it reachable is the release
that started feeding this bug. Twenty policy tests covered the dialog's *decisions* and none of
them pressed anything or synced anything.

Fixed in 1.0.36 by mirroring the library's queue: `pendingProgressDeletions`, pushed before the
pull, with `adoptProgress` refusing a queued key and any fresh write cancelling it. The queue is
stored durably rather than in the purgeable cache the library's queue uses — a purged deletion
queue resurrects exactly the rows it was holding. Flipping the library's own queue needs a
migration read from its current location and is left as its own change.

## Three reports from a viewer, and what they were really about

Filed against our tree on 2026-09-17, all three by the same person within fifteen minutes. None
was a parity gap; all three were ours. Fixed in 1.0.37.

### "Unable to change + and - settings"

> "Pressing the center button does nothing and left/right move around the menus."

`SettingsStepperRow` handed its two step buttons to `SettingsRow` as a trailing accessory, and
`SettingsRow` is a `Button` — **on tvOS the contents of a button's label are not focusable**. So
neither step button could ever take the remote, and Select landed on the row's own `action: {}`.
Every stepper in the app was inert: poster width, height, corner radius, the focus-expansion
delay, and the playback, debrid and tracking values built on the decimal variant. **23 call sites
across five files, shipped inert since the settings screens were written.**

The fix takes the row content out of the button — `SettingsRowContent`, which `SettingsRow` now
wraps and the steppers use bare. `SettingsPriorityListRow` already had the correct shape, which is
what the steppers should have copied.

This is the same lesson as the poster long press in 1.0.32, and it went unlearnt for five
releases: **whether a nested control is reachable is a focus-engine question that exists only at
runtime.** `SettingsWiringTests` checks that every setting is bound to a store. It cannot check
that anything can be pressed. `SettingsStepperUITests` now does, with a real remote.

### "Turning off show labels breaks catalogs"

> "As soon as the setting is turned off I can only see my watchlist, all the catalogs are missing."

Not the labels. `ModernHomeContent.rowsViewportHeight` sizes the rows region from one poster row
and subtracted a 152-point label allowance when labels were off — while the row actually at the
top, Continue Watching, carries its own title and progress line and does not shrink with that
setting. The first row then filled the viewport, the `LazyVStack` below had no room to realise the
next one, and because nothing was realised **there was nothing for focus to move to.** Every
catalog rail existed and none could be reached.

The allowance is now unconditional: it reserves for the tallest row the viewport can contain, not
for the one configuration of the first row. `PosterLabelsUITests` walks Down from the rail in all
four combinations of the two settings that shrink the viewport, and was checked to fail with the
old arithmetic restored.

Worth recording separately: the first version of that test asserted **presence** — it counted
posters and passed while the screen was broken, because the rails were in the tree and simply
unreachable. It also drove the setting with a plain `-layout.poster_labels_enabled 0` launch
argument, which arrives as a string that `PreferenceStore`'s `as? Bool` rejects, so both arms ran
with labels on and the test proved nothing twice over. Hence `SettingsHarness`, which writes real
typed values, and an assertion on reachability rather than on existence.

### "Keeps adding Cinemeta and Open Subtitles"

> "…even after removing them in Nuvio, it also re-enables them if disabled."

Two causes, independently sufficient.

**The addon list lived only in a purgeable cache.** `addons.json` carries the manifests, so it is
a network cache and sits in Caches — correct for a manifest, wrong for everything else in the same
file. When tvOS reclaimed it, `AddonStore.init` found nothing and seeded the two defaults over
whatever the viewer had chosen: installs, removals, renames and disables, all replaced at once.
Split in 1.0.37: `addon-choices.json` is durable and decides *which* addons exist; the cache only
supplies their manifests, and a purge now costs a refresh.

**And `syncAddons` reinstalled what the viewer had just removed.** It pulls the account's list,
installs anything missing locally, then pushes the whole local list — so the pull undid the
removal a moment before the push would have carried it, and the addon was pushed back up. A
removal could not propagate from any device; only an addition could. Same shape as the watch
progress defect in 1.0.36 and the library one before it, now with the same remedy: a queue
consulted by the pull and cleared by the push. No delete RPC is needed — `sync_push_addons`
replaces the account's list, so the push *is* the deletion once the pull stops resurrecting it.

**This is the third deletion-loses-to-pull bug in three releases.** The library had the fix and a
comment explaining the hazard; watch progress and addons were each written without it. The pattern
is now used in all three places in `NuvioSyncService`, and anything added to that file should be
read against it.

## The player, reviewed against the platform and against four more reports

Prompted by a viewer's reports in September 2026 and a review of the engine against Infuse, the
official apps and the platform's own limits. Shipped in 1.0.38.

### Display matching was off by default, and that was a parity bug rather than parity

`frameRateMatchingMode` defaulted to `.off`. On Apple TV the criteria handed to `AVDisplayManager`
are the **only** way the system learns what is about to play — its frame rate *and* its dynamic
range, which `AVDisplayCriteria` carries together in one object. Off meant we told it nothing:
23.976 fps film ran at whatever the panel was already doing, and no HDR mode was ever requested.

Worse, the AVPlayer path passed that same `off` straight into
`appliesPreferredDisplayCriteriaAutomatically`, which AVKit sets to `true` by itself. **The default
actively switched off something Apple gives for free.**

Android's equivalent is off by default too, which is where the value came from. Copying the value
rather than the intent is what made this a defect: the mechanism it gates is not the same one.

Two things were checked in the SDK before changing anything. `preferredDisplayCriteria` is
documented as *"only honored when user settings allow it"*, so sending criteria is safe whatever
the viewer has set — there is no case where this default does harm. And the API exposes **no way
to separate frame rate from dynamic range**: the two switches in Apple TV Settings are applied by
tvOS, not by us, and `isDisplayCriteriaMatchingEnabled` answers only whether matching is allowed
at all. So the plan to split our setting in two was wrong and was dropped; the fix is to stop
suppressing the one we have. Default now `.start` — matching on the way in, leaving the panel
there, which avoids a second mode change and a second black frame on every exit.

### A diagnostic, because the HDR complaint is not otherwise observable

A viewer reported Dolby Vision and HDR looking wrong — *"too dark or too bright"*, varying by
scene, **on both engines**, and still wrong with frame-rate matching enabled. That last detail
rules out the default above as the whole story.

The remaining suspect is ours and is in the mpv options: `tone-mapping=auto` with
`hdr-compute-peak=yes`. If MoltenVK's swapchain does not advertise HDR, libplacebo tone-maps PQ to
SDR — and `hdr-compute-peak` measures each frame's peak to adapt the curve, which is exactly a
brightness that changes with the scene. On an Apple TV pinned to Dolby Vision output the result is
then converted a second time. That is a hypothesis with the right shape, and **it must not be
acted on blind**: the wrong values here degrade the picture as surely as the current ones.

So 1.0.38 ships the measurement instead of a guess. The player's stream information now shows the
source colorimetry against `video-target-params` — what libplacebo is actually presenting — plus
whether tvOS is allowing display matching at all. Equal ranges mean the picture reaches the panel
as authored; different ones mean it is being converted on the way, and the report becomes a fact.

### Subtitles landed on whatever the file listed first

Reported as always selecting Finnish, one row above a French forced track the file itself marked
as default. Two causes:

- `subtitle_preferred_language` defaulted to empty, so **no `slang` list ever reached mpv**;
- and we had overridden `subs-fallback` to `yes`, which widens the fallback to *any* track when
  the language preference finds nothing. mpv's own default, `default`, falls back only to a track
  the file marked as default — which is the French one.

Underneath both: **"Device language" was offered for audio and not for subtitles.** The code to
resolve the placeholder already existed; the choice simply was not in the picker, so the one thing
the viewer wanted could not be selected. Now offered, and the default. An explicit "None" still
works — it stores `""`, which is a value and not an absence.

`subtitle_use_forced_subtitles` also reached the engine for the first time, as
`subs-fallback-forced`. mpv's `yes` is exactly what that setting means: a forced track when the
audio is already in the subtitle language, because a full track would repeat audible dialogue.

One trap worth recording, because it was nearly shipped: `device` is a placeholder, not a language
tag. `SubtitleSelector.autoSelection` was being handed the raw stored value, so the new default
would have matched no track at all — the same symptom, a different cause. It takes the resolved
list now, and a test pins it.

### Two reports that were investigated and not reproduced

Both are recorded rather than quietly dropped.

**"The player controls disappear while you are using them."** Every restart path is already
covered: button actions, focus movement across the transport (`onChange(of: controlFocus)`), and
scrubbing, which calls `wakeControls` precisely so the bar *"does not vanish mid-scrub"*. And our
timeout is **five** seconds against upstream's **three**, so it is already more generous than
parity. No mechanism found; the value is not being changed on a hunch. Needs a reproduction naming
the control and the gesture.

**"Search bar text is not vertically centred."** Measured from a screenshot rather than judged:
cap tops at row 71, baseline at 119, so the optical centre is 95 against a capsule centre of 93.5
— **one and a half pixels** on a 157-pixel field. Not reproduced in the default state. The capture
harness was removed rather than left behind as a test that asserts nothing.

### What the review settled about the engine itself

The platform ceiling applies to everyone and is worth stating once: **the Apple TV has no
bitstream passthrough.** Multichannel leaves as LPCM and Atmos is delivered as Dolby MAT over
LPCM, so TrueHD Atmos and DTS:X cannot reach a receiver intact from any app — Infuse included,
which decodes them to LPCM and says so. The only Atmos path is E-AC-3 with JOC, and AVFoundation
takes the MAT route only when the `dec3` box carries the TS 103 420 type-A extension.

Our gap is therefore narrow and specific: **E-AC-3 JOC inside an MKV**, which routes to mpv and is
decoded to PCM, losing the height objects. The same stream in an MP4 goes to AVPlayer and should
produce Atmos. Closing it means remuxing to fMP4 for AVPlayer rather than replacing the engine —
the architecture Aether's `PrismCore` publishes, which rebuilds the `dec3` box that FFmpeg's own
muxer omits. Not attempted here; recorded as a decision, and moot on a 5.1 system, where Atmos has
no height channels to place.

Against that, two places the engine is ahead of every tvOS alternative: **AV1**, which dav1d
decodes where the A15 has no hardware path and AVFoundation refuses, and **Dolby Vision profile
7**, handled in-engine where ExoPlayer needs a thirteen-file workaround stack. Both remain
unverified on hardware.

## Findings this pass turned up in our own tree

Both are **closed in 1.0.28**, and one of them was half wrong.

**Five settings enums defined and never referenced** — the shape of parity without the substance.
Four are gone: `DecoderPriority` and `LibassRenderType` are ExoPlayer questions (mpv *is* libass,
and hardware decoding is `hwdec`), `DolbyVision7HandlingMode` exists to work around an engine that
cannot play dual-layer DV, and `VodCacheSizeMode` is part of the buffer-tuning surface given up
with ExoPlayer. `FocusedPosterTrailerTarget` stays, commented: it is the only one of the five that
describes something we want and the platform refuses.

**Two preference keys said to diverge from Android's.** Only one did. `hero_catalog_keys` is
correct — upstream carries both `hero_catalog_key` and `hero_catalog_keys`, and the plural is the
live one; the singular is what it migrates from. This finding named the wrong half of that pair.

`remember_last_profile` was a real divergence against upstream's `remember_last_profile_enabled`,
and renaming it turned up something worse underneath: the setting had **two defaults**.
`SettingsStore` defaulted it on and `ProfileStore` — which reads `UserDefaults` directly, because
the settings graph is built per profile and does not exist that early in launch — defaulted it
off. A fresh install showed the switch on and went to "Who's watching?" every launch anyway. Key
and default now live once, in `RememberLastProfile`, which reads the old name too so nobody's
choice is lost.

## Priorities

### P0 — decisions, not code

1. ~~**Direct torrent**: declare debrid a requirement, or scope a linked-in engine as its own
   project~~ — **decided: debrid is required**, stated in the README. Upstream starts TorrServer
   as a subprocess, which tvOS forbids outright, so there was never a port to choose between.
   A linked-in engine would be a separate project and is not planned. This line is closed.
2. **Backend contracts** remain unavailable; keep those controls absent.

### P1 — real gaps, buildable here, ordered by value per line

**This tier is closed.** The last two threads shut in 1.0.29 and 1.0.30. Each entry keeps its
original wording and the release that answered it, because what this tier is worth recording now
is which guesses about effort were right — and several were not.

1. ~~**Poster options dialog**~~ — **shipped in 1.0.18**, extended through **1.0.30**. Reaches
   library and watched state from Home, Discover, Search and Detail at once, and is the only
   route to removing a Continue Watching item.
2. ~~**`videos[].rating` from addon metadata**~~ — **shipped in 1.0.19.**
3. ~~**Mojibake repair for subtitles**~~ — **shipped in 1.0.19**, by inverting the double
   encoding rather than tabulating sequences.
4. ~~**Rating visibility, Continue Watching toggle, addon renaming, library sort**~~ —
   **shipped in 1.0.19.**
5. ~~**Debrid formatter**, with the local HTTP server the editors need~~ — **shipped in
   1.0.20.** Stream badge rules and repository config followed in **1.0.23**, a page each on
   the same server.
6. ~~**Simkl anime identity model**~~ — **shipped in 1.0.22**, and `delete-playback` in
   **1.0.26**: removing a series from Continue Watching left Simkl's playback session standing,
   so the next sync put the row straight back. Snapshot reconciliation stays out by decision —
   our list screens fetch when they appear, so there is no snapshot to reconcile.
7. ~~**Next Up projection and dismissal**~~ — **shipped in 1.0.21**, and the episode cache is
   seeded from Continue Watching since **1.0.25**, bounded to the front of the rail.
   Sibling-id reconciliation followed in **1.0.29**: a series watched under one addon's id and
   listed under another's was two rows to us and one show to the viewer. Bridged on the IMDb
   id, which the metadata carries even when the addon keys the show in its own namespace.

### P2 — larger, or lower value

1. **Parallel chunked downloader.** 1,352 lines upstream, and the earlier note here was wrong
   twice. The non-faststart MP4 path is **not** built on it — `FrameRateUtils.kt` never
   references `ParallelRangeDataSource`, and what that path does is fetch a file's head and tail
   to find the `moov` atom so ExoPlayer can read the frame rate before playback. mpv gives us
   `container-fps` once the file is open, so we never needed it. And mpv's cache cannot close
   this gap: a cache smooths variability, it does not raise a ceiling. If a single connection is
   capped below the bitrate, only more connections help. FFmpeg's HTTP is single-connection with
   no option to change that, so the shape here would be a local proxy mpv streams from.
   Still gated on measuring a real per-connection ceiling on actual hardware.
2. ~~**Localisation.**~~ — **closed in 1.0.35.** Both tables now carry 1,161 keys and the
   build guard fails on any key missing from either, so the coverage cannot quietly rot. What
   is genuinely still open is *more languages*, which is translation work rather than
   engineering: two against upstream's thirty-six.
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

## Upstream moved a third time: 1.0.0 → 1.1.0-beta.2

218 commits over six days (19–25 September), 298 files, +21,859 lines. Read from a detached
worktree at the tag, per the procedural fix above — the local snapshot was still checked out at
`0.8.9-beta`, which made a first pass read the window as deletions.

**Three quarters of the volume is N/A here.** Around twenty commits are RTL layout and text
direction, which stays N/A while the app ships English and French. The translations are theirs.
And roughly fifteen are Compose focus restoration on the detail screen — season chips, the
remembered studio logo, a Crossfade remounting — which our SwiftUI focus model does not share.

What is left is short:

| Upstream | Ours |
|---|---|
| **MDBList as a third tracking account** — device authorisation, incremental watched and playback sync, a cached progress projection, scrobbling, watchlist and static lists in the Library, account management on the Tracking page, and ratings through the connected account with the API key as an override. ~35 files, the largest single addition of the window. | **Ported in 1.0.39**, and deliberately not line for line — see below. |
| **Custom poster URL** (RPDB and relatives) — a URL pattern with placeholder tokens plus per-screen toggles | **Ported in 1.0.39.** Never audited before because it did not exist before this window. |
| **`PlaybackAvailability`** — grey out *Play* when nothing installed can serve a stream | **Ported in 1.0.39.** Was already the top of our own open list against 1.0.0. |
| **Simkl as a third *More like this* source** | **Ported in 1.0.39.** The client was already here; it is a branch in `loadRelated`. |
| *"Prefer in-progress resume over furthest next-to-watch"* | **The same defect was ours.** Ported in 1.0.39 as `NextUpAnchor` — see below. |
| A disk **VOD cache** in the player, plus buffer retuning and three migration flags | Open, and probably moot: mpv has `cache-on-disk` and `demuxer-max-bytes`. The question transfers, the mechanism is already here. Worth a read before anything is built. |
| Grouping streams by plugin repository | Open, and small. |
| Custom theme previews, recomposition profiling, moov caching, chunk eviction | **N/A.** Compose and ExoPlayer internals. |

### The resume anchor, which was our defect too

`next_up_from_furthest_episode` anchors the *Play* button on the deepest episode the viewer has
touched. That is the right answer for the case the preference exists for — a rewatch of an early
episode should not drag a series backwards — and the wrong one the moment that episode is
finished:

> Watch S05E01 to the end, then start S02E03 and stop halfway. The furthest anchor is still
> S05E01, it is watched, so *Play* offers S05E02 — and the episode actually in progress cannot be
> reached from the button at all.

Fixed by letting an in-progress episode outrank the positional anchor when it is at least as
recent. Both halves matter: recency alone would break the rewatch case the preference was written
for, and position alone is the bug. `NextUpAnchor`, nine tests.

### What was left out of MDBList, and why

Upstream holds a durable snapshot of watched rows, resume points and list contents, and keeps it
current by polling `/sync/last_activities` for a watermark, replaying `/sync/journal` deltas
against it, and falling back to a full resync when the journal answers 409. That is most of the
thirty-five files.

**It serves their cached-snapshot design, and we do not have one.** Our Trakt and Simkl screens
fetch when they appear — the decision already recorded under *Differences assumed* — so there is
no snapshot for a journal to be applied to, and the delta engine would be bookkeeping for a cache
we do not keep. Everything a viewer can see is ported: the account, the lists, the resume points,
the watched marks, the writes and the scrobble.

One distribution difference, not a capability one. Upstream reads its client id from
`BuildConfig.MDBLIST_CLIENT_ID`, blank in public source — and their own `local.example.properties`
calls it a *public* client id. So the viewer registers one at mdblist.com and pastes it next to the
Trakt and Simkl ids, which is the same arrangement as Premiumize and Trakt itself.

Two things this window's MDBList work settled that are worth recording:

- **A pasted API key beats a connected account for ratings.** It reads backwards until you take
  the viewer's side: both work, and the key is the one they went and fetched on purpose. Silently
  preferring the account would make the field they filled in do nothing. Before this, connecting an
  account did not help the ratings row at all.
- **Removing a title from MDBList warns about nothing.** `…/items/remove` is a list operation; the
  watched history is `/sync/history/remove`, a different endpoint this call does not reach. Same
  answer as Trakt, the opposite of Simkl — checked against our own writes rather than assumed from
  the fact that it is a tracker.

### The custom poster URL, and the one thing that makes it a type

The feature is artwork from a rating-overlay service in place of the addon's own, and the whole of
it is substituting ids into a URL. What makes it more than `String.replacing` is that **a pattern
this title cannot satisfy has to produce nothing**: a title with no TMDB id must keep the addon's
poster rather than request `…/movie-.jpg`, 404, and draw a placeholder where a poster used to be.
Hence required `{tmdb_id}`, optional `{tmdb_id?}`, and `{imdb_id|tmdb_id}` for a service declaring
which namespaces it accepts.

Typed on a phone through `LocalConfigServer` — its fourth page, and the clearest case for that
hand-off yet, since the remote's keyboard has no `{`. The page shows the pattern resolved against
two real titles, one of which deliberately fails, because on the television an unresolvable
pattern is indistinguishable from one being ignored.

Two adaptations. It is applied **in the card** rather than where lists are produced, so a change
takes effect at once; that is free in the common case because the resolver returns on an empty
pattern before looking at anything. And `RemoteImage` gained a fallback URL, standing in for
upstream's Coil interceptor: these services answer for a subset of titles, and without it a
configured pattern means placeholder cards wherever they do not.

Discover and *See All* follow Home's key. Upstream has none for them, but they draw the same
catalog rows, and a viewer seeing rated posters on one and not the other would read that as a bug.

### Greying out *Play*, and the trap in it

`PlaybackAvailability` reads the gate a stream request already passes — `Addon.handles` — ahead of
time, plus the scrapers, which answer for a type rather than an id. Two properties carry more
weight than the rule. `isLoaded` exists so an empty read is never mistaken for a negative one: our
`AddonStore` always produces a list, two defaults at worst, so an empty state arrives as records
whose manifest cache was purged. And **the hero button is disabled while the episode cards are
not** — a disabled card row would be unfocusable, which is exactly how 1.0.37 lost every catalog.
The cards gate the action instead, and the banner above them says why.

`Video` gained `hasEmbeddedStreams` along the way: some addons never implement `/stream` and hang
the links off the meta entry. Judged by manifests alone those titles are unplayable, and they play.

## Verification

- Unit suite at 1.0.39: **631 tests, 0 failures**. UI suite: **14 tests, 0 failures**.
- Test density is ahead of upstream per line — 645 tests over ~48k lines against 983 over 201k —
  so the 1.0.12 plan's "tests too thin" framing was wrong on volume. It was right about
  *placement*: the network clients still carry the least of it, though every release since
  1.0.22 has added a testable policy type in front of one.
- Three build guards now fail on structural drift rather than leaving it to review: a declared
  setting with no reader, a localisation key missing from either table, and a release whose
  version never reached the sideloading feed.

Not verified: a physical Apple TV, live Trakt/Simkl/debrid/Nuvio accounts, every third-party
addon, or a side-by-side against a running 0.8.9 installation. In particular **the Dolby Vision
and AV1 advantages claimed above are architectural, not measured.** They remain the largest
untested assertion in this document.
