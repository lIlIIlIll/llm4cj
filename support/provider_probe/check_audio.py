#!/usr/bin/env python3
"""Compare the public consumer with an independent, schema-derived audio oracle."""

from __future__ import annotations

import argparse
import copy
import json
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "scripts"))
from check_fixtures import assert_equal, load_json, parse_json, validate_source


def substitute(value: object, format_name: str) -> object:
    if isinstance(value, str):
        return format_name if value == "<output-format>" else value
    if isinstance(value, list):
        return [substitute(item, format_name) for item in value]
    if isinstance(value, dict):
        return {key: substitute(item, format_name) for key, item in value.items()}
    return value


def expected(fixture: dict, format_name: str) -> dict:
    # These templates are hand-authored; no candidate output feeds the oracle.
    oracle = substitute(fixture["oracle"], format_name)
    blocks = [oracle["text"], oracle["audio"]]
    reply = {"response_id": "audio-fixture", "model": "audio-resolved-model", "raw_stop_reason": "stop",
             "blocks": blocks, "usage": oracle["usage"], "choices": [{"index": 0, "raw_stop_reason": "stop",
             "outcome": {"kind": "completed"}, "blocks": blocks, "message_spans": []}]}
    snapshot = {"format": "llm4cj.transcript", "version": 3, "initial_context": {"instructions": [], "tools": []},
                "items": [{"kind": "message", "value": {"role": "assistant", "blocks": [oracle["text"], oracle["replay"]], "message_spans": []}}]}
    next_body = substitute(fixture["request"], format_name)
    next_body["messages"] = oracle["continuation_messages"]
    headers = [{"name": "content-type", "value": "application/json"}, {"name": "accept", "value": "application/json"}]
    projection = {"kind": "ok", "snapshot": snapshot, "restored_snapshot": snapshot, "encoded": {"body": next_body, "headers": headers}}
    return {"state": {"kind": "completed", "reply": reply}, "continuation": {"default": projection, "choices": [{"index": 0, "result": projection}]}}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("probe", type=Path)
    parser.add_argument("fixture", type=Path)
    args = parser.parse_args()
    probe = args.probe.resolve()
    fixture = load_json(args.fixture)
    validate_source(fixture["source"], "audio fixtures")
    if fixture["schema_derived"] is not True or fixture["live"] != "not_run":
        raise ValueError("audio fixtures must retain the offline schema-derived evidence boundary")
    if fixture["formats"] != ["wav", "mp3", "aac", "flac", "opus", "pcm16"]:
        raise ValueError("audio fixtures must cover all six supported output formats exactly once")
    comparisons = 0

    def run(*command: str) -> dict:
        return parse_json(subprocess.check_output([str(probe), *command], text=True))

    with tempfile.TemporaryDirectory(prefix="llm4cj-audio-golden-") as temporary:
        fixed_path, stream_path = Path(temporary) / "fixed.json", Path(temporary) / "stream.sse"
        fixed_path.write_text(json.dumps(fixture["fixed"], ensure_ascii=False))
        stream_path.write_text("".join("data: " + (event if isinstance(event, str) else json.dumps(event)) + "\n\n" for event in fixture["stream"]))
        for format_name in fixture["formats"]:
            for mode in ("fixed", "stream"):
                body = copy.deepcopy(substitute(fixture["request"], format_name))
                headers = [{"name": "content-type", "value": "application/json"},
                           {"name": "accept", "value": "text/event-stream" if mode == "stream" else "application/json"}]
                if mode == "stream":
                    body.update(stream=True)
                assert_equal(run("encode-audio", format_name, mode), {"body": body, "headers": headers}, f"audio.{format_name}.{mode}.request")
                comparisons += 1
            oracle = expected(fixture, format_name)
            fixed = run("inspect-audio-fixed", format_name, str(fixed_path))
            assert_equal(fixed, oracle, f"audio.{format_name}.fixed")
            comparisons += 1
            for width in ("1", "17", "65536"):
                streamed = run("inspect-audio-stream", format_name, str(stream_path), width)
                assert_equal(streamed, oracle, f"audio.{format_name}.{width}.stream")
                assert_equal(streamed, fixed, f"audio.{format_name}.{width}.pair")
                comparisons += 2
    print(f"audio schema-derived golden passed: {comparisons} full comparisons, 6 formats, live:not_run")


if __name__ == "__main__":
    main()
