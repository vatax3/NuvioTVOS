#!/usr/bin/env python3
"""Build and validate the AltStore/SideStore/FlareStore source from GitHub releases."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import sys
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any


REPOSITORY = os.environ.get("GITHUB_REPOSITORY", "vatax3/NuvioTVOS")
ROOT = Path(__file__).resolve().parents[1]
SOURCE_PATH = ROOT / "altstore-source.json"
SOURCE_URL = (
    "https://raw.githubusercontent.com/"
    f"{REPOSITORY}/main/altstore-source.json"
)
RELEASE_DOWNLOAD_PREFIX = f"https://github.com/{REPOSITORY}/releases/download/"
# Earlier releases were packaged before the checked-in plist became the release source of truth,
# so their tags can claim a different version from the IPA. 1.0.13 is also the first build with
# a complete default Nuvio backend configuration, making it the safe floor for this update feed.
MINIMUM_PUBLISHED_VERSION = (1, 0, 13)
ICON_URL = (
    "https://raw.githubusercontent.com/"
    f"{REPOSITORY}/main/Resources/Brand/app_logo_mark.png"
)
SCREENSHOT_ROOT = (
    "https://raw.githubusercontent.com/"
    f"{REPOSITORY}/main/docs"
)


def request(url: str, *, accept: str = "application/vnd.github+json") -> bytes:
    headers = {
        "Accept": accept,
        "User-Agent": "NuvioTVOS-AltSource-Updater",
    }
    token = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN")
    if token and url.startswith("https://api.github.com/"):
        headers["Authorization"] = f"Bearer {token}"
        headers["X-GitHub-Api-Version"] = "2022-11-28"
    with urllib.request.urlopen(urllib.request.Request(url, headers=headers), timeout=30) as response:
        return response.read()


def request_json(url: str) -> Any:
    return json.loads(request(url).decode("utf-8"))


def release_version(tag: str) -> str | None:
    match = re.fullmatch(r"v?(\d+\.\d+\.\d+)", tag)
    return match.group(1) if match else None


def release_versions(tag: str) -> tuple[str, str]:
    """The marketing and build versions, read from `project.yml` at that tag.

    Not from the checked-in Info.plist, which is the wrong source of truth twice over: XcodeGen
    generates it *from* `project.yml`, and Xcode overrides its version keys with the build
    settings anyway. When the two disagreed, the plist was the one that was wrong — six releases
    shipped as build 19 through 24 while the plist still said 18.
    """
    url = f"https://raw.githubusercontent.com/{REPOSITORY}/{tag}/project.yml"
    text = request(url, accept="text/plain").decode("utf-8")

    def unique(setting: str) -> str:
        # Every target has to carry the same numbers — the extension ships inside the app. So
        # the values agreeing is the invariant, and reading them this way needs no YAML parser
        # and fails loudly if one target is ever bumped without the other.
        values = set(re.findall(rf'^\s*{setting}:\s*"?([^"\s#]+)"?\s*$', text, re.MULTILINE))
        if not values:
            raise ValueError(f"{tag}: project.yml declares no {setting}")
        if len(values) > 1:
            raise ValueError(f"{tag}: targets disagree on {setting}: {sorted(values)}")
        return values.pop()

    if not re.search(r"^\s*PRODUCT_BUNDLE_IDENTIFIER:\s*com\.nuvio\.tvos\s*$", text, re.MULTILINE):
        raise ValueError(f"{tag}: project.yml does not build com.nuvio.tvos")

    return unique("MARKETING_VERSION"), unique("CURRENT_PROJECT_VERSION")


def version_record(release: dict[str, Any]) -> dict[str, Any] | None:
    tag = str(release.get("tag_name", ""))
    version = release_version(tag)
    if version is None or release.get("draft") or release.get("prerelease"):
        return None
    if tuple(int(component) for component in version.split(".")) < MINIMUM_PUBLISHED_VERSION:
        return None

    # A qualifying release with no canonical IPA is an error, not a release to skip quietly.
    # Six releases were once packaged as `Nuvio-1.0.17.ipa` and friends, so every one of them was
    # passed over here, the regenerated feed came out byte-identical, the commit step found no
    # diff and exited zero — six green runs while the feed still advertised 1.0.16. Whatever is
    # wrong here, it has to be loud.
    expected_name = f"Nuvio-{version}-tvOS-unsigned.ipa"
    asset = next(
        (item for item in release.get("assets", []) if item.get("name") == expected_name),
        None,
    )
    if asset is None:
        found = ", ".join(str(item.get("name")) for item in release.get("assets", [])) or "none"
        raise ValueError(f"{tag}: no asset named {expected_name} (assets: {found})")

    marketing_version, build_version = release_versions(tag)
    if marketing_version != version:
        raise ValueError(f"{tag}: tag says {version}, project.yml says {marketing_version}")

    published_at = str(release.get("published_at") or release.get("created_at") or "")
    record: dict[str, Any] = {
        "version": version,
        "buildVersion": build_version,
        "date": published_at[:10],
        "localizedDescription": (
            str(release.get("body") or "").strip()
            or str(release.get("name") or f"Nuvio {version}")
        ),
        "downloadURL": str(asset["browser_download_url"]),
        "size": int(asset["size"]),
        "minOSVersion": "17.0",
    }
    digest = str(asset.get("digest") or "")
    if digest.startswith("sha256:") and len(digest) == len("sha256:") + 64:
        record["sha256"] = digest.removeprefix("sha256:")
    return record


def build_source() -> dict[str, Any]:
    releases = request_json(f"https://api.github.com/repos/{REPOSITORY}/releases?per_page=100")
    versions = [record for release in releases if (record := version_record(release))]
    if not versions:
        raise ValueError("No published release contains a canonical tvOS IPA")

    latest = versions[0]
    app: dict[str, Any] = {
        "name": "Nuvio",
        "bundleIdentifier": "com.nuvio.tvos",
        "developerName": "NuvioTVOS contributors",
        "subtitle": "A native Nuvio client for Apple TV.",
        "localizedDescription": (
            "An unofficial, native tvOS client for the Stremio addon ecosystem, designed to "
            "match NuvioTV for Android TV while respecting Apple TV navigation and playback. "
            "The IPA is unsigned and must be signed with a tvOS-compatible certificate."
        ),
        "iconURL": ICON_URL,
        "tintColor": "#E53935",
        "category": "entertainment",
        "screenshots": [
            {
                "imageURL": f"{SCREENSHOT_ROOT}/screenshot-home.png",
                "width": 3840,
                "height": 2160,
            },
            {
                "imageURL": f"{SCREENSHOT_ROOT}/screenshot-detail.png",
                "width": 3840,
                "height": 2160,
            },
            {
                "imageURL": f"{SCREENSHOT_ROOT}/screenshot-settings.png",
                "width": 3840,
                "height": 2160,
            },
        ],
        "versions": versions,
        "appPermissions": {
            "entitlements": ["com.apple.security.application-groups"],
            "privacy": {},
        },
        # Legacy top-level release keys keep older AltSource consumers useful.
        "version": latest["version"],
        "versionDate": latest["date"],
        "versionDescription": latest["localizedDescription"],
        "downloadURL": latest["downloadURL"],
        "size": latest["size"],
        "minOSVersion": latest["minOSVersion"],
    }
    return {
        "name": "Nuvio for Apple TV",
        "identifier": "com.nuvio.tvos.source",
        "subtitle": "Unsigned Nuvio builds for tvOS.",
        "description": (
            "Official sideloading source for the NuvioTVOS repository. Releases are read "
            "directly from GitHub and remain unsigned until installed with your certificate."
        ),
        "iconURL": ICON_URL,
        "headerURL": f"{SCREENSHOT_ROOT}/screenshot-home.png",
        "website": f"https://github.com/{REPOSITORY}",
        "sourceURL": SOURCE_URL,
        "tintColor": "#E53935",
        "featuredApps": ["com.nuvio.tvos"],
        "apps": [app],
        "news": [],
    }


def validate_source(source: dict[str, Any]) -> None:
    errors: list[str] = []
    for key in ("name", "identifier", "sourceURL", "apps"):
        if not source.get(key):
            errors.append(f"missing source key: {key}")
    if source.get("identifier") != "com.nuvio.tvos.source":
        errors.append("source identifier changed")
    if source.get("sourceURL") != SOURCE_URL:
        errors.append("sourceURL does not point to the canonical raw GitHub file")

    apps = source.get("apps")
    if not isinstance(apps, list) or len(apps) != 1:
        errors.append("source must contain exactly one app")
        apps = []
    if apps:
        app = apps[0]
        if app.get("bundleIdentifier") != "com.nuvio.tvos":
            errors.append("unexpected app bundle identifier")
        permissions = app.get("appPermissions", {})
        if "com.apple.security.application-groups" not in permissions.get("entitlements", []):
            errors.append("application-groups entitlement is not disclosed")
        versions = app.get("versions")
        if not isinstance(versions, list) or not versions:
            errors.append("app has no versions")
            versions = []
        seen: set[tuple[str, str]] = set()
        previous_date = "9999-99-99"
        for index, version in enumerate(versions):
            label = f"versions[{index}]"
            for key in ("version", "buildVersion", "date", "downloadURL", "size"):
                if version.get(key) in (None, ""):
                    errors.append(f"{label} missing {key}")
            identity = (str(version.get("version", "")), str(version.get("buildVersion", "")))
            if identity in seen:
                errors.append(f"duplicate version/build: {identity[0]} ({identity[1]})")
            seen.add(identity)
            date = str(version.get("date", ""))
            if date > previous_date:
                errors.append("versions are not in reverse chronological order")
            previous_date = date
            download_url = str(version.get("downloadURL", ""))
            if not download_url.startswith(RELEASE_DOWNLOAD_PREFIX) or not download_url.endswith(".ipa"):
                errors.append(f"{label} has a non-canonical download URL")
            if not isinstance(version.get("size"), int) or version.get("size", 0) <= 0:
                errors.append(f"{label} has an invalid size")
            digest = version.get("sha256")
            if digest and not re.fullmatch(r"[0-9a-f]{64}", str(digest)):
                errors.append(f"{label} has an invalid SHA-256")
        if versions:
            latest = versions[0]
            for legacy_key, version_key in (
                ("version", "version"),
                ("versionDate", "date"),
                ("downloadURL", "downloadURL"),
                ("size", "size"),
            ):
                if app.get(legacy_key) != latest.get(version_key):
                    errors.append(f"legacy {legacy_key} does not match the newest version")

    if errors:
        raise ValueError("Invalid AltSource:\n- " + "\n- ".join(errors))


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--validate", action="store_true", help="validate the checked-in source")
    args = parser.parse_args()

    if args.validate:
        source = json.loads(SOURCE_PATH.read_text(encoding="utf-8"))
        validate_source(source)
        print(f"Valid AltSource: {SOURCE_PATH}")
        return 0

    source = build_source()
    validate_source(source)
    serialized = json.dumps(source, ensure_ascii=False, indent=2) + "\n"
    SOURCE_PATH.write_text(serialized, encoding="utf-8")
    fingerprint = hashlib.sha256(serialized.encode("utf-8")).hexdigest()
    print(f"Updated {SOURCE_PATH} ({len(source['apps'][0]['versions'])} versions, sha256:{fingerprint})")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (ValueError, OSError, urllib.error.URLError, json.JSONDecodeError) as error:
        print(error, file=sys.stderr)
        raise SystemExit(1)
