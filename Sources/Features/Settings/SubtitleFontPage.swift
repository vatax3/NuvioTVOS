import Foundation

/// The phone page for importing a subtitle font — upstream's `SubtitleFontWebPage`
/// (1.2.0-beta.1): one file input, posted raw to `/api/font` with its name in `X-File-Name`.
enum SubtitleFontPage {
    static func html() -> String {
        let title = escape(L10n.text("web.subtitle_font_title", fallback: "Subtitle Fonts"))
        let subtitle = escape(L10n.text(
            "web.subtitle_font_subtitle", fallback: "Choose a .ttf or .otf file to use it for subtitles on your TV."
        ))
        let choose = escape(L10n.text("web.subtitle_font_choose", fallback: "Choose Font File"))
        let uploading = js(L10n.text("web.subtitle_font_uploading", fallback: "Uploading…"))
        let added = js(L10n.text("web.subtitle_font_added", fallback: "Added to your TV"))
        let error = js(L10n.text(
            "web.subtitle_font_error",
            fallback: "Could not import this font. Choose a valid .ttf or .otf file under 10 MB."
        ))
        let connection = js(L10n.text("web.subtitle_font_connection_error", fallback: "Connection error"))
        return """
        <!doctype html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1, user-scalable=no">
        <title>Nuvio — \(title)</title>
        <style>
          :root { color-scheme: dark; }
          * { margin: 0; padding: 0; box-sizing: border-box; -webkit-tap-highlight-color: transparent; }
          body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif; background: #000; color: #fff; min-height: 100vh; line-height: 1.5; }
          .page { max-width: 600px; margin: 0 auto; padding: 0 1.5rem 6rem; }
          .header { text-align: center; padding: 3rem 0 2.5rem; border-bottom: 1px solid rgba(255,255,255,0.06); margin-bottom: 2.5rem; }
          .header h1 { font-size: 1.5rem; font-weight: 700; }
          .header p { font-size: 0.875rem; font-weight: 300; color: rgba(255,255,255,0.42); }
          .intro { color: rgba(255,255,255,0.44); font-size: 0.875rem; font-weight: 300; margin-bottom: 2rem; }
          .actions { display: flex; gap: 0.75rem; margin-top: 1.25rem; }
          .btn { display: inline-flex; align-items: center; justify-content: center; flex: 1; border: 1px solid rgba(255,255,255,0.2); border-radius: 100px; padding: 0.875rem 1.3rem; color: #fff; font-size: 0.875rem; font-weight: 500; cursor: pointer; }
          .btn:hover { background: #fff; color: #000; border-color: #fff; }
          input[type=file] { display: none; }
          .status { color: rgba(135,239,172,0.95); font-size: 0.875rem; font-weight: 300; min-height: 24px; margin-top: 1rem; text-align: center; }
          .status.error { color: rgba(207,102,121,0.9); }
        </style>
        </head>
        <body>
        <div class="page">
          <div class="header"><h1>Nuvio</h1><p>\(title)</p></div>
          <div class="intro">\(subtitle)</div>
          <div class="actions"><label class="btn" for="font">\(choose)</label></div>
          <input id="font" type="file" accept=".ttf,.otf">
          <div class="status" id="status"></div>
        </div>
        <script>
        const input=document.getElementById('font');
        const statusBox=document.getElementById('status');
        function show(text,failed){statusBox.textContent=text;statusBox.className=failed?'status error':'status'}
        input.addEventListener('change',async()=>{
          const file=input.files[0];
          if(!file)return;
          show(\(uploading),false);
          try{
            const response=await fetch('/api/font',{method:'POST',
              headers:{'Content-Type':'application/octet-stream','X-File-Name':encodeURIComponent(file.name)},body:file});
            if(response.ok){show(\(added),false)}else{show(\(error),true)}
          }catch(e){show(\(connection),true)}
          input.value='';
        });
        </script>
        </body>
        </html>
        """
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// A JavaScript string literal, via JSON so quotes and line breaks are safe.
    private static func js(_ text: String) -> String {
        (try? String(data: JSONEncoder().encode(text), encoding: .utf8)) ?? "\"\""
    }
}
