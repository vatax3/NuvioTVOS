#!/bin/bash
#
# Fails when a declared setting has no reader.
#
# The audit of 1.0.4 found 73 of 243 settings with no consumer, eleven of them behind a control a
# viewer could throw with no effect at all. The cause was mechanical — the stores were ported from
# Android's DataStores ahead of the features meant to read them, and the settings screens were
# built from the stores — so the guard has to be mechanical too, or the next store ported does it
# again.
#
# A setting counts as read when either is true:
#
#   * something outside `Sources/Data/` mentions it other than as a SwiftUI binding.
#     `$player.subtitleSize` is a control being drawn; `player.subtitleSize` is somebody acting on
#     the value. A setting that only ever appears with a `$` in front of it is a switch wired to
#     nothing.
#   * something else inside `Sources/Data/` mentions it — a store helper such as
#     `AppSettings.posterMetrics` or `subtitleStyle`, which the features then read instead of the
#     individual fields.
#
# Usage: Scripts/check-settings-wiring.sh
set -uo pipefail
cd "$(dirname "$0")/.."

# Settings whose only legitimate reader *is* the settings UI, because what they decide is which
# rows exist. Add here with the reason, never to silence a real finding.
ALLOWLIST="showsAdvancedSettings canStartTraktAuth canStartSimklAuth settingsUIStyle experienceModeChosen hasChosenLayout"

failures=0
report=""

for store in Sources/Data/*SettingsStore*.swift Sources/Data/SettingsStore.swift; do
  [ -f "$store" ] || continue
  while read -r name; do
    case " $ALLOWLIST " in *" $name "*) continue;; esac

    # Read by a helper next to it in the store layer, which the features read instead.
    instore=$(grep -rho "\b$name\b" Sources/Data/ --include='*.swift' | wc -l | tr -d ' ')
    [ "$instore" -gt 1 ] && continue

    outside=$(grep -rn "\b$name\b" Sources/ --include='*.swift' | grep -v '^Sources/Data/' || true)
    if [ -z "$outside" ]; then
      report="$report\n  $name — declared in ${store#Sources/Data/}, read nowhere"
      failures=$((failures+1))
      continue
    fi

    readers=$(printf '%s\n' "$outside" | grep -v "\$[A-Za-z_][A-Za-z0-9_]*\.$name\b" || true)
    if [ -z "$readers" ]; then
      report="$report\n  $name — has a control, but every mention of it is a binding"
      failures=$((failures+1))
    fi
  done < <(grep -oE '^    var [a-zA-Z0-9_]+' "$store" | awk '{print $2}' | sort -u)
done

if [ "$failures" -gt 0 ]; then
  printf 'error: %d setting(s) with no reader:%b\n\n' "$failures" "$report" >&2
  printf 'Either wire it up or delete it. A control that does nothing spends trust that an absent\n' >&2
  printf 'one would not, and an unread field is the state the inert controls grew out of.\n' >&2
  exit 1
fi

echo "settings wiring: every declared setting has a reader"
