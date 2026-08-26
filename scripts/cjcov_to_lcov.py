#!/usr/bin/env python3
"""Convert cjcov-kept gcov files to LCOV and enforce project coverage."""

from __future__ import annotations

import argparse
import re
import tomllib
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument("--gcov-root", type=Path, required=True)
parser.add_argument("--output", type=Path, required=True)
parser.add_argument("--baseline", type=Path, required=True)
parser.add_argument("--root", type=Path, required=True)
args = parser.parse_args()
source_root = args.root.resolve() / "src"

records: dict[str, dict[int, int]] = {}
branch_records: dict[str, dict[tuple[int, int], int]] = {}
for path in args.gcov_root.rglob("*.gcov"):
    lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
    source = ""
    for line in lines[:10]:
        match = re.match(r"\s*-:\s*0:Source:(.+)$", line)
        if match:
            source = match.group(1)
            break
    if not source or source.endswith("_test.cj"):
        continue
    try:
        resolved = Path(source).resolve()
        resolved.relative_to(source_root)
        relative = str(resolved.relative_to(args.root.resolve()))
    except ValueError:
        continue
    target = records.setdefault(relative, {})
    branch_target = branch_records.setdefault(relative, {})
    current_number = 0
    branch_index = 0
    for line in lines:
        match = re.match(r"\s*([^:]+):\s*(\d+):", line)
        if match:
            current_number = int(match.group(2))
            branch_index = 0
        if line.startswith("branch "):
            branch_match = re.match(r"branch\s+\d+\s+(?:taken\s+(\d+)|never executed)$", line)
            if branch_match and current_number > 0:
                count = int(branch_match.group(1) or 0)
                key = (current_number, branch_index)
                branch_target[key] = max(branch_target.get(key, 0), count)
                branch_index += 1
            continue
        if not match or match.group(1).strip() == "-":
            continue
        count_text = match.group(1).strip().rstrip("*")
        count = 0 if count_text.startswith("#") else int(count_text)
        number = int(match.group(2))
        target[number] = max(target.get(number, 0), count)

args.output.parent.mkdir(parents=True, exist_ok=True)
with args.output.open("w", encoding="utf-8") as handle:
    for source, lines in sorted(records.items()):
        handle.write("TN:\nSF:" + source + "\n")
        for number, count in sorted(lines.items()):
            handle.write(f"DA:{number},{count}\n")
        branches = branch_records.get(source, {})
        for (number, index), count in sorted(branches.items()):
            taken = str(count) if count > 0 else "-"
            handle.write(f"BRDA:{number},0,{index},{taken}\n")
        handle.write(f"BRF:{len(branches)}\n")
        handle.write(f"BRH:{sum(count > 0 for count in branches.values())}\n")
        handle.write("end_of_record\n")

line_hit = sum(count > 0 for lines in records.values() for count in lines.values())
line_total = sum(len(lines) for lines in records.values())
line_percent = 100.0 * line_hit / line_total if line_total else 0.0
branch_hit = sum(count > 0 for branches in branch_records.values() for count in branches.values())
branch_total = sum(len(branches) for branches in branch_records.values())
branch_percent = 100.0 * branch_hit / branch_total if branch_total else 0.0
baseline = tomllib.loads(args.baseline.read_text(encoding="utf-8"))
line_minimum = float(baseline["project_line_percent"])
branch_minimum = float(baseline["project_branch_percent"])
print(f"line coverage: {line_hit}/{line_total} = {line_percent:.1f}% (minimum {line_minimum:.1f}%)")
print(
    f"branch coverage: {branch_hit}/{branch_total} = {branch_percent:.1f}% "
    f"(minimum {branch_minimum:.1f}%)"
)
if line_percent + 1e-9 < line_minimum:
    raise SystemExit("line coverage fell below the project minimum")
if branch_percent + 1e-9 < branch_minimum:
    raise SystemExit("branch coverage fell below the project minimum")
