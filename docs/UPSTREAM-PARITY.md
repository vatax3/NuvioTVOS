# Upstream parity

Nuvio for Apple TV is a port of [NuvioMedia/NuvioTV](https://github.com/NuvioMedia/NuvioTV), the
Android TV app. This file records how far the port has been reconciled against it.

**Reconciled through: `0.8.7-beta` (2026-08-20).**

That sentence is the whole point of this file, and it is deliberately not "we have the same
features as 0.8.7". A shared version number would claim an equality that cannot exist: roughly a
third of every upstream release is ExoPlayer, Compose or Android TV platform work with no tvOS
counterpart. What is claimed here is narrower and checkable — **every upstream release up to and
including 0.8.7 has been read, and each change in it was ported, judged not applicable, or
declined for a stated reason.**

The two version lines are therefore independent. Ours is `1.0.x`; theirs is `0.8.x-beta`. They
ship roughly twice a week from about ten contributors, so a lockstep number would be wrong within
a week of being set, and would force empty releases to keep it true.

## How to bring this forward

1. `gh release list --repo NuvioMedia/NuvioTV` and read every release published after the tag
   named above.
2. Put each changelog line into one of the three tables below.
3. Port what belongs in the first table, then move the marker.

A line that is genuinely hard to classify usually belongs in **declined** with the doubt written
down, not in **ported** with an optimistic guess.

See also [FEATURE-AUDIT.md](FEATURE-AUDIT.md), which asks the complementary question: not "have
we kept up with their releases" but "does what we already shipped actually work".

## Ported

| Upstream | Release | Here |
|---|---|---|
| Universal subtitle charset detector | 0.8.5 | [`SubtitleLoader.decodeSubtitleText`](../Sources/Data/SubtitleEngine.swift). Our fallback chain could not have worked: Windows-1252 accepts nearly every byte, so it never failed and everything behind it was unreachable — Cyrillic and Greek tracks became confident mojibake. Now Foundation's detector, with UTF-8 kept in front of it. |
| Simultaneously active unpositioned cues no longer overlap | 0.8.5 | [`SubtitleTrackController.showing`](../Sources/Features/Player/SubtitleOverlay.swift). Ours had the worse form of the same bug: it returned one cue, so the second speaker's line was dropped rather than drawn badly. |
| “Strip SDH subtitles” setting | 0.8.5 | [`SubtitleSDHFilter`](../Sources/Data/SubtitleSDHFilter.swift) for the sidecar tracks Nuvio draws itself, plus mpv's native `sub-filter-sdh` for muxed ones — the same split upstream uses. |
| Refreshed and retain source results in selection | 0.8.5 | [`StreamsViewModel.load(retainingResults:)`](../Sources/Features/Streams/StreamsView.swift). Refreshing blanked the list, which threw away the comparison the refresh was asked for. The chosen addon tab now also survives a refresh. |
| Keep playback running across Bluetooth route changes | 0.8.7 | [`PlaybackAudioSession.observeRouteChanges`](../Sources/Features/Player/PlaybackWakeLock.swift). The session is retaken and playback resumes, attributed by a short window so a deliberate pause is never overridden. |
| Persist library type filter | 0.8.7 | [`LayoutSettingsStore.libraryFilter`](../Sources/Data/LayoutSettingsStore.swift), and the same for the debrid cloud list. |

Found on the way, in no upstream changelog: the byte order mark was never stripped from a
subtitle file, so it became a real `U+FEFF` in front of the first cue number and **the first cue
of every BOM-marked track failed to parse**. Windows editors write one by default.

| Collections: folders of live sources | pre-0.8.4 | The whole feature, ported to upstream's model — [`CollectionModel.swift`](../Sources/Data/CollectionModel.swift), [`CollectionSourceResolver.swift`](../Sources/Data/CollectionSourceResolver.swift), the folder screen and the editor. The shared `collections_json` shape is matched field for field, which also ends the two apps overwriting each other's collections on one account. **Not rendered on tvOS**: `focusGifUrl` and `heroVideoUrl` — a video layer per tile — though both survive a round trip untouched. |
| Home row ordering with collections as first-class rows | pre-0.8.4 | [`HomeRowOrder`](../Sources/Data/HomeRowOrder.swift), a port of `rebuildCatalogOrder` and `normalizeCollectionBoundaries`. Collections appear in Catalog order alongside catalogues and can be placed anywhere between them; `pinToTop` puts one ahead of every catalogue, which is what its label had been promising. |
| First-run setup: experience mode, layout, essential add-ons | pre-0.8.4 | [`FirstRunView`](../Sources/Features/Onboarding/FirstRunView.swift). Upstream's three screens as one screen with three steps, so Back returns to the previous step rather than leaving a half-configured app. |
| Watch progress and library sourced from a tracking account | pre-0.8.4 | [`TrackingSources`](../Sources/Data/TrackingSources.swift) and [`RemoteProgressService`](../Sources/Data/RemoteProgressService.swift), including upstream's *effective source* rule: a preference pointing at an account nobody signed into falls back to this device rather than rendering an empty screen. |
| Next episode from the same release (`bingeGroup`) | pre-0.8.4 | [`StreamFilterEngine.bingeGroupMatch`](../Sources/Data/StreamFilterEngine.swift). Same encode, same audio, same subtitle timing, without reopening the source list. |
| TMDB episode metadata, forced-subtitle selection, instant playback preparation, subtitle picker grouping, default aspect, external-player subtitle hand-off | pre-0.8.4 | Settings that existed here from the start and were read by nothing. See [FEATURE-AUDIT.md](FEATURE-AUDIT.md) §1. |

## Not applicable

Android platform internals with nothing to port. Listed so the next pass does not re-examine them.

| Upstream | Release | Why |
|---|---|---|
| ExoPlayer AAR update, tunneled playback, `striphdr10plussei` sync exclusion | 0.8.5 | We decode through AVFoundation and libmpv. |
| DataStore crashes, foreground startup sync decoupling | 0.8.5 | Different persistence and lifecycle entirely. |
| Eliminated infinite launcherx waking loops | 0.8.5 | Android launcher integration. |
| Fingerprint caching for recommendations & preview channels | 0.8.5 | tvOS has Top Shelf, which works nothing like preview channels. |
| Coil memory cache and decoder parallelism for TV | 0.8.6 | Different image pipeline. |
| Disable rgb565 for profile backgrounds | 0.8.7 | No such pixel format in our renderer. |
| Hide update banner during playback | 0.8.5 | We have no in-app updater. |

## Already true here

Behaviour upstream added that this port already had, usually because it was built from the
reference apps rather than from the Android source alone.

| Upstream | Release | Here |
|---|---|---|
| Exit player on back press when skip intro button is hidden | 0.8.5 | [`PlayerExitPolicy`](../Sources/Features/Player/PlayerExitPolicy.swift) never let the skip card absorb Menu. |
| Direct player pause/exit synchronisation | 0.8.5 | Same ordered chain, plus [`PlayerRemotePolicy`](../Sources/Features/Player/PlayerRemotePolicy.swift). |
| Re-focus first stream when new results arrive above | 0.8.5 | Cannot occur here: results are assigned once when the load completes, never streamed in above the focused row. |

## Declined

Not ported, on purpose.

| Upstream | Release | Why |
|---|---|---|
| V1 for supporter perks | 0.8.7 | A product and monetisation decision that belongs to the upstream project, not to a port of it. |
| Support for discovery endpoint | 0.8.5 | Depends on their backend contract. Porting it from a changelog line alone would mean guessing at the protocol, and a wrong guess here fails silently. Revisit with the endpoint documented. |
| Configurable rating visibility | 0.8.7 | Deferred, not refused — a preference with no bug behind it. |
| Hero trailers and focused-poster trailers | pre-0.8.4 | Cannot exist on this platform. Stremio trailers are YouTube ids; tvOS has no WKWebView and AVPlayer cannot resolve a YouTube watch page, which is why the trailer button hands off to the YouTube app. The settings were removed rather than left inert; the `trailer` sync namespace is still round-tripped. |
| Playback issue reports | pre-0.8.4 | The report uploads to Nuvio's own backend, whose contract belongs to the Android project. Same reasoning as the discovery endpoint above. |
| Keep poster art when episode thumbnails are off | 0.8.5 | Same. |
| Redesign episode options overlay | 0.8.7 | Our in-player panels were designed against the iOS and macOS apps and already diverge deliberately. |
| Localization updates | 0.8.5, 0.8.7 | Our strings are our own; `Resources/*.lproj` is not generated from theirs. |
