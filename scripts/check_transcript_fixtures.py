#!/usr/bin/env python3
"""Verify ordered transcript fixtures through the public provider probe."""

from __future__ import annotations

import json
import subprocess
from pathlib import Path
from urllib.parse import urlparse

ROOT = Path(__file__).resolve().parent.parent
PROBE = ROOT / "support/provider_probe"
FIXTURES = ROOT / "fixtures/transcripts"
EXPECTED = {
    "openai-responses-additional-tools.json": (
        "openai-responses-additional-tools",
        "openai.responses.v1",
        "gpt-5.4",
        "developers.openai.com",
    ),
    "anthropic-messages-tool-changes.json": (
        "anthropic-messages-tool-changes",
        "anthropic.messages.v1",
        "claude-opus-5",
        "platform.claude.com",
    ),
    "kimi-chat-dynamic-tools.json": (
        "kimi-chat-dynamic-tools",
        "kimi.chat.v1",
        "kimi-k3",
        "platform.kimi.ai",
    ),
}


def run_probe(*args: str) -> str:
    result = subprocess.run(
        [PROBE / "target/release/bin/main", *args],
        cwd=ROOT,
        check=True,
        text=True,
        capture_output=True,
    )
    return result.stdout.strip()


def main() -> None:
    subprocess.run(["cjpm", "build"], cwd=PROBE, check=True)
    records = sorted(FIXTURES.glob("*.json"))
    if [record.name for record in records] != sorted(EXPECTED):
        raise SystemExit("transcript fixture inventory is not the approved three-scenario set")

    for fixture in records:
        scenario, dialect, model, source_host = EXPECTED[fixture.name]
        record = json.loads(fixture.read_text(encoding="utf-8"))
        if record.get("scenario") != scenario or record.get("fixture") != dialect:
            raise SystemExit(f"transcript fixture identity mismatch: {fixture.name}")
        if record.get("model") != model or record.get("captured") != "2026-09-21":
            raise SystemExit(f"transcript fixture model or capture date mismatch: {fixture.name}")
        source = record.get("source")
        if not isinstance(source, str) or urlparse(source).hostname != source_host:
            raise SystemExit(f"transcript fixture source is not the approved provider document: {fixture.name}")
        request = record.get("request")
        profile = record.get("profile")
        expected = record.get("expected")
        negative = record.get("negative")
        if not isinstance(request, dict) or request.get("model") != model:
            raise SystemExit(f"transcript fixture request is incomplete: {fixture.name}")
        if not isinstance(request.get("initial_context"), dict) or not isinstance(request.get("items"), list):
            raise SystemExit(f"transcript fixture request lacks full transcript input: {fixture.name}")
        if not isinstance(profile, dict) or profile.get("endpoint_profile_id") != dialect or profile.get("contract_version") != "1":
            raise SystemExit(f"transcript fixture profile identity is incomplete: {fixture.name}")
        if not isinstance(profile.get("capabilities"), list) or not profile["capabilities"]:
            raise SystemExit(f"transcript fixture profile capabilities are missing: {fixture.name}")
        if not isinstance(expected, dict) or not isinstance(expected.get("body"), dict) or not isinstance(expected.get("headers"), list):
            raise SystemExit(f"transcript fixture expected output is incomplete: {fixture.name}")
        if expected["body"].get("model") != model:
            raise SystemExit(f"transcript fixture expected body model mismatch: {fixture.name}")
        headers = expected["headers"]
        if any(not isinstance(header, dict) for header in headers):
            raise SystemExit(f"transcript fixture headers are malformed: {fixture.name}")
        names = [header.get("name") for header in headers]
        if len(names) != len(set(names)) or "content-type" not in names or "accept" not in names:
            raise SystemExit(f"transcript fixture headers are not deterministic: {fixture.name}")
        actual = json.loads(run_probe("encode-transcript-fixture", scenario, model))
        if actual != expected:
            raise SystemExit(f"public encoder drifted from transcript fixture: {fixture.name}")
        if not isinstance(negative, list) or not negative:
            raise SystemExit(f"transcript fixture lacks a negative case: {fixture.name}")
        for case in negative:
            if not isinstance(case, dict) or not all(isinstance(case.get(key), str) for key in ("scenario", "model", "error")):
                raise SystemExit(f"transcript fixture negative case is malformed: {fixture.name}")
            actual_error = run_probe("negative-transcript-fixture", case["scenario"], case["model"])
            if actual_error != case["error"]:
                raise SystemExit(f"negative transcript fixture drifted: {fixture.name}")

    print(f"ordered transcript fixtures verified through public codecs: {len(records)}")


if __name__ == "__main__":
    main()
