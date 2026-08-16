# Nuvio for Apple TV

A native tvOS client for the [Stremio addon](https://stremio.github.io/stremio-addon-guide/) ecosystem,
built to match the **NuvioTV** Android TV app as closely as tvOS allows.

Unlike the existing unofficial tvOS attempt, this is not a generic media-browser skin: the design
system, layout metrics, motion curves and screen structure are ported from the actual NuvioTV
Compose source, token for token.

<img src="docs/screenshot-home.png" width="720" alt="Modern home layout">

## Why this is a rewrite, not a port

The four Nuvio codebases split across two stacks:

| App | Stack |
| --- | --- |
| NuvioTV (Android TV) | Native Android — Kotlin + Jetpack Compose (`androidx.tv`), ExoPlayer/Media3 + libmpv |
| NuvioMobile (Android + iOS) | Kotlin Multiplatform + Compose Multiplatform, MPVKit |
| NuvioMobile-iOS (unofficial) | Fork of NuvioMobile — same KMP codebase |
| NuvioTVOS (unofficial) | KMP attempt |

The Android TV app — the one this targets — is **Android-only**: ~222k lines of Kotlin bound to
`androidx.tv.material3`, Hilt, DataStore, Media3 and libmpv-android. Compose Multiplatform has no
supported tvOS target and `androidx.tv` components do not exist off Android, which is why the
existing KMP-based tvOS attempt does not reproduce the interface.

This project instead reimplements the app in SwiftUI so it can use the real tvOS focus engine,
while porting NuvioTV's design system verbatim so it *looks and measures* like the original.

### The density bridge

The single most important detail for visual fidelity. Android TV renders a 1920×1080 panel at
density 2.0, giving Compose a **960×540 dp** layout space. tvOS lays out in **1920×1080 points**.
Every `dp`/`sp` token therefore maps to exactly 2 tvOS points:

```swift
enum NuvioScale { static let dp: CGFloat = 2.0 }
func dp(_ value: CGFloat) -> CGFloat { value * NuvioScale.dp }
```

Every token in `Sources/DesignSystem/Tokens.swift` goes through that bridge, so a 126 dp poster
card is 252 pt here and occupies the identical fraction of the screen.

## What is ported

**Design system** — a 1:1 port of `ui/theme/`:

- `NuvioPrimitives` (full neutral ramp + status/source colors)
- All 7 accent palettes (Crimson, Ocean, Violet, Emerald, Amber, Rose, White) with AMOLED variants
- Spacing, radii, shapes, sizes, component, stroke, elevation, effect, layout and media tokens
- Motion durations and the four Compose easing curves, incl. the sidebar's distinct in/out timings
- Typography: the same **Inter / DM Sans / Open Sans** variable fonts as the Android app, with the
  `wght` axis pinned per weight so text renders identically instead of being synthetically bolded

**Stremio protocol** — a faithful port of the Android URL builders and manifest handling:

- `canonicalizeUrl` semantics (strips `/manifest.json`, preserves configurable-addon query strings)
- `catalog/{type}/{id}.json`, `/skip={n}.json` and `/{k=v&k2=v2}.json` extra-args forms
- `meta`, `stream` and `subtitles` endpoints, `resources` + `idPrefixes` gating
- `URLEncoder.encode(…).replace("+", "%20")` reproduced exactly
- Tolerant decoding for the ecosystem's loose JSON (`director` as string *or* array, `imdbRating`
  as string *or* number, `extra` as objects *or* bare strings), and per-item failure isolation so
  one malformed entry cannot blank a catalog

**Screens**

| Screen | Notes |
| --- | --- |
| Shell | Modern floating pill that blooms into the glass sidebar panel on D-pad Left |
| Home | All three layouts — Modern (full-bleed hero), Classic, Grid |
| Detail | Hero + actions, seasons/episodes, cast, More like this |
| Streams | Grouped per addon, quality/HDR/codec/size/seeder chips |
| Player | Resume, progress persistence, per-stream proxy headers, Now Playing metadata |
| Search | Debounced fan-out across every search-capable catalog |
| Discover | Browse any catalog by type and genre |
| Library | Saved titles + Continue Watching |
| Settings | Addon Manager, Catalog Order, Appearance, Layout, Playback, About |

Signature behaviours are preserved, including the **focus-hold poster expansion** (a card held in
focus for 3s widens to `height × 16/9` and reveals its backdrop, logo and metadata) and the
marquee-on-focus card titles.

## Deliberate deviations

These are choices, not gaps — each one is a place where copying Android would have made the tvOS
app worse:

1. **Playback uses `AVPlayerViewController`.** NuvioTV ships a bespoke overlay over ExoPlayer and
   libmpv. On tvOS the system player owns the Siri Remote gestures, scrubbing preview, audio and
   subtitle pickers, and Now Playing integration that viewers expect; a hand-rolled SwiftUI overlay
   would be strictly worse. Nuvio's own logic (resume, progress, headers, metadata) is layered on
   top. The trade-off is codec coverage: AVFoundation handles H.264/HEVC/HLS, but not the MKV and
   exotic-audio range libmpv gives the Android build. Wiring in VLCKit or MPVKit is the natural
   next step if that matters.
2. **Focus is the tvOS focus engine**, not a reimplementation of Compose's. `focusSection()` and
   the native engine give correct D-pad behaviour for free; Nuvio's *visual* focus treatment
   (2 dp accent ring, 1.02 scale, 8 dp elevation) is reproduced by hand because tvOS's stock
   `.card` style applies Apple's parallax lift, which looks nothing like Nuvio.
3. **The sidebar pill is itself the focus target.** On Android the pill is non-focusable and a
   `LEFT` key handler opens the panel. Here moving focus left lands on the pill and the panel
   expands around it — same interaction, no programmatic focus moves to fight the engine.

## Not implemented

The Android app carries a large surface beyond the core browse-and-play loop. Not ported here:
Trakt/Simkl tracking and scrobbling, debrid integrations (Real-Debrid, Premiumize, TorBox),
torrent streaming, cloud sync and multi-profile accounts, collections/folders, MDBList and
parental-guide enrichment, the plugin runtime, and the in-app addon web configurator. The data
layer is structured so these slot in as additional repositories.

## Build & run

Requires Xcode 26 with the tvOS SDK, plus [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```bash
brew install xcodegen          # if needed
xcodegen generate
open NuvioTVOS.xcodeproj
```

From the command line:

```bash
xcodebuild -project NuvioTVOS.xcodeproj -scheme NuvioTVOS \
  -sdk appletvsimulator -destination 'platform=tvOS Simulator,name=Apple TV 4K (3rd generation)' \
  build
```

`project.yml` is the source of truth — `NuvioTVOS.xcodeproj` is generated and gitignored.

Cinemeta and OpenSubtitles v3 are installed by default (the same defaults as
`AddonPreferences.getDefaultAddons()`). Add more under **Settings → Addons → Addon Manager**,
either by URL or from the shortlist of popular addons.

## Layout

```
Sources/
  App/            App entry, Router, root scaffold
  DesignSystem/   Token, theme and typography ports
  Domain/         Addon, Meta, Stream, Subtitle models
  Data/           Stremio client, addon/library/settings stores
  Features/       Shell, Home, Search, Library, Detail, Streams, Player, Settings
  Support/        Image loading, tolerant JSON, disk persistence
Resources/        Inter / DM Sans / Open Sans variable fonts, brand marks
```

## Legal

Nuvio is a client-side playback interface. It does not host, store or distribute media; all
content comes from addons the user chooses to install. Not affiliated with Stremio, nor with the
Nuvio project — this is an unofficial tvOS client.
