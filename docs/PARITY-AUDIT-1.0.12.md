# Functional parity audit — tvOS 1.0.12 vs Android TV 0.8.7-beta

Audit date: 2026-08-23.

## Scope and evidence

The baseline revisions are exact rather than inferred from screenshots:

- tvOS `v1.0.12`: the release state carrying this document;
- Android TV `0.8.7-beta`: commit `91c1355224edfbac796a6b63cb43a999d71d3ce3`.

The comparison covered screen/routes, persisted preferences and their consumers, protocol and
API clients, tracking mutations, stream resolution, player state transitions, system
integrations and test coverage. It deliberately does not call a Compose component missing just
because SwiftUI expresses the same screen differently.

The second column preserves the published `1.0.11` baseline; the third records what `1.0.12`
changes. This makes the release delta reviewable instead of silently replacing the earlier
assessment.

Legend: **Parity** = same viewer outcome; **Adapted** = intentional tvOS implementation;
**Partial** = meaningful behavior is missing; **Missing** = no implementation; **N/A** = Android
platform detail with no useful tvOS counterpart.

## Result by product area

| Area | 1.0.11 baseline | 1.0.12 release | Remaining difference |
|---|---|---|---|
| First run | Parity | Parity | Three Android screens are one three-step tvOS flow; Back remains inside setup. |
| Profiles | Parity | Parity | Avatars/backgrounds, selection at launch, create/edit/delete, PIN and restricted profiles are present. |
| Nuvio account and multi-device sync | Adapted | Adapted | QR sign-in, device codes, linked devices and per-profile sync exist, but an official hosted account still requires the upstream backend URL/key. |
| Main navigation | Adapted | Adapted | Same destinations and placement options; Liquid Glass/sidebar focus behavior is intentionally tvOS-native. |
| Home layouts and hero | Parity | Parity | Classic/Grid/Modern, hero, catalog order, collections and focus-hold expansion exist. Inline focused YouTube trailers do not. |
| Addons | Adapted | Adapted | Install/enable/order/remove and catalog configuration exist; configuration is handed to a phone by QR because tvOS has no web view. |
| Search | Partial | Parity for the Stremio surface | Added debounced incremental results, persisted recent queries, stale-request cancellation and paginated See All. The private official discovery service is still unavailable. |
| Discover | Partial | Parity for addon catalogs | Added tail pagination, de-duplication and cancellation across catalog/genre changes. |
| Detail and metadata | Partial | Partial | Metadata, cast, companies, trailers, recommendations, comments and parental guidance exist. Episode IMDb ratings and the 0.8.7 home/detail rating-visibility controls do not. |
| Collections | Parity | Parity | Data shape, live folder sources, ordering and sync match. Per-card `focusGifUrl` and `heroVideoUrl` are retained in data but intentionally not rendered. |
| Local library/progress | Parity | Parity | Save/remove, Continue Watching, watched threshold, per-profile persistence and account sync exist. |
| Trakt reads and scrobbling | Partial | Partial | OAuth, progress, collection/watchlist reads, comments, related titles and scrobbling exist. Remote collection/watchlist membership and watched-history writes are not routed from the detail/episode UI. |
| Simkl | Minimal/Partial | Partial | Added all five list states, remote resume points and start/pause/stop scrobbling. Still missing remote list/history mutations, playback-session deletion, snapshot reconciliation and Android's complete anime identity/season mapping. |
| Next Up from trackers | Partial | Partial | Local and imported resume state can seed playback. Android's full watched-series projection, sibling-id reconciliation and Simkl Next Up model are not reproduced. |
| Debrid providers | Partial | Partial | Real-Debrid, Premiumize and TorBox validation, cache checks, resolution, file choice and cloud libraries exist. Android's device-code authorization UX and QR debrid formatter/template editor are absent. |
| Stream filtering/ranking | Parity | Parity | Required/excluded/preferred resolution, quality, HDR/DV, codec, audio, channels, language, group, limits and sort matrix are consumed. |
| Stream selection UI | Adapted | Adapted | Same information and refresh/filter/source grouping; card density, focus and overlay geometry follow tvOS. It is not pixel-identical to Compose. |
| Direct torrent playback | Missing | Missing | Android bundles a torrent engine and progress overlay. tvOS currently requires an HTTP source or debrid resolution. |
| Plugin runtime | Partial | Partial | Repository/install/settings, HTML/CSS helpers, fetch and the usual `getStreams` contract exist. CryptoJS compatibility covers common hashes/HMAC, PBKDF2 and AES, not the complete npm package or legacy DES family. |
| Player transport | Adapted/Parity | Adapted/Parity | In-place sources, episodes, tracks, subtitle appearance/delay, audio delay, speed, seven display modes, stream info, skip cards, post-play, still-watching and external-player hand-off exist. |
| Player failure recovery | Partial | Parity at state-machine level | Added decoded-first-frame detection, one bounded startup/stall retry, AVFoundation-to-mpv fallback and live-playhead resume without leaving the player. |
| Player parity gaps | Partial | Partial | No subtitle sync-by-line dialog, hidden-controls seek overlay, torrent progress or upstream playback-report upload. Real Apple TV validation remains mandatory for AFR/HDR, CJK fonts and audio routes. |
| Subtitles | Adapted/Parity | Adapted/Parity | Addon and muxed tracks, auto-language/forced rules, style, delay, SDH stripping, charset detection and CJK font fallback exist. Rendering uses libass/mpv or the tvOS sidecar overlay rather than ExoPlayer. |
| External players | Adapted/Parity | Adapted/Parity | Infuse/VLC/nPlayer/Outplayer hand-off exists; subtitle forwarding is supported where the target accepts it. Android-only Zidoo monitoring is N/A. |
| Top Shelf / launcher | Adapted | Adapted | Top Shelf publishes local Continue Watching with detail/play deep links. Android preview-channel fingerprinting and launcher jobs are N/A; remote-only Next Up does not yet enrich Top Shelf independently. |
| Supporter perks | Missing by decision | Missing by decision | Monetisation/product ownership belongs to the official project. |
| Diagnostics/backend reports | Partial | Partial | Local verbose/network diagnostics exist. Crash/playback reports and the official discovery endpoint require contracts/credentials not shipped in public source. |
| Localization | Partial | Partial | The tvOS app has its own resources; it does not yet mirror the complete Android string catalog. |

## Highest-priority remaining work

### P0 — architecture/product blockers

1. **Choose a direct-torrent strategy.** Either ship and maintain a tvOS-compatible torrent
   engine, explicitly make debrid a requirement, or integrate an external LAN service. This is
   the largest functional difference and cannot be solved in the view layer.
2. **Obtain/document the official backend contracts** for discovery and playback reports, or keep
   those controls absent. Guessing endpoint shapes would create silent data loss or misleading UI.

### P1 — features that can be implemented in this repository

1. Route detail-library and watched/progress mutations through the selected tracking provider:
   Trakt collection/watchlist/history and Simkl status/history/delete-playback.
2. Port Android's Simkl snapshot cache/reconciliation and anime identity model, including MAL,
   Kitsu, AniDB/AniList, Simkl IDs and season-vs-absolute episode coordinates.
3. Validate the player on physical Apple TV hardware with a matrix of HLS/MKV, AAC/E-AC3,
   Bluetooth/HDMI route changes, ASS/SRT/WebVTT, RTL and CJK. Simulator success is insufficient
   evidence for display matching, hardware decode and route timing.

### P2 — visible parity polish

1. Add `home_imdb_ratings_visibility` and `detail_imdb_ratings_visibility`, including the episode
   rating source needed for “hide unwatched episode ratings”.
2. Add debrid device authorization and the formatter/template configuration flow, adapted to QR
   hand-off on tvOS.
3. Decide whether Top Shelf should be sourced from the selected remote progress provider when no
   local preview has been cached.
4. Add visual snapshot/golden tests for profile selection, Home variants, settings, stream cards
   and every player panel. Current UI tests prove navigation/focus, not pixel-level appearance.

### P3 — deliberate or low-frequency differences

1. Expand CryptoJS compatibility only when a real supported plugin requires more surface.
2. Translate the remaining Android strings instead of maintaining two independent catalogs.
3. Revisit inline trailers only if a supported YouTube playback path becomes available on tvOS.

## Verification performed

- `xcodebuild` tvOS Simulator build: passed.
- Unit suite: **174 tests, 0 failures**.
- UI suite from the same remediation pass: **8 tests, 0 failures**.
- New contract/state tests cover Simkl mixed IDs and list projection, search-history behavior and
  player recovery gating.
- `git diff --check`: passed.

Not verified: live Trakt/Simkl/debrid/Nuvio accounts, a physical Apple TV, every third-party addon,
or visual comparison against a running Android 0.8.7 installation. Those are the remaining
acceptance tests, not evidence that the code is already equivalent.
