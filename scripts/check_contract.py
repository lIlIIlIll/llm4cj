#!/usr/bin/env python3
"""Check public API, diagnostic codes, and provider fixture digests."""

from __future__ import annotations

import hashlib
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
source = "\n".join(path.read_text(encoding="utf-8") for path in sorted((ROOT / "src").glob("*.cj")))

api = sorted(
    f"{kind} {name}"
    for kind, name in re.findall(
        r"^public\s+(class|enum|interface|struct|func)\s+([A-Za-z][A-Za-z0-9_]*)",
        source,
        re.MULTILINE,
    )
)
expected_api = (ROOT / "contract/public-api.txt").read_text(encoding="utf-8").splitlines()
if api != expected_api:
    raise SystemExit("public API snapshot drifted; update contract/public-api.txt intentionally")

codes = sorted(set(re.findall(r'"(llm\.[a-z0-9_.]+)"', source)))
expected_codes = (ROOT / "contract/error-codes.txt").read_text(encoding="utf-8").splitlines()
if codes != expected_codes:
    raise SystemExit("error-code inventory drifted; update contract/error-codes.txt intentionally")

digest = hashlib.sha256()
fixtures = sorted((ROOT / "fixtures").glob("*.json"))
if len(fixtures) != 6:
    raise SystemExit(f"expected six dialect fixtures, found {len(fixtures)}")
for path in fixtures:
    digest.update(path.name.encode("utf-8") + b"\0" + path.read_bytes() + b"\0")
actual_digest = digest.hexdigest()
expected_digest = (ROOT / "contract/fixture-digest.txt").read_text(encoding="utf-8").strip()
if actual_digest != expected_digest:
    raise SystemExit(f"fixture digest drifted: {actual_digest}")

print(f"contract check passed: {len(api)} declarations, {len(codes)} codes, {len(fixtures)} fixtures")
