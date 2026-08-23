# Feature audit

Written 2026-08-21 against 1.0.4 (6), because collections turned out to be built and invisible
and that was not supposed to be possible. It was: the same mechanism had already produced the
skip-intro complaint a day earlier.

**Resolved 2026-08-22.** Everything below is kept rather than deleted, because the interesting
part is not the list — it is why the list existed, and what now stops it coming back.

**Rechecked for 1.0.12 (14) on 2026-08-23.** The follow-up closed three cross-cutting gaps that a
screen inventory alone did not expose: Simkl had authentication but no complete library/progress
projection, Search and Discover stopped at their first page, and player load success was declared
before mpv produced a frame. Contract and state-machine coverage now lives in
`SimklContractTests`, `SearchHistoryTests` and `PlayerRecoveryPolicyTests`.

Two questions were asked of the tree, both mechanically rather than by reading:

1. Which settings can a viewer change that change nothing?
2. Which Android screens have no counterpart here?

## 1. Controls that do nothing — fixed

**243 settings were declared across the stores. 73 had no consumer anywhere in `Sources/`.**
Thirty percent. They split into two very different kinds, and the two needed opposite answers.

### A. A control existed and it was inert

The dangerous kind: the viewer finds a switch, throws it, and nothing happens. Eleven of them.
Eight are now wired; three were removed, because implementing them here would have been a
promise this platform cannot keep.

| Setting | What happened |
|---|---|
| `subtitleUseForcedSubtitles` | **Wired.** The rule is narrower than the label, and worth stating: when the audio is already in the language you read subtitles in, a full track repeats dialogue you can hear, so only a *forced* track comes on — and where there is none, nothing does. When the audio is another language the rule inverts and forced tracks are the ones excluded. Addons do not flag forced tracks, so the word is looked for in the id, URL and addon name, as upstream does. |
| `watchProgressSource` | **Wired.** [`RemoteProgressService`](../Sources/Data/RemoteProgressService.swift) pulls Trakt's resume points into Continue Watching. `TraktClient.playbackProgress` already existed, with a doc comment saying what it was for, and no caller. |
| `moreLikeThisSource` | **Wired.** Addon catalog, TMDB recommendations, or Trakt's related endpoint. All three fall back to the catalog rather than leaving the row empty — an empty row reads as "nothing is like this" rather than "that account is not connected". |
| `continueWatchingDaysCap` | **Wired.** A row abandoned eight months ago is not something you are in the middle of, and it pushes what you *are* watching off the end of the rail. |
| `enrichContinueWatching` | **Wired.** Episode stills from TMDB for rows that have none, so every episode of a show stops looking identical. Budgeted and de-duplicated: a rail is a handful of rows, not a reason for a request per appearance of Home. |
| `useEpisodes` | **Wired.** TMDB episode titles, overviews, stills and air dates, fetched per season on selection. Fills blanks only — the addon knows which cut it is serving and TMDB does not. |
| `instantPlaybackPreparationLimit` | **Wired.** Resolves the first few **cached** torrents through debrid before the viewer picks one. Only cached ones: asking debrid for an uncached torrent starts a download on the account, which is not something to do speculatively. |
| `settingsUIStyle` | **Wired.** The single-column alternative to the two-pane rail now exists. |
| `playbackIssueReportsEnabled` | **Removed.** It means "upload a diagnostic report to Nuvio's backend", whose contract belongs to the Android project. A toggle meaning something different from what it says on Android is worse than an absent one. |
| `focusedPosterBackdropTrailerEnabled` | **Removed.** See below. |
| `trailers.enabled` / `delaySeconds` | **Removed.** Stremio trailers are YouTube ids; tvOS has no WKWebView and AVPlayer cannot resolve a YouTube watch page. That is the same reason [`TrailerLauncher`](../Sources/Support/TrailerLauncher.swift) hands off to the YouTube app rather than playing anything itself. The whole hero-trailer family cannot exist here. |

`showsAdvancedSettings`, `canStartTraktAuth`, `canStartSimklAuth` and `settingsUIStyle` are read
only by the settings UI, which is their entire purpose. They are allowlisted in the guard script
with that reason.

### B. Store fields with no UI and no consumer

The other ~60 were stored, defaulted, synced — and referenced nowhere at all. Mostly the
ExoPlayer surface with no meaning on tvOS: `minBufferMs`, `tunnelingEnabled`, `useLibass`, the
Dolby Vision 7 mapping family, the downmix family, `parallelNetworkEnabled` and its knobs.

**52 were deleted. Five were wired instead**, because they had a real meaning here and a natural
home:

| Setting | Where it landed |
|---|---|
| `subtitleOrganizationMode` | `SubtitleSelector.group` had supported all three modes since the port began; nothing was telling it which one to use, so every viewer got "by language" whichever they picked. |
| `resizeMode` | The aspect the picture starts in. The player's Display button already cycled seven modes; the viewer's *default* went nowhere. |
| `externalPlayerForwardSubtitles` | Infuse and VLC accept a sidecar `sub=` on their callback. Without it a hand-off silently drops the subtitle track the viewer had chosen. nPlayer and Outplayer take a bare URL, and the row says so. |
| `reuseBingeGroup`, `preferBingeGroupNextEpisode`, `autoPlayNextEpisodeFallbackEnabled` | The next episode now plays from the release you were already watching — same encode, same audio, same subtitle timing — instead of reopening the choice. |
| `streamAutoPlayTimeoutSeconds` | The grace period between the source list appearing and one being chosen for you. |

**Deleting the other 52 does not touch account sync**, and that is not an assumption:
`PreferenceStore` syncs its **raw storage**, not its declared properties, so a key arriving from
Android is persisted and written back whether or not a Swift property names it.
[`PreferenceSyncTests`](../Tests/PreferenceSyncTests.swift) proves it. What *would* lose data is
removing a namespace from `AppSettings.syncedStores` — which is why `TrailerSettingsStore` is
still registered while being deliberately empty.

## 2. Collections were not the same feature — fixed

Recorded here because it prompted this audit, and because the fix carried a more urgent one.

**Then**: ours was a named folder holding a manual list of bookmarked titles. Upstream's is a
collection containing **folders**, each folder containing **sources**, where a source is a live
query — an addon catalog optionally narrowed by genre, a TMDB request, or a Trakt list.

**Also then, and worse**: collections sync through the shared account as one `collections_json`
blob, and the two payloads had nothing in common. Theirs would not decode here at all, because
`JSONDecoder` is strict and `name` was absent. Ours parsed *there* into titleless empty
collections, because Gson is lenient. On one account, whichever app synced last destroyed the
other's collections.

**Now**: the model is upstream's, field for field, including the legacy `catalogSources` mirror
that older Android builds still read. Manual collections are gone, and the old file is moved
aside rather than deleted. The TMDB source editor exposes all eighteen filters as of 2026-08-22;
it had exposed three.

**And the ordering, which was a third thing wrong with them.** A collection was not a home row
that could be placed — every collection rendered after every catalogue, so the "pin above
catalogs" switch reordered collections among themselves and moved nothing past a catalogue.
[`HomeRowOrder`](../Sources/Data/HomeRowOrder.swift) is upstream's `rebuildCatalogOrder` and
`normalizeCollectionBoundaries`: one list where a collection is an equal of a catalogue, pinned
ones ahead of everything, and — under *follow addons order* — a collection pushed out of the
middle of one addon's run of catalogues, because splitting a block is the one thing that mode
exists to prevent.

Deliberately not rendered: `focusGifUrl` and `heroVideoUrl`. An animated cover per card would
need a video layer per tile on tvOS. Both are parsed, kept, and written back, so a round trip
through this app does not strip them from the others.

## 3. Screens with no counterpart — fixed

| Android | Here |
|---|---|
| `collection/` (12 files) | Ported — manager and editor in Settings → Sources, folder screen, rails on Home |
| `ExperienceModeSelectionScreen` | [`FirstRunView`](../Sources/Features/Onboarding/FirstRunView.swift), step 1 |
| `LayoutSelectionScreen` | `FirstRunView`, step 2 — `hasChosenLayout` was written in Settings and read by nothing, so the flow could never start |
| `EssentialAddonSetupScreen` | `FirstRunView`, step 3 |

One screen with three steps rather than three pushed screens: on a remote, Back out of step two
should return to step one, not leave a half-configured app, and a single `@State` step makes that
true by construction. It is skipped under XCUITest, where a fresh container is indistinguishable
from a first install — which the UI suite caught within minutes of the screen existing.

The rest — account, addon, cast, detail, home, library, player, plugin, profile, search,
settings, stream, tmdb — all have counterparts. `SupportersContributorsScreen` is declined, with
the V1 supporter perks it belongs to.

## 4. What stops it happening again

The mechanism mattered more than any single finding: **the settings stores were ported from
Android's DataStores wholesale, ahead of the features that would read them, and the settings
screens were built from the stores.** An inert control was the default outcome, not an oversight.

[`Scripts/check-settings-wiring.sh`](../Scripts/check-settings-wiring.sh) now runs as a build
phase and **fails the build** when a declared setting has no reader. A setting counts as read
when something outside `Sources/Data/` mentions it other than as a SwiftUI binding —
`$player.subtitleSize` is a control being drawn, `player.subtitleSize` is somebody acting on the
value — or when a store helper next to it reads it and the features read the helper.

Both failure modes are verified rather than assumed: a field with no mention at all, and a field
whose every mention is a binding, were each introduced deliberately and confirmed to fail the
script before being removed again.

## Method

The original scan, kept so the numbers above can be re-derived:

```
for f in Sources/Data/*SettingsStore*.swift Sources/Data/SettingsStore.swift; do
  grep -oE '^    var [a-zA-Z0-9_]+' "$f" | awk '{print $2}'
done | sort -u | while read -r n; do
  total=$(grep -rho "\b$n\b" Sources/ | wc -l)
  instore=$(grep -rho "\b$n\b" Sources/Data/ | wc -l)
  inui=$(grep -rho "\b$n\b" Sources/Features/Settings/ | wc -l)
  [ $((total - instore - inui)) -le 0 ] && [ "$instore" -le 1 ] && echo "$n"
done
```

It reports 73 against the 1.0.4 tree and nothing against this one. The build-phase script is the
same idea with the binding distinction added, which is what separates an inert control from a
field with no UI at all.
