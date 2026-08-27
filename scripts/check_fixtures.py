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
STREAM_PROBE = ROOT / "support/provider_probe"
FIXTURES = ROOT / "fixtures"
ALLOWED_SOURCE_HOSTS = {
    "platform.openai.com",
    "docs.anthropic.com",
    "api-docs.deepseek.com",
}


def main() -> None:
    subprocess.run(["cjpm", "build"], cwd=PROBE, check=True)
    subprocess.run(["cjpm", "build"], cwd=STREAM_PROBE, check=True)
    executable = PROBE / "target/release/bin/main"
    stream_executable = STREAM_PROBE / "target/release/bin/main"
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

        request_records = sorted((FIXTURES / "requests").glob("*.json"))
        stream_records = sorted((FIXTURES / "streams").glob("*.json"))
        if len(request_records) != 6 or len(stream_records) != 6:
            raise SystemExit("expected six request and six stream fixtures")
        for fixture in request_records:
            dialect = fixture.stem
            encoded = subprocess.run(
                [stream_executable, "encode-fixture", dialect, "fixture-model"], cwd=ROOT,
                check=True, text=True, capture_output=True,
            ).stdout
            if json.loads(encoded) != json.loads(fixture.read_text(encoding="utf-8")):
                raise SystemExit(f"public encoder drifted from request fixture: {fixture.name}")
        for fixture in stream_records:
            record = json.loads(fixture.read_text(encoding="utf-8"))
            dialect = fixture.stem
            events = record.get("events")
            if not isinstance(events, list) or not all(isinstance(value, str) for value in events):
                raise SystemExit(f"invalid stream fixture: {fixture.name}")
            stream_path = temporary / (fixture.stem + ".sse")
            stream_path.write_text("".join(f"data: {value}\n\n" for value in events), encoding="utf-8")
            for chunk_size in (1, 3, 7):
                subprocess.run(
                    [stream_executable, "decode-stream", dialect, stream_path, str(chunk_size)],
                    cwd=ROOT, check=True,
                )

    print(f"provider fixtures verified through public codecs: {len(records) + len(request_records) + len(stream_records)}")


if __name__ == "__main__":
    main()
