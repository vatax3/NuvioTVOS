import Foundation

/// The page `LocalConfigServer` serves for the stream-format editor.
///
/// Written as one self-contained document with no external anything: it is served off a
/// television on a home network with no route to a CDN, and a phone that cannot load the
/// stylesheet would show an unusable form. It also has to work in a mobile browser one-handed,
/// which is why the two fields are the whole of it.
enum DebridFormatterPage {
    static func html(templates: DebridStreamTemplates, preview: DebridStreamFormatter.Rendered) -> String {
        """
        <!doctype html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>Nuvio — stream format</title>
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
          p.lede { margin: 0 0 28px; color: #9a9aa8; font-size: 15px; }
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
            padding: 14px; margin: 6px 0 28px; white-space: pre-wrap;
            font: 13px/1.5 ui-monospace, SFMono-Regular, Menlo, monospace; color: #c9c9d4;
          }
          .preview strong { display: block; color: #ececf1; font-size: 14px; margin-bottom: 6px; }
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
          <h1>Stream format</h1>
          <p class="lede">How each debrid result is labelled on the Apple TV. Saving takes effect on the next list of streams.</p>

          <div class="preview"><strong>\(escape(preview.name))</strong>\(escape(preview.description))</div>

          <form method="post">
            <div class="field">
              <label for="name">Name</label>
              <p class="hint">The bold line at the top of the row.</p>
              <textarea id="name" name="name" rows="3" spellcheck="false" autocapitalize="off" autocorrect="off">\(escape(templates.name))</textarea>
            </div>

            <div class="field">
              <label for="description">Description</label>
              <p class="hint">Everything under it. Line breaks are kept.</p>
              <textarea id="description" name="description" rows="10" spellcheck="false" autocapitalize="off" autocorrect="off">\(escape(templates.description))</textarea>
            </div>

            <div class="row">
              <button class="save" type="submit" name="action" value="save">Save</button>
              <button class="reset" type="submit" name="action" value="reset">Restore defaults</button>
            </div>
          </form>

          <details>
            <summary>Syntax</summary>
            <p>A field in braces is replaced by its value: <code>{stream.resolution}</code>.
            Add transforms after <code>::</code>, and a two-branch condition in brackets —
            <code>{stream.size::&gt;0["{stream.size::bytes} "||""]}</code> prints the size only
            when there is one.</p>
            <p><strong>Tests:</strong> <code>exists</code>, <code>istrue</code>,
            <code>isfalse</code>, <code>=value</code>, <code>~text</code>, <code>&gt;</code>,
            <code>&lt;</code>, <code>&gt;=</code>, <code>&lt;=</code>, joined with
            <code>and</code> / <code>or</code>.</p>
            <p><strong>Transforms:</strong> <code>title</code>, <code>lower</code>,
            <code>upper</code>, <code>bytes</code>, <code>time</code>,
            <code>join(' | ')</code>, <code>replace('a','b')</code>.</p>
            <table>
              \(fieldRows)
            </table>
          </details>
        </div>
        </body>
        </html>
        """
    }

    private static let fieldRows: String = [
        ("stream.title", "Release title as the addon gave it"),
        ("stream.year", "Year found in the title"),
        ("stream.resolution", "2160p, 1080p, 720p…"),
        ("stream.quality", "BluRay, WEB-DL, HDTV…"),
        ("stream.encode", "x265, AV1…"),
        ("stream.visualTags", "HDR, Dolby Vision, 10bit — a list"),
        ("stream.audioTags", "Atmos, DTS-HD, TrueHD — a list"),
        ("stream.audioChannels", "5.1, 7.1, stereo — a list"),
        ("stream.languages", "Languages detected in the release — a list"),
        ("stream.releaseGroup", "The group that released it"),
        ("stream.size", "File size. Use ::bytes to format it"),
        ("stream.filename", "Filename, when the addon supplies one"),
        ("stream.type", "torrent or http"),
        ("service.name", "Real-Debrid, Premiumize, TorBox"),
        ("service.shortName", "RD, PM, TB"),
        ("service.cached", "Whether the service already holds it"),
        ("addon.name", "The addon the stream came from")
    ].map { "<tr><td>\($0.0)</td><td>\($0.1)</td></tr>" }.joined(separator: "\n              ")

    /// A template is arbitrary text the viewer typed, and it goes back into the page inside a
    /// textarea. Unescaped, a stray `</textarea>` would end the field and the rest would land in
    /// the document as markup.
    static func escape(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// A stream to render the preview against, so the editor shows the shape of a real row
    /// rather than a form full of syntax.
    static var sampleStream: Stream {
        var stream = Stream(
            name: "Torrentio\n4k HDR",
            title: "Dune Part Two 2024 2160p UHD BluRay REMUX DV HDR TrueHD Atmos 7.1-FraMeSToR",
            addonName: "Torrentio"
        )
        stream.behaviorHints = StreamBehaviorHints(
            videoSize: 64_424_509_440,
            filename: "Dune.Part.Two.2024.2160p.UHD.BluRay.REMUX.DV.HDR.TrueHD.Atmos.7.1-FraMeSToR.mkv"
        )
        return stream
    }
}
