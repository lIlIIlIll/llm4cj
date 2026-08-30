#!/usr/bin/env python3
"""Evaluate and publish the trusted pull-request metadata gate."""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass
from pathlib import PurePosixPath
from typing import Any, Iterable


BRANCH_RE = re.compile(
    r"^(feat|fix|docs|test|refactor|ci|build|chore)/"
    r"[a-z0-9]+(?:-[a-z0-9]+)*$"
)
TITLE_RE = re.compile(
    r"^(feat|fix|docs|test|refactor|perf|ci|build|chore|revert)"
    r"(?:\([a-z0-9][a-z0-9-]*\))?!?: .+\S$"
)
RISK_RE = re.compile(r"(?im)^Risk:\s*(routine|high)\s*$")
NA_RE = re.compile(r"(?im)^Issue:\s*N/A:\s*(\S.+)$")
ISSUE_RE = re.compile(
    r"(?i)\b(?:close[sd]?|fix(?:e[sd])?|resolve[sd]?)\s+#(\d+)\b"
)
ADVISORY_RE = re.compile(r"(?im)^Security-Advisory:\s*private\s*$")

BUILTIN_DEPENDABOT = "dependabot[bot]"
WRITE_PERMISSIONS = {"admin", "maintain", "write"}
PLACEHOLDER_RE = re.compile(r"(?i)^(?:<.*>|todo|tbd|none|n/a)$")
SENSITIVE_PREFIXES = (
    ".github/workflows/",
    "contract/",
    "src/",
    "support/provider_probe/",
)
SENSITIVE_FILES = {
    "AGENTS.md",
    "SECURITY.md",
    "coverage-baseline.toml",
    "cjpm.toml",
    "cjpm.lock",
    "scripts/pr_metadata.py",
    "scripts/check_pr_metadata.py",
    "scripts/check_api_compat.py",
    "scripts/check_contract.py",
    "scripts/check_patch_coverage.py",
    "scripts/check_provider_smoke_security.py",
    "scripts/provider_smoke.sh",
    "scripts/release_gate.sh",
}


@dataclass(frozen=True)
class PullRequestFacts:
    number: int
    branch: str
    title: str
    body: str
    author: str
    head_sha: str
    files: tuple[tuple[str, str], ...]
    open_issue_numbers: frozenset[int]
    land_permissions: tuple[tuple[str, str], ...]
    author_permission: str = "read"


@dataclass(frozen=True)
class GateResult:
    state: str
    summary: str
    errors: tuple[str, ...]


def _is_test(path: str) -> bool:
    name = PurePosixPath(path).name
    return (
        path.startswith("tests/")
        or path.startswith("scripts/test_")
        or name.endswith("_test.cj")
        or name.startswith("test_")
    )


def _is_sensitive(path: str, status: str) -> bool:
    if path in SENSITIVE_FILES or path.startswith(SENSITIVE_PREFIXES):
        return True
    return status in {"modified", "removed", "renamed"} and _is_test(path)


def evaluate(facts: PullRequestFacts) -> GateResult:
    errors: list[str] = []
    dependabot = facts.author == BUILTIN_DEPENDABOT

    if not dependabot and not BRANCH_RE.fullmatch(facts.branch):
        errors.append(
            "branch must match <type>/<kebab-case> for an allowed short-lived type"
        )
    if not TITLE_RE.fullmatch(facts.title):
        errors.append("PR title must use Conventional Commit syntax")

    risk_match = RISK_RE.search(facts.body)
    declared_risk = risk_match.group(1).lower() if risk_match else ""
    inferred_high = any(_is_sensitive(path, status) for path, status in facts.files)
    if declared_risk not in {"routine", "high"}:
        errors.append("PR body must declare exactly `Risk: routine` or `Risk: high`")
    elif inferred_high and declared_risk != "high":
        errors.append("sensitive changes must declare `Risk: high`")

    high = inferred_high or declared_risk == "high"
    linked = set(int(value) for value in ISSUE_RE.findall(facts.body))
    linked_open = linked.intersection(facts.open_issue_numbers)
    advisory = bool(ADVISORY_RE.search(facts.body))

    if high:
        issue_exempt = dependabot or (
            advisory and facts.author_permission in WRITE_PERMISSIONS
        )
        if not issue_exempt and not linked_open:
            errors.append("high-risk PRs must close an open same-repository issue")
    elif not dependabot and not linked_open:
        na_match = NA_RE.search(facts.body)
        if not na_match or PLACEHOLDER_RE.fullmatch(na_match.group(1).strip()):
            errors.append(
                "routine PRs must close an open issue or give `Issue: N/A: <reason>`"
            )

    if errors:
        return GateResult("failure", errors[0], tuple(errors))

    if high:
        exact_command = f"/land {facts.head_sha}"
        approved = any(
            body.strip() == exact_command and permission in WRITE_PERMISSIONS
            for body, permission in facts.land_permissions
        )
        if not approved:
            return GateResult(
                "pending",
                f"awaiting `{exact_command}` from a repository writer",
                (),
            )

    return GateResult("success", "pull-request metadata policy satisfied", ())


class GitHubClient:
    def __init__(self, repository: str, token: str) -> None:
        self.repository = repository
        self.token = token
        self.api = "https://api.github.com"

    def request(self, method: str, path: str, payload: Any | None = None) -> Any:
        data = None if payload is None else json.dumps(payload).encode("utf-8")
        request = urllib.request.Request(
            f"{self.api}{path}",
            data=data,
            method=method,
            headers={
                "Accept": "application/vnd.github+json",
                "Authorization": f"Bearer {self.token}",
                "X-GitHub-Api-Version": "2022-11-28",
                "User-Agent": "llm4cj-pr-metadata",
            },
        )
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                raw = response.read()
        except urllib.error.HTTPError as error:
            detail = error.read().decode("utf-8", errors="replace")
            raise RuntimeError(f"GitHub API {method} {path} failed: {detail}") from error
        return None if not raw else json.loads(raw)

    def get(self, path: str) -> Any:
        return self.request("GET", path)

    def permission(self, login: str) -> str:
        encoded = urllib.parse.quote(login, safe="")
        result = self.get(
            f"/repos/{self.repository}/collaborators/{encoded}/permission"
        )
        return str(result.get("permission", "read"))


def _pages(client: GitHubClient, path: str) -> Iterable[dict[str, Any]]:
    page = 1
    while True:
        separator = "&" if "?" in path else "?"
        values = client.get(f"{path}{separator}per_page=100&page={page}")
        yield from values
        if len(values) < 100:
            return
        page += 1


def collect_facts(client: GitHubClient, number: int) -> PullRequestFacts:
    base = f"/repos/{client.repository}"
    pr = client.get(f"{base}/pulls/{number}")
    files = tuple(
        (str(item["filename"]), str(item["status"]))
        for item in _pages(client, f"{base}/pulls/{number}/files")
    )
    body = str(pr.get("body") or "")
    issue_numbers = set(int(value) for value in ISSUE_RE.findall(body))
    open_issues: set[int] = set()
    for issue_number in issue_numbers:
        issue = client.get(f"{base}/issues/{issue_number}")
        if issue.get("state") == "open" and "pull_request" not in issue:
            open_issues.add(issue_number)

    expected = f"/land {pr['head']['sha']}"
    land_permissions: list[tuple[str, str]] = []
    for comment in _pages(client, f"{base}/issues/{number}/comments"):
        comment_body = str(comment.get("body") or "").strip()
        if comment_body == expected:
            login = str(comment["user"]["login"])
            land_permissions.append((comment_body, client.permission(login)))

    author = str(pr["user"]["login"])
    author_permission = client.permission(author)
    return PullRequestFacts(
        number=number,
        branch=str(pr["head"]["ref"]),
        title=str(pr["title"]),
        body=body,
        author=author,
        head_sha=str(pr["head"]["sha"]),
        files=files,
        open_issue_numbers=frozenset(open_issues),
        land_permissions=tuple(land_permissions),
        author_permission=author_permission,
    )


def _event_pr_number(event: dict[str, Any]) -> int:
    if "pull_request" in event:
        return int(event["pull_request"]["number"])
    issue = event.get("issue", {})
    if "pull_request" in issue:
        return int(issue["number"])
    raise ValueError("event does not identify a pull request")


def publish(client: GitHubClient, facts: PullRequestFacts, result: GateResult) -> None:
    description = result.summary.replace("`", "")[:140]
    client.request(
        "POST",
        f"/repos/{client.repository}/statuses/{facts.head_sha}",
        {
            "state": result.state,
            "context": "pr-metadata",
            "description": description,
            "target_url": (
                f"https://github.com/{client.repository}/pull/{facts.number}"
            ),
        },
    )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--event", required=True)
    args = parser.parse_args()
    repository = os.environ["GITHUB_REPOSITORY"]
    token = os.environ["GITHUB_TOKEN"]
    with open(args.event, encoding="utf-8") as handle:
        event = json.load(handle)
    client = GitHubClient(repository, token)
    facts = collect_facts(client, _event_pr_number(event))
    result = evaluate(facts)
    publish(client, facts, result)
    print(json.dumps({"state": result.state, "errors": result.errors}, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
