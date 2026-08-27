#!/usr/bin/env python3
"""Enforce line and branch coverage for added Cangjie source lines."""

from __future__ import annotations

import argparse
import re
import tomllib
from pathlib import Path


def changed_lines(diff: str) -> dict[str, set[int]]:
    changed: dict[str, set[int]] = {}
    current: str | None = None
    new_line = 0
    for raw in diff.splitlines():
        if raw.startswith("+++ "):
            name = raw[4:].split("\t", 1)[0]
            current = None if name == "/dev/null" else name.removeprefix("b/")
            continue
        hunk = re.match(r"@@ -\d+(?:,\d+)? \+(\d+)(?:,\d+)? @@", raw)
        if hunk:
            new_line = int(hunk.group(1))
            continue
        if current is None or raw.startswith("diff --git"):
            continue
        if raw.startswith("+") and not raw.startswith("+++"):
            changed.setdefault(current, set()).add(new_line)
            new_line += 1
        elif raw.startswith("-") and not raw.startswith("---"):
            continue
        elif raw.startswith(" "):
            new_line += 1
    return changed


def read_lcov(
    path: Path,
) -> tuple[dict[str, dict[int, int]], dict[str, list[tuple[int, int]]]]:
    lines: dict[str, dict[int, int]] = {}
    branches: dict[str, list[tuple[int, int]]] = {}
    source = ""
    for raw in path.read_text(encoding="utf-8").splitlines():
        if raw.startswith("SF:"):
            source = raw[3:]
        elif raw.startswith("DA:") and source:
            number, count = raw[3:].split(",", 1)
            lines.setdefault(source, {})[int(number)] = int(count)
        elif raw.startswith("BRDA:") and source:
            number, _, _, taken = raw[5:].split(",", 3)
            count = 0 if taken == "-" else int(taken)
            branches.setdefault(source, []).append((int(number), count))
    return lines, branches


def percent(hit: int, total: int) -> float:
    return 100.0 * hit / total if total else 0.0


def canonical_source(value: str) -> str:
    normalized = value.replace("\\", "/")
    marker = "/src/"
    if marker in normalized:
        return "src/" + normalized.split(marker, 1)[1]
    return normalized.removeprefix("./")


def has_candidate_code(path: Path, numbers: set[int]) -> bool:
    if not path.exists():
        return False
    lines = path.read_text(encoding="utf-8").splitlines()
    for number in numbers:
        if number < 1 or number > len(lines):
            continue
        text = lines[number - 1].strip()
        if text and not text.startswith("//") and text not in {"{", "}"} and not text.startswith(("package ", "import ")):
            return True
    return False


parser = argparse.ArgumentParser()
parser.add_argument("--diff", type=Path, required=True)
parser.add_argument("--lcov", type=Path, required=True)
parser.add_argument("--baseline", type=Path, required=True)
args = parser.parse_args()

changed = changed_lines(args.diff.read_text(encoding="utf-8"))
lines, branches = read_lcov(args.lcov)
lines = {canonical_source(source): values for source, values in lines.items()}
branches = {canonical_source(source): values for source, values in branches.items()}
production_changed = {
    source: numbers for source, numbers in changed.items()
    if source.startswith("src/") and source.endswith(".cj") and not source.endswith("_test.cj")
}
missing_records = sorted(source for source in production_changed if source not in lines)
if missing_records:
    raise SystemExit("modified production source is absent from LCOV: " + ", ".join(missing_records))

line_counts = [
    count
    for source, source_lines in lines.items()
    for number, count in source_lines.items()
    if number in changed.get(source, set())
]
branch_counts = [
    count
    for source, source_branches in branches.items()
    for number, count in source_branches
    if number in changed.get(source, set())
]

candidate_files = [source for source, numbers in production_changed.items() if has_candidate_code(Path(source), numbers)]
if candidate_files and not line_counts:
    raise SystemExit("modified production code has no instrumented patch lines")

line_hit = sum(count > 0 for count in line_counts)
branch_hit = sum(count > 0 for count in branch_counts)
line_percent = percent(line_hit, len(line_counts)) if candidate_files else 100.0
branch_percent = percent(branch_hit, len(branch_counts)) if branch_counts else 100.0
baseline = tomllib.loads(args.baseline.read_text(encoding="utf-8"))
line_minimum = float(baseline["patch_line_percent"])
branch_minimum = float(baseline["patch_branch_percent"])

print(
    f"patch line coverage: {line_hit}/{len(line_counts)} = {line_percent:.1f}% "
    f"(minimum {line_minimum:.1f}%)"
)
print(
    f"patch branch coverage: {branch_hit}/{len(branch_counts)} = {branch_percent:.1f}% "
    f"(minimum {branch_minimum:.1f}%)"
)
if line_percent + 1e-9 < line_minimum:
    raise SystemExit("line coverage fell below the patch minimum")
if branch_percent + 1e-9 < branch_minimum:
    raise SystemExit("branch coverage fell below the patch minimum")
