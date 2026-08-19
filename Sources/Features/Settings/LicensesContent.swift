import SwiftUI

/// Licences and attributions, the Apple TV counterpart of Android's
/// `LicensesAttributionsScreen`.
///
/// Two reasons it is not optional.  Several of the services Nuvio talks to require the credit
/// in the client — TMDB and IMDb both do — and the playback stack shipped in `Vendor/` is
/// FFmpeg, libmpv, libass and friends, whose licences oblige the app to say so.  It is inline
/// rather than a pushed screen because tvOS has no browser to send a viewer to: every URL here
/// is something to read and type on a phone, not something to open.
struct LicensesContent: View {
    @Environment(\.nuvioColors) private var colors

    var body: some View {
        VStack(alignment: .leading, spacing: NuvioTheme.components.settings.rowGap) {
            SettingsCard(title: L10n.text("licenses.section_app")) {
                attribution(
                    L10n.text("licenses.nuvio_title"),
                    L10n.text("licenses.nuvio_body"),
                    "github.com/NuvioMedia/NuvioTV"
                )
            }

            SettingsCard(title: L10n.text("licenses.section_data")) {
                ForEach(Self.dataAttributions, id: \.title) { item in
                    attribution(item.title, item.body, item.url)
                }
            }

            SettingsCard(title: L10n.text("licenses.section_playback")) {
                ForEach(Self.playbackAttributions, id: \.title) { item in
                    attribution(item.title, item.body, item.url)
                }
            }
        }
    }

    private func attribution(_ title: String, _ body: String, _ url: String) -> some View {
        VStack(alignment: .leading, spacing: NuvioTheme.spacing.xs) {
            Text(title)
                .nuvioText(NuvioTextStyles.cardTitle)
                .foregroundStyle(colors.textPrimary)
            Text(body)
                .nuvioText(NuvioTextStyles.bodyCompact)
                .foregroundStyle(colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(url)
                .nuvioText(NuvioTextStyles.metadata)
                .foregroundStyle(colors.textTertiary)
        }
        .frame(maxWidth: dp(760), alignment: .leading)
        .padding(.horizontal, NuvioTheme.spacing.lg)
        .padding(.vertical, NuvioTheme.spacing.sm)
    }

    private struct Attribution {
        let title: String
        let body: String
        let url: String
    }

    private static var dataAttributions: [Attribution] {
        [
            Attribution(
                title: "The Movie Database (TMDB)",
                body: L10n.text("licenses.tmdb_body"),
                url: "themoviedb.org"
            ),
            Attribution(
                title: "Trakt",
                body: L10n.text("licenses.trakt_body"),
                url: "trakt.tv"
            ),
            Attribution(
                title: "Simkl",
                body: L10n.text("licenses.simkl_body"),
                url: "simkl.com"
            ),
            Attribution(
                title: "Real-Debrid",
                body: L10n.text("licenses.debrid_body"),
                url: "real-debrid.com"
            ),
            Attribution(
                title: "Premiumize",
                body: L10n.text("licenses.debrid_body"),
                url: "premiumize.me"
            ),
            Attribution(
                title: "TorBox",
                body: L10n.text("licenses.debrid_body"),
                url: "torbox.app"
            ),
            Attribution(
                title: "MDBList",
                body: L10n.text("licenses.mdblist_body"),
                url: "mdblist.com"
            ),
            Attribution(
                title: "AniSkip",
                body: L10n.text("licenses.aniskip_body"),
                url: "aniskip.com"
            )
        ]
    }

    private static var playbackAttributions: [Attribution] {
        [
            Attribution(
                title: "AVFoundation",
                body: L10n.text("licenses.avfoundation_body"),
                url: "developer.apple.com/av-foundation"
            ),
            Attribution(
                title: "mpv / libmpv",
                body: L10n.text("licenses.libmpv_body"),
                url: "mpv.io"
            ),
            Attribution(
                title: "FFmpeg",
                body: L10n.text("licenses.ffmpeg_body"),
                url: "ffmpeg.org"
            ),
            Attribution(
                title: "libass, libplacebo, dav1d, MoltenVK",
                body: L10n.text("licenses.native_body"),
                url: "github.com/mpv-player/mpv/wiki"
            )
        ]
    }
}
