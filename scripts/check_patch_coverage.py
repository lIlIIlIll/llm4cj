#!/usr/bin/env python3
"""Enforce line and branch coverage for added Cangjie source lines."""

from __future__ import annotations

import argparse
import re
import subprocess
import tomllib
from pathlib import Path
from typing import Sequence


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


def read_instrumented_lines(gcov_root: Path, root: Path) -> dict[str, set[int]]:
    """Read executable source lines from gcov, including zero-hit lines."""
    instrumented: dict[str, set[int]] = {}
    source_root = root.resolve() / "src"
    for path in gcov_root.rglob("*.gcov"):
        raw_lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
        source = ""
        for raw in raw_lines[:10]:
            match = re.match(r"\s*-:\s*0:Source:(.+)$", raw)
            if match:
                source = match.group(1)
                break
        if not source:
            continue
        try:
            resolved = Path(source).resolve()
            resolved.relative_to(source_root)
            relative = str(resolved.relative_to(root.resolve())).replace("\\", "/")
        except ValueError:
            continue
        target = instrumented.setdefault(relative, set())
        for raw in raw_lines:
            match = re.match(r"\s*([^:]+):\s*(\d+):", raw)
            if not match or match.group(1).strip() == "-":
                continue
            target.add(int(match.group(2)))
    return instrumented


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


DECISION_TOKEN = re.compile(r"\b(?:if|else|for|while|match|case|catch|where)\b")


def source_decision_lines(path: Path, numbers: set[int]) -> set[int]:
    """Return changed lines that contain an explicit source-level decision.

    Cangjie gcov emits BRDA records for exception unwinding, enum deriving, and
    cleanup edges on ordinary calls inside ``try`` blocks. Those compiler arcs
    are not decisions a source test can intentionally select. Patch branch
    coverage therefore uses only BRDA records attached to explicit Cangjie
    control-flow syntax, while project coverage continues to report every arc.
    """
    if not path.exists():
        return set()
    lines = path.read_text(encoding="utf-8").splitlines()
    decisions: set[int] = set()
    for number in numbers:
        if number < 1 or number > len(lines):
            continue
        text = lines[number - 1].split("//", 1)[0]
        if DECISION_TOKEN.search(text) or "&&" in text or "||" in text:
            decisions.add(number)
    return decisions


def compact_ranges(numbers: list[int]) -> str:
    if not numbers:
        return "-"
    ranges: list[str] = []
    start = numbers[0]
    end = start
    for number in numbers[1:]:
        if number == end + 1:
            end = number
            continue
        ranges.append(str(start) if start == end else f"{start}-{end}")
        start = number
        end = number
    ranges.append(str(start) if start == end else f"{start}-{end}")
    return ",".join(ranges)


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    diff_source = parser.add_mutually_exclusive_group(required=True)
    diff_source.add_argument("--diff", type=Path)
    diff_source.add_argument("--base-ref")
    parser.add_argument("--lcov", type=Path, required=True)
    parser.add_argument("--gcov-root", type=Path, required=True)
    parser.add_argument("--baseline", type=Path, required=True)
    parser.add_argument("--root", type=Path, default=Path.cwd())
    args = parser.parse_args(argv)

    root = args.root.resolve()
    if args.diff is not None:
        diff_text = args.diff.read_text(encoding="utf-8")
    else:
        diff_text = subprocess.run(
            ["git", "diff", "--unified=0", f"{args.base_ref}...HEAD", "--", "src/*.cj"],
            cwd=root, check=True, text=True, capture_output=True,
        ).stdout
    changed = changed_lines(diff_text)
    lines, branches = read_lcov(args.lcov)
    lines = {canonical_source(source): values for source, values in lines.items()}
    branches = {canonical_source(source): values for source, values in branches.items()}
    instrumented = read_instrumented_lines(args.gcov_root, root)
    production_changed = {
        source: numbers for source, numbers in changed.items()
        if source.startswith("src/") and source.endswith(".cj") and not source.endswith("_test.cj")
    }
    missing_records = sorted(source for source in production_changed if source not in lines)
    if missing_records:
        raise SystemExit("modified production source is absent from LCOV: " + ", ".join(missing_records))
    missing_instrumentation = sorted(source for source in production_changed if source not in instrumented)
    if missing_instrumentation:
        raise SystemExit("modified production source is absent from gcov instrumentation: " + ", ".join(missing_instrumentation))

    executable_changed = {
        source: numbers & instrumented.get(source, set())
        for source, numbers in production_changed.items()
    }
    decision_changed = {
        source: source_decision_lines(root / source, numbers)
        for source, numbers in production_changed.items()
    }
    missing_da = sorted(
        f"{source}:{number}"
        for source, numbers in executable_changed.items()
        for number in numbers
        if number not in lines.get(source, {})
    )
    if missing_da:
        raise SystemExit("instrumented patch lines are absent from LCOV DA records: " + ", ".join(missing_da))

    line_counts = [
        lines[source][number]
        for source, numbers in executable_changed.items()
        for number in sorted(numbers)
    ]
    branch_counts = [
        count
        for source, source_branches in branches.items()
        for number, count in source_branches
        if number in decision_changed.get(source, set())
    ]

    candidate_files = [source for source, numbers in production_changed.items() if has_candidate_code(root / source, numbers)]
    if candidate_files and not line_counts:
        raise SystemExit("modified production code has no instrumented patch lines")

    line_hit = sum(count > 0 for count in line_counts)
    branch_hit = sum(count > 0 for count in branch_counts)
    line_percent = percent(line_hit, len(line_counts)) if candidate_files else 100.0
    branch_percent = percent(branch_hit, len(branch_counts)) if branch_counts else 100.0
    baseline = tomllib.loads(args.baseline.read_text(encoding="utf-8"))
    line_minimum = float(baseline["patch_line_percent"])
    branch_minimum = float(baseline["patch_branch_percent"])

    for source in sorted(executable_changed):
        source_lines = sorted(executable_changed[source])
        covered_lines = [number for number in source_lines if lines[source][number] > 0]
        uncovered_lines = [number for number in source_lines if lines[source][number] == 0]
        source_branches = [count for number, count in branches.get(source, []) if number in decision_changed.get(source, set())]
        covered_branches = sum(count > 0 for count in source_branches)
        uncovered_branch_lines = sorted({
            number for number, count in branches.get(source, [])
            if number in decision_changed.get(source, set()) and count == 0
        })
        print(
            f"patch file {source}: lines {len(covered_lines)}/{len(source_lines)}, "
            f"branches {covered_branches}/{len(source_branches)}, "
            f"uncovered={compact_ranges(uncovered_lines)}, "
            f"uncovered-branch-lines={compact_ranges(uncovered_branch_lines)}"
        )

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
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
