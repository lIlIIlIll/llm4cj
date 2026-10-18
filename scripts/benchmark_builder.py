#!/usr/bin/env python3
"""Measure builder copy counts and advisory release timings in isolated copies.

Run under the normal Cangjie environment. --output must name a new disk-backed
directory. An optional baseline is the source tree with the old immutable-append
builder. Coverage runs perform append only; release runs measure append, build,
and encode separately. Wall-clock times are reported without pass thresholds.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
from pathlib import Path


COUNTS = (1000, 2000, 4000)
IGNORED = (".git", "target", "coverage", "cov_output", ".agents", ".claude", ".codex", "__pycache__", "*.gcno", "*.gcda", "*.gcov")


def run(command: list[str], cwd: Path, log: Path) -> str:
    result = subprocess.run(command, cwd=cwd, capture_output=True, text=True, check=False)
    log.write_text(result.stdout + result.stderr, encoding="utf-8")
    if result.returncode:
        raise RuntimeError(f"command failed ({result.returncode}); see {log.name}")
    return result.stdout


def measure(label: str, source: Path, output: Path, probe: Path, llvm_cov: str, samples: int) -> dict:
    tree = output / label
    shutil.copytree(source, tree, ignore=shutil.ignore_patterns(*IGNORED))
    project = tree / "support" / "builder_benchmark"
    if project.exists():
        shutil.rmtree(project)
    shutil.copytree(probe, project, ignore=shutil.ignore_patterns(*IGNORED))
    run(["cjpm", "build", "--coverage"], project, output / f"{label}-coverage-build.log")
    notes = project / "0-llm4cj.gcno"
    if not notes.is_file():
        raise RuntimeError("coverage build did not produce the library notes")
    copies = []
    for count in COUNTS:
        raw = output / f"{label}-copies-{count}"
        raw.mkdir()
        for path in project.rglob("*.gcda"):
            path.unlink()
        run(["target/release/bin/main", str(count), "append"], project, raw / "run.jsonl")
        run([llvm_cov, "gcov", "-b", "-c", str(notes)], project, raw / "gcov.log")
        coverage = project / "transcript.cj.gcov"
        text = coverage.read_text(encoding="utf-8")
        match = re.search(r"function\s+\S*copyTranscriptMessage\S*\s+called\s+(\d+)\s", text)
        if match is None:
            raise RuntimeError("copyTranscriptMessage execution count is absent")
        actual = int(match.group(1))
        expected = count if label == "candidate" else count * (count + 1) // 2
        copies.append({"items": count, "message_copies": actual, "expected": expected})
        shutil.copy2(coverage, raw / coverage.name)
        shutil.copy2(project / "request_builder.cj.gcov", raw / "request_builder.cj.gcov")
        if actual != expected:
            raise RuntimeError(f"{label} copy count for {count} items: {actual}, expected {expected}")
    run(["cjpm", "clean"], project, output / f"{label}-release-clean.log")
    run(["cjpm", "build"], project, output / f"{label}-release-build.log")
    timings = []
    for count in COUNTS:
        for sample in range(samples):
            text = run(["target/release/bin/main", str(count), "all"], project,
                       output / f"{label}-timing-{count}-{sample}.jsonl")
            for line in text.splitlines():
                value = json.loads(line)
                value["sample"] = sample
                timings.append(value)
    return {"copy_counts": copies, "release_timings": timings}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--baseline-source", type=Path,
                        help="tree containing the pre-buffering immutable-append builder")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--llvm-cov", default="llvm-cov")
    parser.add_argument("--samples", type=int, default=3)
    args = parser.parse_args()
    if args.samples < 1:
        parser.error("--samples must be positive")
    source = args.source.resolve()
    output = args.output.resolve()
    if output.is_relative_to(source) or (args.baseline_source is not None and
                                         output.is_relative_to(args.baseline_source.resolve())):
        parser.error("--output must be outside the measured source trees")
    output.mkdir(mode=0o700)
    os.environ.update({name: str(output) for name in ("TMPDIR", "TMP", "TEMP")})
    os.environ["DISABLE_ZOXIDE"] = "1"
    results = {}
    probe = Path(__file__).resolve().parents[1] / "support" / "builder_benchmark"
    for label, tree in (("baseline", args.baseline_source), ("candidate", source)):
        if tree is not None:
            results[label] = measure(label, tree.resolve(), output, probe, args.llvm_cov, args.samples)
    (output / "results.json").write_text(json.dumps(results, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({label: result["copy_counts"] for label, result in results.items()}))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
