#!/usr/bin/env python3
"""Preview or apply llm4cj's versioned GitHub repository settings."""

from __future__ import annotations

import argparse
import json
import os
import re
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_SETTINGS = ROOT / ".github/settings.yml"
REPOSITORY_RE = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$")
EXPECTED_CONTEXTS = {
    "verify (minimum-1.1.0)",
    "verify (stable-latest)",
    "coverage",
    "contract",
    "pr-metadata",
}


def load_settings(path: Path = DEFAULT_SETTINGS) -> dict[str, Any]:
    with path.open(encoding="utf-8") as handle:
        settings = json.load(handle)
    repository = settings.get("repository")
    protection = settings.get("branch_protection")
    if not isinstance(repository, dict) or not isinstance(protection, dict):
        raise ValueError("settings must define repository and branch_protection objects")
    if repository.get("default_branch") != "main" or protection.get("branch") != "main":
        raise ValueError("main must remain the repository default and protected branch")
    checks = protection.get("required_status_checks")
    contexts = checks.get("contexts") if isinstance(checks, dict) else None
    if not isinstance(contexts, list) or set(contexts) != EXPECTED_CONTEXTS:
        raise ValueError("branch protection required checks do not match repository policy")
    if repository.get("allow_squash_merge") is not True:
        raise ValueError("squash merge must remain enabled")
    if repository.get("allow_merge_commit") is not False:
        raise ValueError("merge commits must remain disabled")
    if repository.get("allow_rebase_merge") is not False:
        raise ValueError("rebase merge must remain disabled")
    return settings


def requests_for(
    repository_name: str, settings: dict[str, Any]
) -> tuple[tuple[str, str, dict[str, Any]], ...]:
    if not REPOSITORY_RE.fullmatch(repository_name):
        raise ValueError("repository must use the owner/name form")
    repository = dict(settings["repository"])
    protection = dict(settings["branch_protection"])
    branch = urllib.parse.quote(str(protection.pop("branch")), safe="")
    base = f"/repos/{repository_name}"
    return (
        ("PATCH", base, repository),
        ("PUT", f"{base}/branches/{branch}/protection", protection),
    )


def send(token: str, method: str, path: str, payload: dict[str, Any]) -> None:
    request = urllib.request.Request(
        f"https://api.github.com{path}",
        data=json.dumps(payload).encode("utf-8"),
        method=method,
        headers={
            "Accept": "application/vnd.github+json",
            "Authorization": f"Bearer {token}",
            "Content-Type": "application/json",
            "User-Agent": "llm4cj-repository-bootstrap",
            "X-GitHub-Api-Version": "2022-11-28",
        },
    )
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            response.read()
    except urllib.error.HTTPError as error:
        detail = error.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"GitHub API {method} {path} failed: {detail}") from error


def main(arguments: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repository", required=True, help="GitHub owner/name")
    parser.add_argument("--settings", type=Path, default=DEFAULT_SETTINGS)
    parser.add_argument(
        "--apply",
        action="store_true",
        help="apply the plan; without this flag the command only prints it",
    )
    args = parser.parse_args(arguments)
    planned = requests_for(args.repository, load_settings(args.settings))
    if not args.apply:
        print(json.dumps([
            {"method": method, "path": path, "payload": payload}
            for method, path, payload in planned
        ], indent=2, sort_keys=True))
        return 0

    token = os.environ.get("GITHUB_TOKEN", "")
    if not token:
        raise SystemExit("GITHUB_TOKEN is required with --apply")
    for method, path, payload in planned:
        send(token, method, path, payload)
        print(f"applied {method} {path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
