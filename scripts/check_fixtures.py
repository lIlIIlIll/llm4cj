#!/usr/bin/env python3
"""Decode every checked-in provider fixture through the public llm4cj API."""

from __future__ import annotations

import json
import subprocess
import tempfile
from pathlib import Path
from urllib.parse import urlparse

ROOT = Path(__file__).resolve().parent.parent
PROBE = ROOT / "support/protocol_probe"
FIXTURES = ROOT / "fixtures"
ALLOWED_SOURCE_HOSTS = {
    "platform.openai.com",
    "docs.anthropic.com",
    "api-docs.deepseek.com",
}


def main() -> None:
    subprocess.run(["cjpm", "build"], cwd=PROBE, check=True)
    executable = PROBE / "target/release/bin/main"
    records = sorted(FIXTURES.glob("*.json"))
    if len(records) != 6:
        raise SystemExit(f"expected six provider fixtures, found {len(records)}")

    with tempfile.TemporaryDirectory(prefix="llm4cj-fixtures-") as raw:
        temporary = Path(raw)
        for fixture in records:
            record = json.loads(fixture.read_text(encoding="utf-8"))
            dialect = record.get("fixture")
            source = record.get("source")
            response = record.get("response")
            if not isinstance(dialect, str) or not isinstance(response, dict):
                raise SystemExit(f"invalid fixture envelope: {fixture.name}")
            if not isinstance(source, str) or urlparse(source).hostname not in ALLOWED_SOURCE_HOSTS:
                raise SystemExit(f"fixture source is not an approved provider document: {fixture.name}")
            probe_name = dialect.removesuffix(".v1").replace(".", "-")
            response_path = temporary / fixture.name
            response_path.write_text(json.dumps(response, separators=(",", ":")), encoding="utf-8")
            subprocess.run([executable, probe_name, response_path], cwd=ROOT, check=True)

    print(f"provider fixtures decoded: {len(records)}")


if __name__ == "__main__":
    main()
