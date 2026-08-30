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


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path)
    args = parser.parse_args(argv)
    tags = git("tag", "--sort=-version:refname").splitlines()
    if not tags:
        raise SystemExit("public API compatibility check requires a release tag")
    tag = tags[0]
    previous_manifest = tomllib.loads(git("show", f"{tag}:cjpm.toml"))
    current_manifest = tomllib.loads((ROOT / "cjpm.toml").read_text(encoding="utf-8"))
    previous = parse_version(previous_manifest["package"]["version"])
    current = parse_version(current_manifest["package"]["version"])
    previous_digest = shape_digest(source_at(tag))
    current_source = "\n".join(
        path.read_text(encoding="utf-8")
        for path in sorted((ROOT / "src").glob("*.cj"))
        if not path.name.endswith("_test.cj")
    )
    current_digest = shape_digest(current_source)
    changed = previous_digest != current_digest
    permitted = not changed or permits_shape_change(previous, current)
    report = {
        "scope": "stable llm4cj package only",
        "experimentalExcluded": True,
        "baselineTag": tag,
        "baselineVersion": previous_manifest["package"]["version"],
        "candidateVersion": current_manifest["package"]["version"],
        "baselineShapeSha256": previous_digest,
        "candidateShapeSha256": current_digest,
        "shapeChanged": changed,
        "semverPermitsChange": permitted,
    }
    if args.output is not None:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    if not permitted:
        raise SystemExit(
            f"public API changed since {tag} without a breaking semver bump: "
            f"{previous_manifest['package']['version']} -> {current_manifest['package']['version']}"
        )
    print(
        f"public API compatibility passed against {tag}: "
        f"{previous_manifest['package']['version']} -> {current_manifest['package']['version']}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
