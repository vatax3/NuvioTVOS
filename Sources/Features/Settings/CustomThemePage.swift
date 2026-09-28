import Foundation

/// The page `LocalConfigServer` serves for the custom theme's accent.
///
/// The one page of the five where the phone's own controls do the work: `<input type="color">` is
/// a native colour picker on every mobile browser, which is exactly the thing a D-pad cannot be.
/// The hex field sits beside it for anyone who already knows the value they want.
///
/// Self-contained like the others — served off a television on a home network, so a stylesheet
/// from anywhere else would leave the phone with an unusable form.
enum CustomThemePage {
    static func html(accentHex: String) -> String {
        let hex = CustomThemePalette.components(fromHex: accentHex).map(CustomThemePalette.hex)
            ?? CustomThemePalette.defaultHex
        return """
        <!doctype html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>Nuvio — custom theme</title>
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
          .pick { display: flex; gap: 14px; align-items: center; margin-bottom: 26px; }
          input[type=color] {
            appearance: none; -webkit-appearance: none; border: 0; padding: 0;
            width: 96px; height: 96px; border-radius: 16px; background: none; cursor: pointer;
          }
          input[type=color]::-webkit-color-swatch-wrapper { padding: 0; }
          input[type=color]::-webkit-color-swatch { border: 1px solid #2c2c38; border-radius: 16px; }
          input[type=text] {
            flex: 1; background: #191920; color: #ececf1;
            border: 1px solid #2c2c38; border-radius: 10px; padding: 14px 12px;
            font: 16px/1.2 ui-monospace, SFMono-Regular, Menlo, monospace;
            text-transform: uppercase; -webkit-appearance: none;
          }
          input:focus { outline: 2px solid #4fc9dd; outline-offset: 1px; border-color: transparent; }
          .row { display: flex; gap: 10px; flex-wrap: wrap; }
          button {
            flex: 1 1 160px; padding: 13px 18px; border-radius: 10px; border: 0;
            font: 600 16px/1 -apple-system, system-ui, sans-serif; cursor: pointer;
          }
          button.save { background: #4fc9dd; color: #06222a; }
          button.reset { background: #24242e; color: #ececf1; }
          .note { margin-top: 30px; border-top: 1px solid #24242e; padding-top: 18px;
                  color: #9a9aa8; font-size: 14px; }
        </style>
        </head>
        <body>
        <div class="wrap">
          <h1>Custom theme</h1>
          <p class="lede">One accent colour. The pressed shade, the focus ring and the card
          background follow from it, the way each built-in theme's do.</p>

          <form method="post">
            <label for="picker">Accent</label>
            <p class="hint">Tap the square for your phone's colour picker, or type a hex value.</p>
            <div class="pick">
              <input type="color" id="picker" value="#\(hex)"
                     oninput="document.getElementById('accent').value = this.value.slice(1).toUpperCase()">
              <input type="text" id="accent" name="accent" value="\(hex)"
                     spellcheck="false" autocapitalize="characters" autocorrect="off"
                     inputmode="latin" maxlength="7"
                     oninput="if (/^#?[0-9a-fA-F]{6}$/.test(this.value)) {
                                document.getElementById('picker').value =
                                  '#' + this.value.replace('#','');
                              }">
            </div>

            <div class="row">
              <button class="save" type="submit" name="action" value="save">Save</button>
              <button class="reset" type="submit" name="action" value="reset">Restore default</button>
            </div>
          </form>

          <p class="note">Judge it on the television rather than here: the focus ring is what tells
          you where you are on screen, and a colour that reads well on a phone can disappear against
          the picture across a room. The Apple TV shows a preview as soon as you save.</p>
        </div>
        </body>
        </html>
        """
    }
}
