# Feature audit

Written 2026-08-21, against 1.0.4 (6), because collections turned out to be built and invisible
and that was not supposed to be possible. It was: the same mechanism had already produced the
skip-intro complaint a day earlier. This records what else it is hiding.

Two questions were asked of the tree, both mechanically rather than by reading:

1. Which settings can a viewer change that change nothing?
2. Which Android screens have no counterpart here?

## 1. Controls that do nothing

**243 settings are declared across the stores. 73 have no consumer anywhere in `Sources/`** —
not the player, not a view, not a client. Thirty percent.

They split into two very different kinds.

### A. A control exists and it is inert

The dangerous kind: the viewer finds a switch, throws it, and nothing happens. Each of these
appears exactly once outside its store — as the binding of a settings row.

| Setting | Where the control lives |
|---|---|
| `subtitleUseForcedSubtitles` | Playback → Subtitles |
| `playbackIssueReportsEnabled` | Playback |
| `watchProgressSource` | Tracking |
| `moreLikeThisSource` | Tracking |
| `continueWatchingDaysCap` | Tracking |
| `enrichContinueWatching` | Integrations → TMDB |
| `useEpisodes` | Integrations → TMDB |
| `instantPlaybackPreparationLimit` | Debrid |
| `focusedPosterBackdropTrailerEnabled` | Layout |
| `delaySeconds` | Layout → Trailers |
| `settingsUIStyle` | Advanced |

`showsAdvancedSettings`, `canStartTraktAuth`, `canStartSimklAuth`, `hasChosenLayout` and
`experienceModeChosen` also came up in the scan and are **not** defects — their whole purpose is
to change the settings UI, which is where they are read.

Two of this class were fixed in 1.0.3 and 1.0.4 after the user reported them: the Anime-Skip
toggle and client id, the AniSkip toggle, and "Skip intros automatically". They were found by
someone using the app, not by anything in the build.

### B. Store fields with no UI and no consumer

The remaining ~60 are stored, defaulted, synced — and referenced nowhere at all. Mostly the
ExoPlayer surface that has no meaning on tvOS: `minBufferMs`, `maxBufferMs`, `backBufferDurationMs`,
`bufferForPlaybackMs`, `targetBufferSizeMb`, `allowLargeTargetBuffer`, `bufferEngineEnabled`,
`enableBufferLogs`, `tunnelingEnabled`, `decoderPriority`, `useLibass`, `libassRenderType`,
`vodCacheEnabled`/`SizeMb`/`SizeMode`, `parallelNetworkEnabled` and its chunk/connection knobs,
the Dolby Vision 7 mapping family, the downmix family, `resizeMode`, `frameRateMatching`
(distinct from `frameRateMatchingMode`, which *is* used).

Harmless in themselves. They are evidence of the cause: **the settings stores were ported from
Android's DataStores wholesale, ahead of the features that would read them.** The screen was
built from the store, so every field grew a control whether or not anything consumed it. That is
the mechanism, and it is why an inert control is the default outcome here rather than an
oversight.

## 2. Collections are not the same feature

Worth stating plainly, because 1.0.4 just put "collections" on the home screen and that is **our**
collections, not Android's.

**Ours** (`Sources/Data/CollectionStore.swift`): a named folder holding a manual list of titles,
membership by `rowKey`, resolved against the library's preview cache. A favourites folder.

**Theirs** (`domain/model/Collection.kt`): a collection contains **folders**, each folder contains
**sources**, and a source is one of

- an addon catalog, optionally filtered by genre (`CollectionCatalogSource`),
- a TMDB discover query with genre filters, media type and sort (`TmdbCollectionFilters`),
- a Trakt list with its own sort (`TraktListSort`, `TraktSortHow`).

Plus a backdrop image, a per-folder tile shape, and a full-screen `FolderDetailScreen`. The editor
is seven files — catalog picker, TMDB picker, Trakt picker, genre/emoji pickers.

So upstream's collections are **user-built home sections assembled from live sources**. Ours is a
static list of things you bookmarked. Same word, different feature. What shipped in 1.0.4 is worth
having and is not parity.

## 3. Screens with no counterpart

| Android | Here |
|---|---|
| `collection/` (12 files: management, folder detail, source pickers) | A rail and an editor inside the Library tab |
| `ExperienceModeSelectionScreen` | No first-run chooser; `showsAdvancedSettings` covers the outcome |
| `LayoutSelectionScreen` | Launch profile chooser exists (`hasChosenLayout` is written, never read back) |

The rest — account, addon, cast, detail, home, library, player, plugin, profile, search, settings,
stream, tmdb — all have counterparts.

## What to do about it

In order of how much it costs a viewer:

1. **Remove or implement the eleven inert controls.** Removing is usually right: a setting that
   does nothing is worse than an absent one, because it spends the viewer's trust. Where the
   Android behaviour is worth having — `subtitleUseForcedSubtitles` especially, which is a real
   subtitle-selection rule — implement it.
2. **Delete the ~60 orphan store fields**, or move them behind a comment saying they exist only
   to keep account sync round-tripping Android's payload. If sync is the reason, that is a good
   reason and should be written down; right now nothing says so.
3. **Decide what "collections" means here.** Either keep ours and say in the parity document that
   the name is shared and the feature is not, or build the source-backed version. The first is
   cheap and honest; the second is a genuine feature.
4. **Stop the mechanism.** A test that walks the settings stores and asserts every declared
   setting has a reader would have caught all of this, and would keep catching it. It is the only
   item here that prevents the next occurrence rather than cleaning up after this one.

## Method

Reproducible, so this can be re-run rather than re-argued:

```
# settings with no consumer outside the stores and the settings UI
for f in Sources/Data/*SettingsStore*.swift Sources/Data/SettingsStore.swift; do
  grep -oE '^    var [a-zA-Z0-9_]+' "$f" | awk '{print $2}'
done | sort -u | while read -r n; do
  total=$(grep -rho "\b$n\b" Sources/ | wc -l)
  instore=$(grep -rho "\b$n\b" Sources/Data/ | wc -l)
  inui=$(grep -rho "\b$n\b" Sources/Features/Settings/ | wc -l)
  [ $((total - instore - inui)) -le 0 ] && [ "$instore" -le 1 ] && echo "$n"
done
```

Counts indirect readers as consumers only when a store helper reads the field and something reads
the helper — `subtitleStripSDH` reaches the player through `settings.subtitleStyle`, and is
correctly absent from the list above.
