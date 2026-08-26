import Foundation

/// The page `LocalConfigServer` serves for plugin repositories.
///
/// Nothing here changes anything on its own: every button posts a *request*, and the television
/// asks the viewer. The page's job while that is happening is to say so — hence the refresh
/// header, which is the whole of its liveness with no script and no fetch.
enum RepositoryConfigPage {
    struct Row {
        var id: String
        var name: String
        var manifestUrl: String
        var detail: String
        var isEnabled: Bool
    }

    static func html(rows: [Row], notice: String?, isWaiting: Bool) -> String {
        """
        <!doctype html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        \(isWaiting ? #"<meta http-equiv="refresh" content="2">"# : "")
        <title>Nuvio — plugin repositories</title>
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
          h2 { font-size: 17px; margin: 30px 0 12px; }
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
          input[disabled], button[disabled] { opacity: .45; }
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
          .notice.waiting { border-left-color: #e0b341; }
          .repo {
            background: #16161d; border: 1px solid #24242e; border-radius: 10px;
            padding: 14px; margin-bottom: 12px;
          }
          .repo.off { opacity: .6; }
          .repo .name { font-weight: 600; margin: 0 0 2px; }
          .repo .url {
            font: 12.5px/1.45 ui-monospace, SFMono-Regular, Menlo, monospace;
            color: #9a9aa8; word-break: break-all; margin: 0 0 4px;
          }
          .repo .meta { color: #9a9aa8; font-size: 13px; margin: 0 0 11px; }
          .actions { display: flex; gap: 8px; flex-wrap: wrap; }
          .actions form { margin: 0; }
          .empty { color: #9a9aa8; font-size: 14.5px; }
        </style>
        </head>
        <body>
        <div class="wrap">
          <h1>Plugin repositories</h1>
          <p class="lede">Scrapers Nuvio asks alongside your addons. Every change here is confirmed on the Apple TV before it happens.</p>

          \(noticeBlock(notice, isWaiting: isWaiting))

          <form method="post">
            <div class="field">
              <label for="url">Add a repository</label>
              <p class="hint">A link to a plugin <code>manifest.json</code>.</p>
              <input id="url" name="url" type="url" inputmode="url" spellcheck="false"
                     autocapitalize="off" autocorrect="off" \(isWaiting ? "disabled" : "")
                     placeholder="https://example.com/plugins/manifest.json">
            </div>
            <button class="save" type="submit" name="action" value="add" \(isWaiting ? "disabled" : "")>Request</button>
          </form>

          <h2>Installed</h2>
          \(rows.isEmpty
            ? #"<p class="empty">None yet.</p>"#
            : rows.map { row($0, isWaiting: isWaiting) }.joined(separator: "\n          "))
        </div>
        </body>
        </html>
        """
    }

    private static func noticeBlock(_ notice: String?, isWaiting: Bool) -> String {
        guard let notice, !notice.isEmpty else { return "" }
        return #"<p class="notice\#(isWaiting ? " waiting" : "")">\#(escape(notice))</p>"#
    }

    private static func row(_ row: Row, isWaiting: Bool) -> String {
        let disabled = isWaiting ? "disabled" : ""
        return """
        <div class="repo\(row.isEnabled ? "" : " off")">
                <p class="name">\(escape(row.name))</p>
                <p class="url">\(escape(row.manifestUrl))</p>
                <p class="meta">\(escape(row.detail))</p>
                <div class="actions">
                  <form method="post">
                    <input type="hidden" name="id" value="\(escape(row.id))">
                    <button class="small" type="submit" name="action" value="toggle" \(disabled)>\(row.isEnabled ? "Turn off" : "Turn on")</button>
                  </form>
                  <form method="post">
                    <input type="hidden" name="id" value="\(escape(row.id))">
                    <button class="small danger" type="submit" name="action" value="remove" \(disabled)>Remove</button>
                  </form>
                </div>
              </div>
        """
    }

    static func escape(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
