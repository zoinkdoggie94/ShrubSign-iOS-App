#!/usr/bin/env python3
"""Keep ShrubSign's AltStore repo.json in sync with successfully published releases.

Called by .github/workflows/beta.yml after gh release create succeeds.
Preserves unrelated repo metadata and previously published version entries.
"""

from __future__ import annotations

import base64
import json
import os
from pathlib import Path
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request


API_ROOT = "https://api.github.com"
IPA_FILENAME = "ShrubSign.ipa"
RELEASE_TAG_PATTERN = re.compile(r"^v(?P<version>\d+\.\d+\.\d+)-build-\d+\.\d+$")


def api(method: str, path: str, payload: dict | None = None) -> dict | list:
    token = os.environ["GH_TOKEN"]
    request = urllib.request.Request(
        f"{API_ROOT}{path}",
        method=method,
        headers={
            "Authorization": f"Bearer {token}",
            "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28",
            "User-Agent": "ShrubSign-repo-sync",
            "Content-Type": "application/json",
        },
        data=None if payload is None else json.dumps(payload).encode("utf-8"),
    )
    with urllib.request.urlopen(request, timeout=25) as response:
        return json.load(response)


def project_version() -> tuple[str, str]:
    project = Path("ShrubSign.xcodeproj/project.pbxproj").read_text()
    version = re.search(r"\bMARKETING_VERSION\s*=\s*([\d.]+)\s*;", project)
    build = re.search(r"\bCURRENT_PROJECT_VERSION\s*=\s*(\d+)\s*;", project)
    if not version or not build:
        raise ValueError("Cannot find ShrubSign version and build in Xcode project")
    return version.group(1), build.group(1)


def ipa_download(release: dict) -> str | None:
    return next(
        (asset.get("browser_download_url") for asset in release.get("assets", [])
         if asset.get("name") == IPA_FILENAME and asset.get("browser_download_url")),
        None,
    )


def recent_releases(repo: str) -> list[dict]:
    # Older releases remain available on GitHub regardless of this listing.
    releases = []
    for page in range(1, 4):
        batch = api("GET", f"/repos/{repo}/releases?per_page=100&page={page}")
        if not isinstance(batch, list):
            raise ValueError("GitHub release listing was not an array")
        releases.extend(r for r in batch if isinstance(r, dict) and not r.get("draft"))
        if len(batch) < 100:
            break
    return releases


def update_document(document: dict, release: dict, releases: list[dict], version: str, build: str) -> dict:
    apps = document.get("apps")
    if not isinstance(apps, list):
        raise ValueError("repo.json is missing its apps array")
    app = next((a for a in apps if isinstance(a, dict) and
                a.get("bundleIdentifier") == "com.shrubhub.shrubsign"), None)
    if app is None:
        raise ValueError("ShrubSign app entry not found; refusing to overwrite repo.json")
    url = ipa_download(release)
    if not url:
        raise ValueError("Current release is missing ShrubSign.ipa; refusing to update repo.json")
    release_date = release.get("published_at") or release.get("created_at")
    if not release_date:
        raise ValueError("Current release has no publication timestamp")

    versions = app.get("versions", [])
    if not isinstance(versions, list):
        raise ValueError("repo.json versions is not an array")
    historical = []
    for entry in versions:
        if not isinstance(entry, dict):
            continue
        # Replace the same version/build entry; never duplicate it.
        if str(entry.get("version")) == version and str(entry.get("buildVersion")) == build:
            continue
        old_url = str(entry.get("downloadURL", ""))
        if "/releases/latest/download/" in old_url:
            # Repair an old bug: a 3.0 entry must never download the latest (3.1) IPA.
            candidates = [r for r in releases if (
                (m := RELEASE_TAG_PATTERN.fullmatch(r.get("tag_name", ""))) and
                m.group("version") == str(entry.get("version")) and ipa_download(r)
            )]
            if candidates:
                newest = max(candidates, key=lambda r: r.get("published_at") or "")
                entry["downloadURL"] = ipa_download(newest)
            else:
                print(f"WARNING: No permanent URL found for historical version {entry.get('version')}", file=sys.stderr)
        historical.append(entry)

    entry = {
        "downloadURL": url,
        "version": version,
        "buildVersion": build,
        "date": release_date,
        "localizedDescription": (
            "ShrubSign 3.2 with faster IPA packaging, safer signing recovery, "
            "ShrubLibrary, IPA Inspector, Tweak Studio, and workflow improvements."
        ),
        "minOSVersion": "16.0",
    }
    app["versions"] = [entry, *historical]
    app["version"] = version
    app["versionDate"] = release_date
    app["downloadURL"] = url
    app["localizedDescription"] = (
        "ShrubSign is an iOS IPA signer with ShrubLibrary integration, Quick Sign, "
        "IPA Inspector, Tweak Studio, a signing history center, and certificate tools."
    )
    return document


def main() -> None:
    repo = os.environ["GITHUB_REPOSITORY"]
    tag = os.environ["RELEASE_TAG"]
    version, build = project_version()
    expected_tag_prefix = f"v{version}-build-"
    if not tag.startswith(expected_tag_prefix):
        raise ValueError(f"Release tag {tag} doesn't match Xcode version {version}")

    release = api("GET", f"/repos/{repo}/releases/tags/{urllib.parse.quote(tag, safe='')}")
    releases = recent_releases(repo)
    path = f"/repos/{repo}/contents/repo.json"

    for attempt in range(3):
        remote = api("GET", f"{path}?ref=main")
        if not isinstance(remote, dict) or remote.get("encoding") != "base64":
            raise ValueError("Unexpected GitHub contents API response")
        raw = base64.b64decode(remote["content"])
        document = json.loads(raw.decode("utf-8"))
        updated = update_document(document, release, releases, version, build)
        encoded = (json.dumps(updated, indent=2, ensure_ascii=False) + "\n").encode("utf-8")
        if raw == encoded:
            print(f"repo.json already matches {version} build {build}")
            return
        message = f"Sync repo.json with ShrubSign {version} ({tag}) [skip ci]"
        payload = {
            "message": message,
            "content": base64.b64encode(encoded).decode("ascii"),
            "sha": remote["sha"],
            "branch": "main",
        }
        try:
            api("PUT", path, payload)
            print(f"Updated repo.json to ShrubSign {version} ({tag}), kept {len(next(a for a in updated['apps'] if a.get('bundleIdentifier') == 'com.shrubhub.shrubsign')['versions']) - 1} historical entries")
            return
        except urllib.error.HTTPError as exc:
            if exc.code not in (409, 422) or attempt == 2:
                raise
            print("Repository changed while updating. Retrying with current repo.json...")
            time.sleep(1)


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, urllib.error.HTTPError) as error:
        print(f"ERROR updating repo.json: {error}", file=sys.stderr)
        sys.exit(1)
