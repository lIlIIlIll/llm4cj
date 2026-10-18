#!/usr/bin/env python3
"""Compare public typed codec results with independent, sourced fixture oracles."""

from __future__ import annotations

import argparse
import datetime
import json
import re
import subprocess
import tempfile
from decimal import Decimal
from pathlib import Path
from urllib.parse import urlsplit

from consumer_compile import consumer_compile_options

ROOT = Path(__file__).resolve().parent.parent
FIXTURES = ROOT / "fixtures"
PROBE = ROOT / "support/provider_probe"
LEGACY_PROBE = ROOT / "support/protocol_probe"
MANIFEST = FIXTURES / "manifest.json"
DIALECTS = {
    "openai.responses.v1": "openai-responses",
    "openai.codex.responses.v1": "openai-codex-responses",
    "deepseek.responses.v1": "deepseek-responses",
    "openai.chat.v1": "openai-chat",
    "deepseek.chat.v1": "deepseek-chat",
    "kimi.chat.v1": "kimi-chat",
    "anthropic.messages.v1": "anthropic-messages",
    "deepseek.messages.v1": "deepseek-messages",
}
SOURCE_HOSTS = {
    "platform.openai.com", "developers.openai.com", "docs.anthropic.com",
    "platform.claude.com", "api-docs.deepseek.com", "platform.kimi.ai",
    "json-schema.org",
}


def reject_constant(value: str) -> None:
    raise ValueError(f"non-JSON numeric constant: {value}")


def unique_object(fields: list[tuple[str, object]]) -> dict:
    result: dict = {}
    for name, value in fields:
        if name in result:
            raise ValueError(f"duplicate JSON field: {name}")
        result[name] = value
    return result


def parse_json(value: str) -> object:
    return json.loads(value, parse_float=Decimal, parse_constant=reject_constant,
                      object_pairs_hook=unique_object)


def load_json(path: Path) -> object:
    return parse_json(path.read_text(encoding="utf-8"))


def dump_json(value: object) -> str:
    """Serialize fixture envelopes without converting exact numbers to floats."""
    if value is None:
        return "null"
    if type(value) is bool:
        return "true" if value else "false"
    if type(value) in (int, Decimal):
        return str(value)
    if type(value) is str:
        return json.dumps(value, ensure_ascii=False)
    if type(value) is list:
        return "[" + ",".join(dump_json(item) for item in value) + "]"
    if type(value) is dict:
        return "{" + ",".join(json.dumps(key) + ":" + dump_json(item)
                              for key, item in value.items()) + "}"
    raise ValueError(f"unexpected fixture value type: {type(value).__name__}")


def assert_equal(actual: object, expected: object, path: str) -> None:
    numbers = (int, Decimal)
    if type(actual) in numbers and type(expected) in numbers:
        if actual == expected:
            return
    elif type(actual) is type(expected):
        if type(expected) is dict:
            if actual.keys() != expected.keys():
                raise AssertionError(f"{path}: fields actual={sorted(actual)} expected={sorted(expected)}")
            for key in expected:
                assert_equal(actual[key], expected[key], f"{path}.{key}")
            return
        if type(expected) is list:
            if len(actual) != len(expected):
                raise AssertionError(f"{path}: length actual={len(actual)} expected={len(expected)}")
            for index, (left, right) in enumerate(zip(actual, expected)):
                assert_equal(left, right, f"{path}[{index}]")
            return
        if actual == expected:
            return
    raise AssertionError(f"{path}: actual={actual!r} expected={expected!r}")


def fixture_path(relative: str) -> Path:
    if not isinstance(relative, str) or not relative.endswith(".json"):
        raise ValueError("fixture reference must be a relative JSON path")
    path = FIXTURES / relative
    if Path(relative).is_absolute() or ".." in Path(relative).parts or not path.is_file():
        raise ValueError(f"invalid fixture reference: {relative}")
    if not path.resolve().is_relative_to(FIXTURES.resolve()):
        raise ValueError(f"fixture reference escapes fixture directory: {relative}")
    return path


def validate_source(source: dict, label: str) -> None:
    url = urlsplit(source.get("url", ""))
    if url.scheme != "https" or url.hostname not in SOURCE_HOSTS or url.username:
        raise ValueError(f"{label}: source must be a primary protocol document")
    datetime.date.fromisoformat(source.get("checked_at", ""))
    if not source.get("revision") or not source.get("notes"):
        raise ValueError(f"{label}: source revision and derivation notes are required")
    kind = source.get("kind")
    if kind not in {"official_example", "schema_derived", "authorized_capture"}:
        raise ValueError(f"{label}: unknown source kind")
    if kind == "authorized_capture" and not all(source.get(key) for key in
                                               ("authorization", "captured_at", "sanitization")):
        raise ValueError(f"{label}: capture authorization and sanitization are required")


def validate_manifest() -> dict:
    manifest = load_json(MANIFEST)
    if manifest.get("version") != 1 or manifest.get("live_provider") != "not_run":
        raise ValueError("fixture manifest version or offline evidence boundary changed")
    entries = manifest.get("dialects", [])
    if {entry["id"]: entry["probe"] for entry in entries} != DIALECTS or len(entries) != len(DIALECTS):
        raise ValueError("fixture manifest must cover all eight named stable dialects")
    for entry in entries:
        protocol = "responses" if ".responses." in entry["id"] else "chat_completions" if ".chat." in entry["id"] else "messages"
        if entry["protocol"] != protocol:
            raise ValueError("fixture dialect and protocol disagree")
    identifiers: set[str] = set()
    coverage = {dialect: set() for dialect in DIALECTS}
    for case in manifest["cases"]:
        identifier = case["id"]
        if not re.fullmatch(r"[a-z0-9_-]+", identifier) or identifier in identifiers:
            raise ValueError(f"duplicate or invalid fixture scenario: {identifier}")
        identifiers.add(identifier)
        if DIALECTS.get(case["dialect"]) != case["probe"]:
            raise ValueError(f"{identifier}: dialect and public codec disagree")
        validate_source(case["source"], identifier)
        if not case["scenario"]:
            raise ValueError(f"{identifier}: semantic scenarios are required")
        coverage[case["dialect"]].update(case["scenario"])
        fixture_path(case["expected"])
        oracle = load_json(fixture_path(case["expected"]))
        wire = case["wire"]
        if type(case["pair"]) is not bool and case["pair"] != "error_kind_code":
            raise ValueError(f"{identifier}: unknown pair comparison policy")
        if "cancel" in wire and (type(wire["cancel"]) is not bool or "stream" not in wire):
            raise ValueError(f"{identifier}: cancellation requires a stream and a boolean flag")
        modes = [mode for mode in ("fixed", "stream", "websocket") if mode in wire]
        if not modes or set(wire) - {"fixed", "stream", "websocket", "cancel"}:
            raise ValueError(f"{identifier}: invalid wire modes")
        for mode in modes:
            fixture_path(wire[mode])
            if mode not in oracle and "canonical" not in oracle:
                raise ValueError(f"{identifier}: missing independent {mode} oracle")
        if case["pair"] and not {"fixed", "stream"}.issubset(wire):
            raise ValueError(f"{identifier}: pair needs both fixed and stream")
    for dialect, scenarios in coverage.items():
        needed = {"text", "tool", "refusal", "usage", "provider-failure", "truncated", "continuation"}
        if ".responses." in dialect:
            needed |= {"phase", "reasoning", "native-replay"}
        elif dialect != "openai.chat.v1":
            needed |= {"reasoning", "native-replay"}
        if ".chat." in dialect:
            needed.add("logprobs")
        if not needed.issubset(scenarios):
            raise ValueError(f"{dialect}: missing semantic coverage {sorted(needed - scenarios)}")
    if len(manifest["requests"]) != len(DIALECTS) or {Path(path).stem for path in manifest["requests"]} != set(DIALECTS.values()):
        raise ValueError("request fixtures must cover all eight named codecs")
    expected_transcripts = {
        "transcripts/openai-responses.json", "transcripts/anthropic-messages.json",
        "transcripts/kimi-chat.json",
    }
    if len(manifest["transcripts"]) != len(expected_transcripts) or set(manifest["transcripts"]) != expected_transcripts:
        raise ValueError("the three native transcript provenance fixtures must remain present")
    for relative in manifest["requests"] + manifest["transcripts"]:
        fixture_path(relative)
    for check in manifest.get("public_checks", []):
        identifier = check["id"]
        if not re.fullmatch(r"[a-z0-9_-]+", identifier) or identifier in identifiers:
            raise ValueError("duplicate or invalid public fixture check")
        identifiers.add(identifier)
        if check["command"] not in {"check-schema", "check-structured"}:
            raise ValueError("unknown public fixture check command")
        fixture_path(check["fixture"])
        validate_source(check["source"], identifier)
    return manifest


def fixture_inventory(manifest: dict | None = None) -> list[Path]:
    """Exact contract input set; unrelated untracked artifacts are never adopted."""
    manifest = validate_manifest() if manifest is None else manifest
    relatives = {"manifest.json", *manifest["requests"], *manifest["transcripts"]}
    relatives.update(check["fixture"] for check in manifest.get("public_checks", []))
    for case in manifest["cases"]:
        relatives.add(case["expected"])
        relatives.update(value for key, value in case["wire"].items() if key != "cancel")
    return [fixture_path(relative) for relative in sorted(relatives)]


def run_probe(executable: Path, *arguments: str) -> dict:
    result = subprocess.run([str(executable), *arguments], cwd=ROOT, check=True,
                            text=True, capture_output=True)
    value = parse_json(result.stdout)
    if type(value) is not dict:
        raise ValueError("public inspector must print exactly one JSON object")
    return value


def oracle_for(oracle: dict, mode: str) -> dict:
    return oracle[mode] if mode in oracle else oracle["canonical"]


def verify_case(executable: Path, case: dict, temporary: Path) -> int:
    label = case["id"]
    oracle = load_json(fixture_path(case["expected"]))
    wire, actual, count = case["wire"], {}, 0
    if "fixed" in wire:
        record = load_json(fixture_path(wire["fixed"]))
        path = temporary / (label + ".json")
        path.write_text(dump_json(record["response"]), encoding="utf-8")
        actual["fixed"] = run_probe(executable, "inspect-fixed", case["probe"], str(path))
        assert_equal(actual["fixed"], oracle_for(oracle, "fixed"), label + ".fixed")
        count += 1
    if "stream" in wire:
        record = load_json(fixture_path(wire["stream"]))
        events = record["events"]
        if not events or not all(type(event) is str for event in events):
            raise ValueError(f"{label}: nonempty raw event strings are required")
        command = "inspect-cancel" if wire.get("cancel") else "inspect-stream"
        for ending, sizes in (("\n", (65536, 1, 3, 7)), ("\r\n", (7,)), ("\r", (7,))):
            payload = "".join("data: " + event + ending + ending for event in events).encode()
            if len(payload) > 65536:
                raise ValueError(f"{label}: increase the explicit full-buffer probe bound")
            path = temporary / (label + ".sse")
            path.write_bytes(payload)
            for size in sizes:
                value = run_probe(executable, command, case["probe"], str(path), str(size))
                assert_equal(value, oracle_for(oracle, "stream"),
                             f"{label}.stream[ending={ending!r},bytes={size}]")
                actual.setdefault("stream", value)
                count += 1
    if "websocket" in wire:
        record = load_json(fixture_path(wire["websocket"]))
        path = temporary / (label + ".jsonl")
        path.write_text("\n".join(record["events"]), encoding="utf-8")
        value = run_probe(executable, "inspect-websocket", case["probe"], str(path))
        assert_equal(value, oracle_for(oracle, "websocket"), label + ".websocket")
        assert_equal(value.get("result", value), actual.get("fixed", actual.get("stream")),
                     label + ".websocket-canonical-pair")
        count += 1
    if case["pair"] is True:
        assert_equal(actual["fixed"], actual["stream"], label + ".fixed-stream-pair")
    elif case["pair"] == "error_kind_code":
        for field in ("kind", "code"):
            assert_equal(actual["fixed"]["state"]["error"][field],
                         actual["stream"]["state"]["error"][field], label + ".error-pair." + field)
    return count


def verify_requests(executable: Path, manifest: dict) -> int:
    for relative in manifest["requests"]:
        name = Path(relative).stem
        plan = run_probe(executable, "encode-fixture", name, "fixture-model")
        assert_equal(plan["body"], load_json(fixture_path(relative)), relative + ".body")
        headers = [
            {"name": "content-type", "value": "application/json"},
            {"name": "accept", "value": "text/event-stream" if name == "openai-codex-responses" else "application/json"},
        ]
        assert_equal(plan["headers"], headers, relative + ".headers")
    return len(manifest["requests"])


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--validate-only", action="store_true", help="validate provenance and inventory without Cangjie")
    parser.add_argument("--probe", type=Path, help="use an already built inspector (targeted validation only)")
    parser.add_argument("--case", action="append", dest="cases", help="run exact case ID; default runs every case")
    options = parser.parse_args()
    manifest = validate_manifest()
    inventory = fixture_inventory(manifest)
    if options.validate_only:
        print(f"fixture manifest validated: {len(manifest['cases'])} scenarios, {len(inventory)} files, live provider not_run")
        return
    executable = options.probe
    if executable is None:
        with consumer_compile_options(LEGACY_PROBE), consumer_compile_options(PROBE):
            subprocess.run(["cjpm", "build"], cwd=LEGACY_PROBE, check=True)
            subprocess.run(["cjpm", "build"], cwd=PROBE, check=True)
        executable = PROBE / "target/release/bin/main"
    chosen = manifest["cases"]
    if options.cases:
        requested = set(options.cases)
        chosen = [case for case in chosen if case["id"] in requested]
        if {case["id"] for case in chosen} != requested:
            raise ValueError("unknown requested fixture case")
    count = 0
    with tempfile.TemporaryDirectory(prefix="llm4cj-fixtures-") as raw:
        for case in chosen:
            count += verify_case(executable, case, Path(raw))
    requests = verify_requests(executable, manifest) if not options.cases else 0
    if not options.cases:
        for check in manifest.get("public_checks", []):
            subprocess.run([str(executable), check["command"], str(fixture_path(check["fixture"]))],
                           cwd=ROOT, check=True)
    print(f"public fixture semantics verified: {len(chosen)} scenarios, {count} decode comparisons, "
          f"{requests} requests, live provider not_run")


if __name__ == "__main__":
    main()
