#!/bin/bash
# Fetches the libmpv stack used by the internal MPV engine and trims it to tvOS slices.
#
# These are the same artifacts MPVKit resolves through SPM. They are fetched here instead because
# Xcode's resolver can stall on a GitHub credential prompt, and because ~300 MB of binaries do not
# belong in git.
#
# Run once after cloning, then: xcodegen generate && xcodebuild ...
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENDOR="$ROOT/Vendor"
VERSION="1.0.0"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

FRAMEWORKS=(
  "mpvkit/MPVKit:Libmpv" "mpvkit/MPVKit:Libavcodec" "mpvkit/MPVKit:Libavdevice"
  "mpvkit/MPVKit:Libavfilter" "mpvkit/MPVKit:Libavformat" "mpvkit/MPVKit:Libavutil"
  "mpvkit/MPVKit:Libswresample" "mpvkit/MPVKit:Libswscale"
  "mpvkit/gnutls-build:gmp" "mpvkit/gnutls-build:gnutls" "mpvkit/gnutls-build:hogweed"
  "mpvkit/gnutls-build:nettle" "mpvkit/lcms2-build:lcms2" "mpvkit/libass-build:Libass"
  "mpvkit/libass-build:Libfreetype" "mpvkit/libass-build:Libfribidi"
  "mpvkit/libass-build:Libharfbuzz" "mpvkit/libass-build:Libunibreak"
  "mpvkit/libbluray-build:Libbluray" "mpvkit/libdav1d-build:Libdav1d"
  "mpvkit/libdovi-build:Libdovi" "mpvkit/libplacebo-build:Libplacebo"
  "mpvkit/libshaderc-build:Libshaderc_combined" "mpvkit/libuavs3d-build:Libuavs3d"
  "mpvkit/libuchardet-build:Libuchardet" "mpvkit/moltenvk-build:MoltenVK"
  "mpvkit/openssl-build:Libcrypto" "mpvkit/openssl-build:Libssl"
)

mkdir -p "$VENDOR"
echo "Fetching ${#FRAMEWORKS[@]} xcframeworks into Vendor/ …"

for entry in "${FRAMEWORKS[@]}"; do
  repo="${entry%%:*}"
  name="${entry##*:}"
  [ -d "$VENDOR/$name.xcframework" ] && { echo "  · $name (present)"; continue; }
  echo "  ↓ $name"
  curl -sL --retry 3 --retry-delay 2 -o "$TMP/$name.zip" \
    "https://github.com/$repo/releases/download/$VERSION/$name.xcframework.zip"
  unzip -q -o "$TMP/$name.zip" -d "$VENDOR/"
done

# Keep only tvOS slices, and rewrite each Info.plist so it matches what is left on disk —
# Xcode refuses an xcframework whose plist lists a slice that is not there.
python3 - "$VENDOR" <<'PY'
import plistlib, shutil, sys, pathlib
vendor = pathlib.Path(sys.argv[1])
for fw in sorted(vendor.glob("*.xcframework")):
    for slice_dir in list(fw.iterdir()):
        if slice_dir.is_dir() and not slice_dir.name.startswith("tvos"):
            shutil.rmtree(slice_dir)
    plist = fw / "Info.plist"
    if not plist.exists():
        continue
    data = plistlib.loads(plist.read_bytes())
    data["AvailableLibraries"] = [
        lib for lib in data.get("AvailableLibraries", [])
        if (fw / lib["LibraryIdentifier"]).exists()
    ]
    plist.write_bytes(plistlib.dumps(data))
    if not data["AvailableLibraries"]:
        print(f"warning: {fw.name} has no tvOS slice", file=sys.stderr)
PY

echo "Done. $(du -sh "$VENDOR" | cut -f1) in Vendor/"
