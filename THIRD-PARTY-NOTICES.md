# Third-party notices

Nuvio for Apple TV is licensed under the GNU General Public License v3.0 (see `LICENSE`). It is a
port of [NuvioTV for Android TV](https://github.com/tapframe/NuvioTV), which is GPL-3.0, so the
port is a derivative work and carries the same terms.

The playback stack is linked in and keeps its own. Nothing below is checked into this repository —
`Scripts/fetch-mpv.sh` downloads all 28 xcframeworks from a pinned release (`VERSION="1.0.0"`) of
the MPVKit projects, then trims each to its tvOS slice.

## Relinking

libmpv and most of the stack below are LGPL. Section 4 of the LGPL requires that a recipient be
able to relink the application against a modified version of the library. That is satisfied in
practice rather than by a special provision: this application is built from source, and every
binary it links is fetched by a script at a pinned version that anyone can point at their own
build. Replace an xcframework in `Vendor/`, run `xcodegen generate`, and rebuild.

## Components

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
