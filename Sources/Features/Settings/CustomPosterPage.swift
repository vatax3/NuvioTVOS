import Foundation

/// The page `LocalConfigServer` serves for the custom poster URL.
///
/// Fourth page on the same server, and the one with the strongest case for existing: the value is
/// a URL with a query string and half a dozen brace tokens, and the remote's on-screen keyboard
/// has no `{`. Self-contained for the same reason as the others — served off a television on a
/// home network, so a stylesheet from anywhere else would leave the phone with an unusable form.
///
/// It shows the pattern resolved against two real titles rather than describing what it will do,
/// because the mistakes here are silent: a required id the service does not know about yields no
/// URL at all, and on the television that is indistinguishable from the pattern being ignored.
enum CustomPosterPage {
    struct Preview {
        var label: String
        var resolved: String?
    }

    /// Two titles that between them cover the case that goes wrong. `tt` is what almost every
    /// pattern is written for; a Kitsu id is the one most services cannot answer, so a pattern
    /// that resolves the first and not the second is working exactly as it should.
    static let sampleImdb = CustomPosterURL.ContentIds(
        id: "tt0903747", imdb: "tt0903747", tmdb: "1396"
    )
    static let sampleKitsu = CustomPosterURL.ContentIds(id: "kitsu:7442", kitsu: "7442")

    static func previews(pattern: String) -> [Preview] {
        [
            Preview(
                label: "Breaking Bad — series, IMDb and TMDB ids",
                resolved: CustomPosterURL.resolve(
                    pattern: pattern, ids: sampleImdb, contentType: "series"
                )
            ),
            Preview(
                label: "An anime listed under a Kitsu id only",
                resolved: CustomPosterURL.resolve(
                    pattern: pattern, ids: sampleKitsu, contentType: "series"
                )
            )
        ]
    }

    static func html(pattern: String, screens: [(key: String, name: String, isOn: Bool)]) -> String {
        """
        <!doctype html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>Nuvio — poster artwork</title>
        <style>
          :root { color-scheme: dark; }
          * { box-sizing: border-box; }
          body {
            margin: 0; padding: 24px 18px 64px;
            background: #101014; color: #ececf1;
            font: 16px/1.55 -apple-system, BlinkMacSystemFont, "Segoe UI", system-ui, sans-serif;
          }
          .wrap { max-width: 720px; margin: 0 auto; }
          h1 { font-size: 22px; margin: 0 0 4px; letter-spacing: -.01em; }
          h2 { font-size: 17px; margin: 30px 0 10px; }
          p.lede { margin: 0 0 24px; color: #9a9aa8; font-size: 15px; }
          label { display: block; font-weight: 600; margin: 0 0 6px; font-size: 15px; }
          .hint { color: #9a9aa8; font-size: 13px; margin: 0 0 8px; }
          textarea {
            width: 100%; background: #191920; color: #ececf1;
            border: 1px solid #2c2c38; border-radius: 10px; padding: 12px;
            font: 13px/1.5 ui-monospace, SFMono-Regular, Menlo, monospace;
            resize: vertical; -webkit-appearance: none;
          }
          textarea:focus { outline: 2px solid #4fc9dd; outline-offset: 1px; border-color: transparent; }
          .field { margin-bottom: 26px; }
          .preview {
            background: #16161d; border: 1px solid #24242e; border-radius: 10px;
            padding: 14px; margin: 6px 0 22px;
            font: 12.5px/1.5 ui-monospace, SFMono-Regular, Menlo, monospace; color: #c9c9d4;
            overflow-wrap: anywhere;
          }
          .preview strong { display: block; color: #9a9aa8; font-size: 12px; margin-bottom: 4px;
            font-family: -apple-system, system-ui, sans-serif; font-weight: 600; }
          .preview + .preview { margin-top: -10px; }
          .none { color: #e8935f; }
          .screens { display: grid; gap: 2px; margin: 0 0 26px; }
          .screens label {
            display: flex; align-items: center; gap: 12px; font-weight: 400;
            padding: 11px 12px; background: #16161d; border: 1px solid #24242e;
            border-radius: 10px; margin: 0;
          }
          .screens input { width: 21px; height: 21px; accent-color: #4fc9dd; }
          .row { display: flex; gap: 10px; flex-wrap: wrap; }
          button {
            flex: 1 1 160px; padding: 13px 18px; border-radius: 10px; border: 0;
            font: 600 16px/1 -apple-system, system-ui, sans-serif; cursor: pointer;
          }
          button.save { background: #4fc9dd; color: #06222a; }
          button.reset { background: #24242e; color: #ececf1; }
          details { margin-top: 34px; border-top: 1px solid #24242e; padding-top: 18px; }
          summary { cursor: pointer; font-weight: 600; }
          code { background: #191920; padding: 1px 5px; border-radius: 4px; font-size: 12.5px; }
          table { width: 100%; border-collapse: collapse; margin-top: 12px; font-size: 13.5px; }
          td { padding: 5px 8px 5px 0; vertical-align: top; border-bottom: 1px solid #1e1e26; }
          td:first-child { white-space: nowrap; color: #4fc9dd; font-family: ui-monospace, monospace; }
        </style>
        </head>
        <body>
        <div class="wrap">
          <h1>Poster artwork</h1>
          <p class="lede">A URL to fetch posters from instead of the addon's own — a rating-overlay
          service, say. Leave it empty to use whatever each addon supplies. A title the pattern
          cannot address keeps its original poster.</p>

          \(previews(pattern: pattern).map(previewBlock).joined(separator: "\n          "))

          <form method="post">
            <div class="field">
              <label for="pattern">URL pattern</label>
              <p class="hint">Placeholders in braces. <code>{imdb_id}</code> is the usual one.</p>
              <textarea id="pattern" name="pattern" rows="4" spellcheck="false" autocapitalize="off" autocorrect="off" inputmode="url">\(escape(pattern))</textarea>
            </div>

            <h2>Where it applies</h2>
            <p class="hint">Each screen you leave on multiplies the requests to the service.</p>
            <div class="screens">
              \(screens.map(screenRow).joined(separator: "\n              "))
            </div>

            <div class="row">
              <button class="save" type="submit" name="action" value="save">Save</button>
              <button class="reset" type="submit" name="action" value="reset">Clear</button>
            </div>
          </form>

          <details>
            <summary>Placeholders</summary>
            <p>A token in braces is replaced by the title's id. A token the title has no value for
            means <em>no URL at all</em>, and the addon's own poster is used — so
            <code>{imdb_id}</code> in a pattern quietly skips everything listed under another
            namespace. Write <code>{imdb_id?}</code> to let it resolve to nothing instead, or
            <code>{imdb_id|tmdb_id}</code> to say which ids the service accepts.</p>
            <table>
              \(tokenRows)
            </table>
            <p>Services on <code>ratingposterdb.com</code>, <code>aioratings.com</code>,
            <code>top-posters.com</code> and <code>btttr.cc</code> are retried under a second id
            automatically when the first is missing.</p>
          </details>
        </div>
        </body>
        </html>
        """
    }

    private static func previewBlock(_ preview: Preview) -> String {
        let body = preview.resolved.map(escape)
            ?? #"<span class="none">No URL — the addon's own poster is kept.</span>"#
        return #"<div class="preview"><strong>\#(escape(preview.label))</strong>\#(body)</div>"#
    }

    private static func screenRow(_ screen: (key: String, name: String, isOn: Bool)) -> String {
        """
        <label><input type="checkbox" name="screen_\(screen.key)" value="1"\
        \(screen.isOn ? " checked" : "")><span>\(escape(screen.name))</span></label>
        """
    }

    private static let tokenRows: String = [
        ("{id}", "The whole Stremio id — tt0903747, tmdb:1396, kitsu:7442"),
        ("{id_type}", "Which namespace that id is in — imdb, tmdb, kitsu…"),
        ("{typed_id}", "The form RPDB wants: tt0903747, or movie-1396 / series-1396"),
        ("{type}", "movie or series"),
        ("{shape}", "poster, landscape or square — include it to override wide artwork too"),
        ("{imdb_id}", "tt0903747"),
        ("{tmdb_id}", "The TMDB number, with no prefix"),
        ("{tvdb_id}", "The TVDB number"),
        ("{kitsu_id}", "The Kitsu number"),
        ("{anilist_id}", "The AniList number"),
        ("{mal_id}", "The MyAnimeList number"),
        ("{anidb_id}", "The AniDB number")
    ].map { "<tr><td>\(escape($0.0))</td><td>\($0.1)</td></tr>" }
        .joined(separator: "\n              ")

    /// The pattern is arbitrary text the viewer typed and it goes back into a textarea. Unescaped,
    /// a stray `</textarea>` would end the field and the rest would land in the document as markup.
    static func escape(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
