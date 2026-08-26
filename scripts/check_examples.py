#!/usr/bin/env python3
"""Extract every Cangjie documentation program and type-check it."""

from __future__ import annotations

import re
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DOCS = [ROOT / "README.md", *sorted((ROOT / "docs").glob("*.md"))]
programs: list[tuple[Path, str]] = []
for path in DOCS:
    for block in re.findall(r"```cj\n(.*?)```", path.read_text(encoding="utf-8"), re.DOTALL):
        if "main():" in block:
            programs.append((path, block))

if not programs:
    raise SystemExit("no runnable Cangjie documentation examples found")

for index, (document, source) in enumerate(programs):
    with tempfile.TemporaryDirectory(prefix="llm4cj-doc-example-") as raw:
        work = Path(raw)
        (work / "src").mkdir()
        package = re.search(r"^package\s+([A-Za-z0-9_.]+)", source, re.MULTILINE)
        if not package:
            raise SystemExit(f"missing package in {document}")
        manifest = f'''[package]
cjc-version = "1.1.0"
name = "{package.group(1)}"
organization = ""
version = "0.1.0"
output-type = "executable"

[dependencies]
llm4cj = {{ path = "{ROOT}" }}
yjson = {{ git = "https://github.com/lIlIIlIll/yjson.git", branch = "main", output-type = "static" }}
'''
        (work / "cjpm.toml").write_text(manifest, encoding="utf-8")
        (work / "src/main.cj").write_text(source, encoding="utf-8")
        subprocess.run(["cjpm", "check"], cwd=work, check=True)
        if index == 0:
            completed = subprocess.run(
                ["cjpm", "run"], cwd=work, check=True, text=True, capture_output=True
            )
            if "你好，仓颉！" not in completed.stdout.splitlines():
                raise SystemExit("canonical Quick Start produced unexpected output")

print(f"documentation examples checked: {len(programs)}")
