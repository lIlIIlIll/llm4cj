#!/usr/bin/env python3
"""Validate the documentation contract without network access."""

from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
REQUIRED = [
    "README.md", "CONTRIBUTING.md", "SECURITY.md", "CHANGELOG.md",
    "docs/README.md", "docs/getting-started.md", "docs/choosing-a-protocol.md",
    "docs/requests-and-replies.md", "docs/streaming-and-transport.md",
    "docs/tools-thinking-and-structured-output.md", "docs/errors-and-limits.md",
    "docs/api-reference.md", "docs/architecture.md", "docs/testing-and-releasing.md",
    "docs/migrating-from-v0.1.md", "docs/v0.2-test-plan.md",
]


def fail(message: str) -> None:
    print(f"documentation check failed: {message}", file=sys.stderr)
    raise SystemExit(1)


for relative in REQUIRED:
    if not (ROOT / relative).is_file():
        fail(f"missing {relative}")

markdown = list(ROOT.glob("*.md")) + list((ROOT / "docs").glob("*.md"))
for path in markdown:
    text = path.read_text(encoding="utf-8")
    if len(re.findall(r"^```", text, re.MULTILINE)) % 2:
        fail(f"unclosed code fence in {path.relative_to(ROOT)}")
    for target in re.findall(r"\[[^]]+\]\(([^)]+)\)", text):
        if target.startswith(("http://", "https://", "#")):
            continue
        clean = target.split("#", 1)[0]
        if clean and not (path.parent / clean).resolve().exists():
            fail(f"broken link {target} in {path.relative_to(ROOT)}")

manifest = (ROOT / "cjpm.toml").read_text(encoding="utf-8")
version = re.search(r'^version = "([^"]+)"$', manifest, re.MULTILINE)
minimum = re.search(r'^cjc-version = "([^"]+)"$', manifest, re.MULTILINE)
if not version or f"v{version.group(1)}" not in (ROOT / "README.md").read_text(encoding="utf-8"):
    fail("README stable tag does not match cjpm.toml")
if not minimum or minimum.group(1) not in (ROOT / "README.md").read_text(encoding="utf-8"):
    fail("README Cangjie minimum does not match cjpm.toml")

api = (ROOT / "docs/api-reference.md").read_text(encoding="utf-8")
source = "\n".join(path.read_text(encoding="utf-8") for path in (ROOT / "src").glob("*.cj"))
names = set(re.findall(r"^public\s+(?:class|enum|interface|struct|func)\s+([A-Za-z][A-Za-z0-9_]*)", source, re.MULTILINE))
missing = sorted(name for name in names if f"`{name}" not in api)
if missing:
    fail("public API missing from reference: " + ", ".join(missing))

canonical = (ROOT / "support/external_consumer/src/main.cj").read_text(encoding="utf-8").strip()
for relative in ("README.md", "docs/getting-started.md"):
    blocks = re.findall(r"```cj\n(.*?)```", (ROOT / relative).read_text(encoding="utf-8"), re.DOTALL)
    if not blocks or blocks[0].strip() != canonical:
        fail(f"canonical Quick Start drifted in {relative}")

print(f"documentation check passed: {len(markdown)} Markdown files, {len(names)} public declarations")
