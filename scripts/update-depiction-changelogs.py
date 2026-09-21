#!/usr/bin/env python3
"""Refresh native depiction changelogs from published GitHub releases."""

import argparse
import datetime
import json
from pathlib import Path
import re
import subprocess
import sys


DEPICTIONS = {
    "Fila": "Documentation/Site/depiction.json",
    "Inspector":"Documents/Site/depiction.json",
    "iGhostVT": "Documents/Site/depiction.json",
}


def fetch_releases(repository):
    """Let gh manage authentication and pagination without exposing credentials."""
    if "/" not in repository:
        repository = f"owngoal-dev/{repository}"
    if not valid_repository(repository):
        raise ValueError("Enter a GitHub repository as OWNER/NAME.")
    try:
        result = subprocess.run(
            [
                "gh", "api", "--paginate", "--slurp",
                f"repos/{repository}/releases?per_page=100",
            ],
            capture_output=True,
            text=True,
            check=False,
            timeout=120,
        )
    except (OSError, subprocess.TimeoutExpired):
        raise ValueError(
            f"Unable to fetch releases for {repository}. Check gh and your GitHub access."
        ) from None
    if result.returncode:
        raise ValueError(
            f"Unable to fetch releases for {repository}. Check your GitHub access and try again."
        )
    try:
        pages = json.loads(result.stdout)
    except json.JSONDecodeError:
        raise ValueError(f"Unable to read releases for {repository}. Try again.") from None
    if not isinstance(pages, list) or not all(isinstance(page, list) for page in pages):
        raise ValueError(f"Unable to read releases for {repository}. Try again.")
    return [release for page in pages for release in page]


def changelog_tab(releases, repository):
    published = []
    for release in releases:
        if not isinstance(release, dict):
            raise ValueError(f"Invalid release information for {repository}.")
        if not all(isinstance(release.get(key), bool) for key in ("draft", "prerelease")):
            raise ValueError(f"Invalid release information for {repository}.")
        if release["draft"] or release["prerelease"]:
            continue
        tag = release.get("tag_name")
        name = release.get("name")
        body = release.get("body")
        date = release.get("published_at")
        if (
            not isinstance(tag, str) or not tag.strip()
            or (name is not None and not isinstance(name, str))
            or (body is not None and not isinstance(body, str))
            or not isinstance(date, str)
        ):
            raise ValueError(f"Incomplete release information for {repository}.")
        if re.search(
            r"(^|[^A-Za-z0-9])(alpha|beta|rc|pre|preview|dev|nightly|snapshot)(?=[^A-Za-z]|$)",
            tag, re.IGNORECASE,
        ):
            continue
        try:
            timestamp = datetime.datetime.fromisoformat(date.replace("Z", "+00:00"))
            if timestamp.utcoffset() is None:
                raise ValueError
        except ValueError:
            raise ValueError(f"Invalid release date for {repository}.") from None
        published.append((timestamp, tag, name, body))
    if not published:
        return None
    published.sort(key=lambda release: (release[0], release[1]), reverse=True)
    views = []
    for timestamp, tag, name, body in published:
        # ISO dates remain unambiguous regardless of the machine's locale.
        views.append({
            "class": "DepictionLayerView",
            "views": [
                {
                    "class": "DepictionLabelView",
                    "text": name if name and name.strip() else tag,
                    "fontWeight": "bold",
                    "fontSize": 16,
                },
                {
                    "class": "DepictionLabelView",
                    "text": timestamp.astimezone(datetime.timezone.utc).date().isoformat(),
                    "fontWeight": "semibold",
                    "fontSize": 16,
                    "textColor": "#696969",
                    "alignment": 2,
                },
            ],
        })
        if body:
            views.append({"class": "DepictionMarkdownView", "markdown": body})
        views.append({"class": "DepictionSeparatorView"})
    return {"class": "DepictionStackView", "tabname": "Changelog", "views": views}


def refresh(workspace, repositories, fetch=fetch_releases, depiction_path=None):
    pending = []
    # Validate every depiction and response before changing any file.
    for repository in repositories:
        path = depiction_path if depiction_path is not None else workspace / repository / DEPICTIONS[repository]
        try:
            original = path.read_text(encoding="utf-8")
            depiction = json.loads(original)
        except (OSError, UnicodeError, json.JSONDecodeError):
            raise ValueError(
                f"Unable to read the depiction for {repository}. Check the workspace path and file."
            ) from None
        if (
            not isinstance(depiction, dict)
            or depiction.get("class") != "DepictionTabView"
            or not isinstance(depiction.get("tabs"), list)
            or not all(isinstance(tab, dict) for tab in depiction["tabs"])
        ):
            raise ValueError(f"Invalid depiction for {repository}.")
        tab = changelog_tab(fetch(repository), repository)
        tabs = []
        replaced = False
        for existing in depiction["tabs"]:
            if existing.get("tabname") == "Changelog":
                if tab is not None and not replaced:
                    tabs.append(tab)
                    replaced = True
            else:
                tabs.append(existing)
        if tab is not None and not replaced:
            tabs.append(tab)
        depiction["tabs"] = tabs
        updated = json.dumps(depiction, indent=4, ensure_ascii=False) + "\n"
        if updated != original:
            pending.append((path, updated))
    for path, updated in pending:
        path.write_text(updated, encoding="utf-8")
    return [path for path, _ in pending]


def valid_repository(repository):
    return re.fullmatch(
        r"[A-Za-z0-9](?:[A-Za-z0-9-]{0,37}[A-Za-z0-9])?/[A-Za-z0-9_.-]+",
        repository,
    ) is not None and repository.split("/")[1] not in (".", "..")


def parse_arguments(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--workspace", type=Path,
        default=Path(__file__).resolve().parents[2],
        help="Parent directory containing the three app repositories.",
    )
    selection = parser.add_mutually_exclusive_group()
    selection.add_argument(
        "--repo", choices=tuple(DEPICTIONS), action="append",
        help="Update only this repository; repeat to select more than one.",
    )
    selection.add_argument(
        "--repository", metavar="OWNER/NAME",
        help="Fetch releases for this GitHub repository; requires --depiction.",
    )
    parser.add_argument(
        "--depiction", type=Path, metavar="PATH",
        help="Update this depiction file; requires --repository.",
    )
    args = parser.parse_args(argv)
    if bool(args.repository) != (args.depiction is not None):
        parser.error("Use --repository and --depiction together.")
    if args.repository and not valid_repository(args.repository):
        parser.error("Enter a GitHub repository as OWNER/NAME.")
    return args


def main(argv=None):
    args = parse_arguments(argv)
    repositories = [args.repository] if args.repository else list(dict.fromkeys(args.repo or DEPICTIONS))
    try:
        changed = refresh(args.workspace, repositories, depiction_path=args.depiction)
    except (ValueError, OSError) as error:
        if isinstance(error, OSError):
            print("Unable to save the depictions. Check file permissions and try again.", file=sys.stderr)
        else:
            print(error, file=sys.stderr)
        return 1
    for path in changed:
        print(f"Updated {path}")
    if not changed:
        print("Changelogs are up to date.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
