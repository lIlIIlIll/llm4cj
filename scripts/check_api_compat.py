#!/usr/bin/env python3
"""Require a semver-breaking version bump when public API shape changes."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import subprocess
import tomllib
from pathlib import Path

from check_contract import public_api_shape


ROOT = Path(__file__).resolve().parent.parent
STABLE_TAG_RE = re.compile(r"v(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)")


def parse_version(value: str) -> tuple[int, int, int]:
    match = re.fullmatch(r"(\d+)\.(\d+)\.(\d+)(?:[-+].*)?", value)
    if not match:
        raise SystemExit("unsupported semantic version: " + value)
    return tuple(int(part) for part in match.groups())  # type: ignore[return-value]


def permits_shape_change(previous: tuple[int, int, int], current: tuple[int, int, int]) -> bool:
    if previous[0] == 0:
        return current[0] > 0 or current[0] == 0 and current[1] > previous[1]
    return current[0] > previous[0]


def git(*args: str) -> str:
    return subprocess.run(["git", *args], cwd=ROOT, check=True, text=True, capture_output=True).stdout


def git_bytes(*args: str) -> bytes:
    return subprocess.run(["git", *args], cwd=ROOT, check=True, capture_output=True).stdout


def is_stable_source_path(name: str) -> bool:
    path = Path(name)
    return path.parent == Path("src") and path.suffix == ".cj" and not path.name.endswith("_test.cj")


def source_at(reference: str) -> str:
    names = git("ls-tree", "-r", "--name-only", reference, "src").splitlines()
    production = sorted(name for name in names if is_stable_source_path(name))
    if not production:
        raise SystemExit("release tag has no production Cangjie sources: " + reference)
    return "\n".join(git("show", f"{reference}:{name}") for name in production)


def shape_digest(value: str) -> str:
    return hashlib.sha256(("\n".join(public_api_shape(value)) + "\n").encode()).hexdigest()


def current_sources() -> dict[str, str]:
    return {
        path.relative_to(ROOT).as_posix(): path.read_text(encoding="utf-8")
        for path in sorted((ROOT / "src").glob("*.cj"))
        if is_stable_source_path(path.relative_to(ROOT).as_posix())
    }


def candidate_source_dirty(candidate: str, sources: dict[str, str]) -> bool:
    names = git("ls-tree", "-r", "--name-only", candidate, "src").splitlines()
    production = {name for name in names if is_stable_source_path(name)}
    return (
        production != set(sources)
        or any(git_bytes("show", f"{candidate}:{name}") != (ROOT / name).read_bytes() for name in sources)
        or git_bytes("show", f"{candidate}:cjpm.toml") != (ROOT / "cjpm.toml").read_bytes()
    )


def compatibility_report(report: dict[str, object]) -> None:
    candidate = git("rev-parse", "HEAD").strip()
    report["candidateCommit"] = candidate
    sources = current_sources()
    dirty = candidate_source_dirty(candidate, sources)
    report["candidateSourceDirty"] = dirty
    current_manifest = tomllib.loads((ROOT / "cjpm.toml").read_text(encoding="utf-8"))
    current_version = current_manifest["package"]["version"]
    report["candidateVersion"] = current_version
    current = parse_version(current_version)
    stable_tags = sorted(
        (tag for tag in git("tag", "--list").splitlines() if STABLE_TAG_RE.fullmatch(tag)),
        key=lambda tag: parse_version(tag[1:]), reverse=True,
    )
    commits = {tag: git("rev-parse", f"{tag}^{{commit}}").strip() for tag in stable_tags}
    candidate_tags = [tag for tag in stable_tags if commits[tag] == candidate]
    report["candidateTag"] = candidate_tags[0] if candidate_tags else None
    baselines = [tag for tag in stable_tags if dirty or commits[tag] != candidate]
    if not baselines:
        raise SystemExit("public API compatibility check requires a previous stable release tag")
    tag = baselines[0]
    report["baselineTag"], report["baselineCommit"] = tag, commits[tag]
    previous_manifest = tomllib.loads(git("show", f"{tag}:cjpm.toml"))
    previous_version = previous_manifest["package"]["version"]
    report["baselineVersion"] = previous_version
    if previous_version != tag[1:]:
        raise SystemExit(f"release tag {tag} does not match package version {previous_version}")
    previous = parse_version(previous_version)
    previous_digest = shape_digest(source_at(tag))
    current_digest = shape_digest("\n".join(sources.values()))
    changed = previous_digest != current_digest
    permitted = not changed or permits_shape_change(previous, current)
    report.update({
        "baselineShapeSha256": previous_digest,
        "candidateShapeSha256": current_digest,
        "shapeChanged": changed,
        "semverPermitsChange": permitted,
    })
    if not permitted:
        raise SystemExit(
            f"public API changed since {tag} without a breaking semver bump: "
            f"{previous_version} -> {current_version}"
        )


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path)
    args = parser.parse_args(argv)
    report = {
        "scope": "stable llm4cj package only",
        "experimentalExcluded": True,
        "baselineTag": None,
        "baselineCommit": None,
        "candidateCommit": None,
        "candidateTag": None,
        "candidateSourceDirty": None,
    }
    try:
        compatibility_report(report)
    except (SystemExit, subprocess.CalledProcessError, KeyError, ValueError) as error:
        report["error"] = str(error)
        raise
    finally:
        if args.output is not None:
            args.output.parent.mkdir(parents=True, exist_ok=True)
            args.output.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(
        f"public API compatibility passed against {report['baselineTag']}: "
        f"{report['baselineVersion']} -> {report['candidateVersion']}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
