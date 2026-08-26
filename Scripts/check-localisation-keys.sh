#!/bin/bash
#
# Fails when a localisation key has no entry, or when the two tables have drifted apart.
#
# The mechanism was here long before the coverage: `L10n` and the `en`/`fr` tables shipped early
# and the views went on holding English literals, so the tables and the source could disagree with
# nothing to notice. A missing key does not crash — `NSLocalizedString` falls back to the key
# itself, or to whatever `fallback:` says — so the failure mode is a screen that reads correctly
# in English and shows raw keys, or silent English, in French.
#
# Three checks:
#
#   * every key the source asks for exists in `en`
#   * every key the source asks for exists in `fr`
#   * the two tables carry exactly the same keys, so neither grows an orphan
#
# Usage: Scripts/check-localisation-keys.sh
set -uo pipefail
cd "$(dirname "$0")/.."

EN="Resources/en.lproj/Localizable.strings"
FR="Resources/fr.lproj/Localizable.strings"

for table in "$EN" "$FR"; do
  if [ ! -f "$table" ]; then
    echo "error: $table is missing" >&2
    exit 1
  fi
done

keys_in() {
  grep -oE '^"[^"]+"' "$1" | tr -d '"' | sort -u
}

# `L10n.text("key"` and `L10n.format("key"` — the only two entry points.
used_keys() {
  grep -rhoE 'L10n\.(text|format)\("[^"]+"' Sources \
    | sed -E 's/.*\("//; s/"$//' \
    | sort -u
}

en_keys=$(keys_in "$EN")
fr_keys=$(keys_in "$FR")
used=$(used_keys)

status=0

missing_en=$(comm -23 <(echo "$used") <(echo "$en_keys"))
if [ -n "$missing_en" ]; then
  echo "error: keys used in Sources with no entry in $EN:" >&2
  echo "$missing_en" | sed 's/^/  /' >&2
  status=1
fi

missing_fr=$(comm -23 <(echo "$used") <(echo "$fr_keys"))
if [ -n "$missing_fr" ]; then
  echo "error: keys used in Sources with no entry in $FR:" >&2
  echo "$missing_fr" | sed 's/^/  /' >&2
  status=1
fi

# A key in one table and not the other is a screen that silently reverts to English, which is the
# hardest kind of gap to see from the language you develop in.
only_en=$(comm -23 <(echo "$en_keys") <(echo "$fr_keys"))
if [ -n "$only_en" ]; then
  echo "error: keys in $EN with no French translation:" >&2
  echo "$only_en" | sed 's/^/  /' >&2
  status=1
fi

only_fr=$(comm -13 <(echo "$en_keys") <(echo "$fr_keys"))
if [ -n "$only_fr" ]; then
  echo "error: keys in $FR that no longer exist in $EN:" >&2
  echo "$only_fr" | sed 's/^/  /' >&2
  status=1
fi

# A key defined twice is not caught by anything else — the last one silently wins, so a stale
# translation can sit above a corrected one and nothing says which is in force.
for table in "$EN" "$FR"; do
  duplicates=$(grep -oE '^"[^"]+"' "$table" | sort | uniq -d)
  if [ -n "$duplicates" ]; then
    echo "error: keys defined more than once in $table:" >&2
    echo "$duplicates" | sed 's/^/  /' >&2
    status=1
  fi
done

# Reported, not failed: a key can legitimately land a release ahead of the screen that uses it,
# and failing the build for that would push somebody to add the string later instead of now.
orphans=$(comm -13 <(echo "$used") <(echo "$en_keys"))
if [ -n "$orphans" ]; then
  echo "note: defined but never asked for:"
  echo "$orphans" | sed 's/^/  /'
fi

if [ $status -eq 0 ]; then
  echo "Localisation: $(echo "$used" | wc -l | tr -d ' ') keys used, $(echo "$en_keys" | wc -l | tr -d ' ') defined in each table"
fi
exit $status
