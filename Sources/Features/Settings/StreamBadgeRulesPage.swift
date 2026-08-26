import Foundation

/// The page `LocalConfigServer` serves for badge rules.
///
/// Same constraints as the format editor: one self-contained document, served off a television on
/// a network with no route to a CDN, usable one-handed in a mobile browser. The difference is that
/// this form has a list in it — the packs already imported, each with the two things a viewer
/// actually wants to do to one, and the count of rules it contributes.
enum StreamBadgeRulesPage {
    static func html(rules: StreamBadgeRules, notice: String?) -> String {
        """
        <!doctype html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>Nuvio — badge rules</title>
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
          p.lede { margin: 0 0 24px; color: #9a9aa8; font-size: 15px; }
          label { display: block; font-weight: 600; margin: 0 0 6px; font-size: 15px; }
          .hint { color: #9a9aa8; font-size: 13px; margin: 0 0 8px; }
          input[type=url] {
            width: 100%; background: #191920; color: #ececf1;
            border: 1px solid #2c2c38; border-radius: 10px; padding: 12px;
            font: 14px/1.4 ui-monospace, SFMono-Regular, Menlo, monospace;
            -webkit-appearance: none;
          }
          input[type=url]:focus { outline: 2px solid #4fc9dd; outline-offset: 1px; border-color: transparent; }
          .field { margin-bottom: 22px; }
          button {
            padding: 13px 18px; border-radius: 10px; border: 0;
            font: 600 16px/1 -apple-system, system-ui, sans-serif; cursor: pointer;
          }
          button.save { background: #4fc9dd; color: #06222a; width: 100%; }
          button.small { padding: 8px 13px; font-size: 14px; background: #24242e; color: #ececf1; }
          button.small.danger { background: #3a1d22; color: #ff9d9d; }
          .notice {
            background: #16161d; border: 1px solid #2c2c38; border-left: 3px solid #4fc9dd;
            border-radius: 8px; padding: 11px 13px; margin: 0 0 22px; font-size: 14.5px;
          }
          .pack {
            background: #16161d; border: 1px solid #24242e; border-radius: 10px;
            padding: 14px; margin-bottom: 12px;
          }
          .pack.active { border-color: #4fc9dd; }
          .pack .url {
            font: 12.5px/1.45 ui-monospace, SFMono-Regular, Menlo, monospace;
            color: #c9c9d4; word-break: break-all; margin: 0 0 4px;
          }
          .pack .meta { color: #9a9aa8; font-size: 13px; margin: 0 0 11px; }
          .pack .meta .on { color: #4fc9dd; font-weight: 600; }
          .actions { display: flex; gap: 8px; flex-wrap: wrap; }
          .actions form { margin: 0; }
          .empty { color: #9a9aa8; font-size: 14.5px; margin: 0 0 22px; }
          details { margin-top: 34px; border-top: 1px solid #24242e; padding-top: 18px; }
          summary { cursor: pointer; font-weight: 600; }
          code { background: #191920; padding: 1px 5px; border-radius: 4px; font-size: 12.5px; }
          pre {
            background: #191920; border-radius: 8px; padding: 12px; overflow-x: auto;
            font: 12.5px/1.5 ui-monospace, SFMono-Regular, Menlo, monospace; color: #c9c9d4;
          }
        </style>
        </head>
        <body>
        <div class="wrap">
          <h1>Badge rules</h1>
          <p class="lede">Named patterns matched against every source. A rule that matches puts its badge on the row.</p>

          \(noticeBlock(notice))

          <form method="post">
            <div class="field">
              <label for="url">Add a badge pack</label>
              <p class="hint">A link to a badge JSON file. Re-adding a link you already have updates it in place.</p>
              <input id="url" name="url" type="url" inputmode="url" spellcheck="false"
                     autocapitalize="off" autocorrect="off" placeholder="https://example.com/badges.json">
            </div>
            <button class="save" type="submit" name="action" value="import">Import</button>
          </form>

          <h2 style="font-size:17px;margin:30px 0 12px;">Imported</h2>
          \(packList(rules))

          <details>
            <summary>What a badge file looks like</summary>
            <p>A JSON object with a <code>filters</code> array. Each filter needs a
            <code>name</code> and a <code>pattern</code> — a regular expression matched against the
            filename, title, description and detected tags of every source. Everything else is
            optional.</p>
            <pre>\(sampleFile)</pre>
            <p>Up to \(StreamBadgeRuleLimits.importLimit) packs can be held at once and one is
            applied. Colours are CSS hex; leave them out for the app's own styling.</p>
          </details>
        </div>
        </body>
        </html>
        """
    }

    /// Held apart from the page because `<pre>` keeps its whitespace: indenting it to sit inside
    /// the document literal would indent it on the phone too.
    private static let sampleFile = escape(#"""
    {
      "filters": [
        {
          "name": "Atmos",
          "pattern": "(?i)\\batmos\\b",
          "tagColor": "#3B1E54",
          "tagStyle": "filled",
          "textColor": "#EBD3F8"
        }
      ]
    }
    """#)

    private static func noticeBlock(_ notice: String?) -> String {
        guard let notice, !notice.isEmpty else { return "" }
        return #"<p class="notice">\#(escape(notice))</p>"#
    }

    private static func packList(_ rules: StreamBadgeRules) -> String {
        guard rules.hasImport else {
            return #"<p class="empty">No packs yet. Streams show the app's own badges until you add one.</p>"#
        }
        return rules.imports.map(pack).joined(separator: "\n          ")
    }

    private static func pack(_ entry: StreamBadgeImport) -> String {
        let rules = entry.filters.count == 1 ? "1 rule" : "\(entry.filters.count) rules"
        let enabled = entry.enabledFilterCount == entry.filters.count
            ? ""
            : " · \(entry.enabledFilterCount) on"
        let state = entry.isActive
            ? #"<span class="on">Applied</span> · \#(rules)\#(enabled)"#
            : "\(rules)\(enabled)"

        // Activate is pointless on the pack that is already applied, and offering it anyway is
        // how a list of identical buttons stops telling you anything.
        let activate = entry.isActive ? "" : """
        <form method="post">
                  <input type="hidden" name="url" value="\(escape(entry.sourceUrl))">
                  <button class="small" type="submit" name="action" value="activate">Apply this one</button>
                </form>
        """

        return """
        <div class="pack\(entry.isActive ? " active" : "")">
                <p class="url">\(escape(entry.sourceUrl))</p>
                <p class="meta">\(state)</p>
                <div class="actions">
                  \(activate)
                  <form method="post">
                    <input type="hidden" name="url" value="\(escape(entry.sourceUrl))">
                    <button class="small" type="submit" name="action" value="refresh">Re-fetch</button>
                  </form>
                  <form method="post">
                    <input type="hidden" name="url" value="\(escape(entry.sourceUrl))">
                    <button class="small danger" type="submit" name="action" value="remove">Remove</button>
                  </form>
                </div>
              </div>
        """
    }

    /// The URL is whatever the viewer typed and it goes back into the document inside an
    /// attribute — unescaped, a quote in it would end the attribute and the rest would be markup.
    static func escape(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
