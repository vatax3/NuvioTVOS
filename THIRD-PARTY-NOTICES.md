# Third-party notices

Nuvio for Apple TV is licensed under the GNU General Public License v3.0 (see `LICENSE`). It is a
port of [NuvioTV for Android TV](https://github.com/tapframe/NuvioTV), which is GPL-3.0, so the
port is a derivative work and carries the same terms.

The playback stack is linked in and keeps its own. Nothing below is checked into this repository.
The mpv half is fetched by `Scripts/fetch-mpv.sh`, which downloads all 28 xcframeworks from a
pinned release (`VERSION="1.0.0"`) of the MPVKit projects and trims each to its tvOS slice. The
AetherEngine half is resolved by SwiftPM from `Packages/PlayerEngineKit`, pinned to a minor.

## Relinking

AetherEngine, libmpv and most of the stack below are LGPL. Section 4 of the LGPL requires that a recipient be
able to relink the application against a modified version of the library. That is satisfied in
practice rather than by a special provision: this application is built from source, and every
binary it links is fetched by a script at a pinned version that anyone can point at their own
build. Replace an xcframework in `Vendor/`, run `xcodegen generate`, and rebuild. The AetherEngine
side is relinkable the same way and more directly: its FFmpeg frameworks are **dynamically** linked
and resolved by SwiftPM, so pointing `Packages/PlayerEngineKit/Package.swift` at another build of
either is the whole procedure.

## Components — AetherEngine

Resolved through `Packages/PlayerEngineKit`, which depends on AetherEngine with the
`TrueHDObjectAudio` and `DTSXObjectAudio` package traits enabled. The engine's own FFmpeg is
prefixed (`AetherLibavcodec` and friends) and is a **separate** FFmpeg from mpv's below: both are in
the binary, each linked to its own, which is why the wrapper package exists.

| Component | Source repository | Licence |
|---|---|---|
| AetherEngine | `superuser404notfound/AetherEngine` | LGPL-3.0-or-later, with an Apple-store / DRM exception |
| FFmpeg — AetherLibavcodec, AetherLibavformat, AetherLibavutil, AetherLibswresample, AetherLibswscale, AetherLibavfilter | `superuser404notfound/FFmpegBuild` | LGPL-2.1-or-later, no GPL components, dynamically linked |
| dav1d (AetherLibdav1d) | `superuser404notfound/FFmpegBuild` | BSD-2-Clause |
| zimg (AetherLibzimg) | `superuser404notfound/FFmpegBuild` | WTFPL |
| libzvbi (AetherLibzvbi) | `superuser404notfound/FFmpegBuild` | LGPL-2.1-or-later (GPL parts excised) |
| libdovi | `superuser404notfound/LibDovi` | MIT (the `dolby_vision` crate from `quietvoid/dovi_tool`, dual MIT OR Apache-2.0, taken under MIT) |
| LibTrueHD | `superuser404notfound/LibTrueHD` | MIT for the C API, framer and packaging (Copyright Quick104, Vincent Herbst); the compiled-in `truehd` and `oamd` crates from `truehdd/truehdd` are **Apache-2.0** (Copyright Rainbaby and the truehdd contributors) |

**Apache-2.0 obligation.** LibTrueHD is statically linked whenever the `TrueHDObjectAudio` trait is
on, which it is in this build. Apache-2.0 §4 requires its licence text and LibTrueHD's own `NOTICE`
to travel with the binary. Both ship in the app bundle, from `Resources/Licenses/`
(`LibTrueHD-Apache-2.0.txt`, `LibTrueHD-NOTICE.txt`, with `LibTrueHD-MIT.txt` and
`AetherEngine-LGPL-3.0.txt` beside them), and the in-app attribution screen names them.
DTS:X needs no entry of its own — it is decoded by FFmpeg's `dca` decoder above, with FFmpegBuild's
height patch, so the `DTSXObjectAudio` trait adds no library and no licence.

## Components — libmpv

All fetched from the `mpvkit` organisation. The licence column is the component's own upstream
licence; where a project offers a choice, the term listed is the one its MPVKit build is made
under.

| Component | Source repository | Licence |
|---|---|---|
| libmpv | `mpvkit/MPVKit` | GPL-2.0-or-later |
| FFmpeg — libavcodec, libavdevice, libavfilter, libavformat, libavutil, libswresample, libswscale | `mpvkit/MPVKit` | LGPL-2.1-or-later, with GPL components where enabled |
| libass | `mpvkit/libass-build` | ISC |
| FreeType | `mpvkit/libass-build` | FTL or GPL-2.0-or-later |
| FriBidi | `mpvkit/libass-build` | LGPL-2.1-or-later |
| HarfBuzz | `mpvkit/libass-build` | MIT (Old) |
| libunibreak | `mpvkit/libass-build` | Zlib |
| libbluray | `mpvkit/libbluray-build` | LGPL-2.1-or-later |
| dav1d | `mpvkit/libdav1d-build` | BSD-2-Clause |
| libdovi | `mpvkit/libdovi-build` | MIT |
| libplacebo | `mpvkit/libplacebo-build` | LGPL-2.1-or-later |
| shaderc | `mpvkit/libshaderc-build` | Apache-2.0 |
| uavs3d | `mpvkit/libuavs3d-build` | BSD-3-Clause |
| uchardet | `mpvkit/libuchardet-build` | MPL-1.1 / GPL-2.0-or-later / LGPL-2.1-or-later |
| MoltenVK | `mpvkit/moltenvk-build` | Apache-2.0 |
| Little CMS (lcms2) | `mpvkit/lcms2-build` | MIT |
| OpenSSL — libcrypto, libssl | `mpvkit/openssl-build` | Apache-2.0 |
| GnuTLS | `mpvkit/gnutls-build` | LGPL-2.1-or-later |
| Nettle, Hogweed | `mpvkit/gnutls-build` | LGPL-3.0-or-later / GPL-2.0-or-later |
| GMP | `mpvkit/gnutls-build` | LGPL-3.0-or-later / GPL-2.0-or-later |

## Fonts

| Font | Licence |
|---|---|
| Inter | SIL Open Font License 1.1 |
| DM Sans | SIL Open Font License 1.1 |
| Open Sans | SIL Open Font License 1.1 |
| Noto Sans CJK SC | SIL Open Font License 1.1 |

## Services

The app talks to services it does not bundle and does not represent: TMDB, Trakt, Simkl, MDBList,
AniSkip, and the debrid providers Real-Debrid, Premiumize and TorBox. Each is used under its own
terms with credentials the viewer supplies. This product uses the TMDB API but is not endorsed or
certified by TMDB.

The in-app attribution screen (Settings → About → Licences) carries the same list for viewers who
will never read this file, and is the copy that has to stay correct on the television.
