#!/usr/bin/env python3
"""Convert cjcov-kept gcov files to LCOV and enforce the line baseline."""

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
    for line in lines:
        match = re.match(r"\s*([^:]+):\s*(\d+):", line)
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
        handle.write("end_of_record\n")

hit = sum(count > 0 for lines in records.values() for count in lines.values())
total = sum(len(lines) for lines in records.values())
percent = 100.0 * hit / total if total else 0.0
baseline = tomllib.loads(args.baseline.read_text(encoding="utf-8"))
minimum = float(baseline["line_percent"]) - float(baseline["tolerance_points"])
print(f"line coverage: {hit}/{total} = {percent:.1f}% (minimum {minimum:.1f}%)")
if percent + 1e-9 < minimum:
    raise SystemExit("line coverage fell below the frozen baseline tolerance")
