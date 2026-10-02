#!/usr/bin/env python3
"""Record reproducible native-update cache observations, never inferred hits.

Requests and normalized usage come from support/transcript_probe's public API.
The output retains metadata/counters, not credentials, prompts, or responses.
"""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import random
import re
import subprocess
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request

from consumer_compile import consumer_compile_options

ROOT = Path(__file__).resolve().parent.parent
PROBE_PROJECT = ROOT / "support/transcript_probe"
PROBE = PROBE_PROJECT / "target/release/bin/main"
PATHS = {"openai-responses", "anthropic-messages", "kimi-chat"}
COUNTERS = ("input_tokens", "output_tokens", "cache_read_tokens", "cache_write_tokens")
MAX_RESPONSE = 8 * 1024 * 1024


def canonical(value: object) -> bytes:
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode()


def digest(value: object) -> str:
    return hashlib.sha256(canonical(value)).hexdigest()


def probe(arguments: list[str]) -> dict:
    completed = subprocess.run([str(PROBE), *arguments], check=False, capture_output=True, text=True)
    if completed.returncode:
        raise ValueError("public codec probe failed before a usable plan/observation")
    value = json.loads(completed.stdout)
    if not isinstance(value, dict):
        raise ValueError("public codec probe returned a non-object")
    return value


def model_input(path: str, body: dict) -> dict:
    fields = ("tools", "input") if path == "openai-responses" else ("tools", "system", "messages")
    return {name: body[name] for name in fields if name in body}


def verify_layout(path: str, warm: dict, native: dict, control: dict) -> None:
    before, after = warm["body"], native["body"]
    items = "input" if path == "openai-responses" else "messages"
    if after.get(items, [])[:len(before.get(items, []))] != before.get(items, []):
        raise ValueError("native update rewrote an existing model input item")
    if len(after.get(items, [])) != len(before.get(items, [])) + 1:
        raise ValueError("native update did not append exactly one native input item")
    for initial in ("tools", "system"):
        if before.get(initial) != after.get(initial):
            raise ValueError("native update rewrote the initial context")
    last = after[items][-1]
    if path == "openai-responses":
        valid = last.get("type") == "additional_tools" and last.get("role") == "developer"
    elif path == "anthropic-messages":
        valid = last.get("role") == "system" and last.get("content", [{}])[0].get("type") == "tool_addition"
    else:
        valid = last.get("role") == "system" and "tools" in last and "content" not in last
    if not valid or model_input(path, control["body"]) == model_input(path, after):
        raise ValueError("missing native mapping or changed-baseline control")


def normalize_usage(value: object) -> dict:
    usage = value if isinstance(value, dict) else {}
    output = {}
    for name in COUNTERS:
        counter = usage.get(name)
        if counter is not None and (type(counter) is not int or counter < 0):
            raise ValueError("normalized provider counter must be null or a nonnegative integer")
        output[name] = counter
        if name.startswith("cache_"):
            output[name.removesuffix("_tokens") + "_availability"] = "unknown" if counter is None else "reported"
    output["source"] = usage.get("source")
    return output


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise urllib.error.HTTPError(req.full_url, code, "redirect refused", headers, fp)


def request_once(path: str, entry: dict, plan: dict) -> dict:
    headers = {"content-type": "application/json", **entry.get("headers", {})}
    if any(key.lower() in {"authorization", "x-api-key", "cookie"} for key in headers):
        raise ValueError("credentials must come from auth_env, not the config file")
    for header in plan["headers"]:
        existing = next((key for key in headers if key.lower() == header["name"].lower()), None)
        if existing and headers[existing] != header["value"]:
            raise ValueError("materialized header conflicts with experiment configuration")
        headers[existing or header["name"]] = header["value"]
    key = os.environ.get(entry["auth_env"])
    if not key:
        raise ValueError("required credential environment variable is unavailable")
    headers[entry["auth_header"]] = entry.get("auth_prefix", "") + key
    request = urllib.request.Request(entry["endpoint"], data=canonical(plan["body"]), headers=headers, method="POST")
    started = time.monotonic_ns()
    try:
        response = urllib.request.build_opener(NoRedirect()).open(request, timeout=60)
    except urllib.error.HTTPError as error:
        response = error
    except (urllib.error.URLError, TimeoutError, OSError):
        return {"outcome": "transport_failed", "http_status": None,
                "elapsed_ms": (time.monotonic_ns() - started) / 1_000_000,
                "usage": normalize_usage(None)}
    with response:
        status = response.code
        payload = response.read(MAX_RESPONSE + 1)
    elapsed = (time.monotonic_ns() - started) / 1_000_000
    if len(payload) > MAX_RESPONSE:
        return {"outcome": "body_limit", "http_status": status, "elapsed_ms": elapsed, "usage": normalize_usage(None)}
    with tempfile.NamedTemporaryFile(prefix="llm4cj-cache-response-", suffix=".json") as temporary:
        temporary.write(payload)
        temporary.flush()
        decoded = probe(["decode", path, entry["model"], entry["endpoint"], str(status), temporary.name])
    return {"outcome": decoded["outcome"], "codec_error": decoded.get("error", ""),
            "http_status": status, "elapsed_ms": elapsed, "usage": normalize_usage(decoded.get("usage"))}


def validate_entry(path: str, entry: dict) -> None:
    if path not in PATHS or not isinstance(entry, dict):
        raise ValueError("unknown experiment path")
    endpoint = urllib.parse.urlsplit(entry.get("endpoint", ""))
    if endpoint.scheme != "https" or not endpoint.hostname or endpoint.username or endpoint.query or endpoint.fragment:
        raise ValueError("endpoint must be an exact HTTPS URL without credentials/query/fragment")
    if not entry.get("model") or "REPLACE" in entry["model"]:
        raise ValueError("configure an explicitly supported model")
    if not re.fullmatch(r"[A-Z][A-Z0-9_]*", entry.get("auth_env", "")):
        raise ValueError("auth_env must name a credential environment variable")
    if entry.get("auth_header", "").lower() not in {"authorization", "x-api-key"}:
        raise ValueError("unsupported auth header")
    if entry.get("options", {}).get("cache") not in {"provider-default", "automatic-default"}:
        raise ValueError("options.cache must be explicit")
    options = entry["options"]
    if set(options) != {"cache", "max_output_tokens"} or type(options["max_output_tokens"]) is not int or not 1 <= options["max_output_tokens"] <= 512:
        raise ValueError("options must contain only an explicit cache choice and a 1–512 output token limit")
    if path == "anthropic-messages" and entry["options"]["cache"] != "automatic-default":
        raise ValueError("Anthropic experiment requires explicit automatic caching")
    if path == "kimi-chat" and entry["options"]["cache"] != "provider-default":
        raise ValueError("Kimi uses provider automatic caching without an invented cache field")


def self_test() -> None:
    absent = normalize_usage({})
    zero = normalize_usage({"cache_read_tokens": 0, "cache_write_tokens": 0})
    assert absent["cache_read_tokens"] is None and absent["cache_read_availability"] == "unknown"
    assert zero["cache_read_tokens"] == 0 and zero["cache_read_availability"] == "reported"
    assert zero["cache_write_availability"] == "reported"
    failed = normalize_usage({"input_tokens": 12, "cache_read_tokens": 4})
    assert failed["cache_read_tokens"] == 4
    for invalid in (-1, False, "0"):
        try:
            normalize_usage({"cache_read_tokens": invalid})
        except ValueError:
            pass
        else:
            raise AssertionError("invalid counter accepted")
    print("cache experiment metadata self-test passed (offline; no live cache claim)")


def offline_check() -> None:
    """Compile and exercise the actual consumer with all network calls disabled."""
    checkout = checkout_state()
    with consumer_compile_options(PROBE_PROJECT) as compile_option:
        subprocess.run(["cjpm", "build"], cwd=PROBE_PROJECT, check=True)
        offline_check_prepared(compile_option, checkout)


def offline_check_prepared(compile_option: str | None, checkout: tuple[str, bool]) -> None:
    with tempfile.TemporaryDirectory(prefix="llm4cj-cache-offline-") as raw:
        work = Path(raw)
        config = json.loads((ROOT / "support/transcript_probe/cache-config.example.json").read_text())
        config["openai-responses"]["model"] = "fixture-model"
        config["anthropic-messages"]["model"] = "fixture-model"
        config_path, output_path = work / "config.json", work / "prepared.json"
        config_path.write_text(json.dumps(config))
        run_experiment(argparse.Namespace(config=config_path, output=output_path, prepare_only=True,
                                          samples=3, history_bytes=16384, random_seed=27003),
                       compile_option, checkout)
        record = json.loads(output_path.read_text())
        assert record["status"] == "prepared_only" and record["cache_benefit_claim"] is False
        assert record["probe_compilation"]["override_compile_option"] == compile_option
        assert len(record["paths"]) == 3
        for path_record in record["paths"]:
            assert len(path_record["samples"]) == 3
            for sample in path_record["samples"]:
                assert {arm["arm"] for arm in sample["arms"]} == {"warm", "native", "control"}
                assert all(arm["outcome"] == "not_run" and arm["usage"]["cache_read_tokens"] is None for arm in sample["arms"])
        completed = {"id": "probe", "status": "completed", "output": [{"type": "message", "content": [{"type": "output_text", "text": "OK"}]}]}
        cases = [
            ({**completed, "usage": {}}, "completed", None, None),
            ({**completed, "usage": {"input_tokens": 1, "input_tokens_details": {"cached_tokens": 0}}}, "completed", 0, 1),
            ({"error": {"type": "server_error", "message": "fixture failure"},
              "usage": {"input_tokens": 12, "input_tokens_details": {"cached_tokens": 4}}}, "provider_failed", 4, 12),
        ]
        for index, (response, expected_outcome, read_tokens, input_tokens) in enumerate(cases):
            response_path = work / f"response-{index}.json"
            response_path.write_text(json.dumps(response))
            value = probe(["decode", "openai-responses", "fixture-model", "https://api.openai.com/v1/responses", "200", str(response_path)])
            assert value["outcome"] == expected_outcome
            assert value["usage"]["cache_read_tokens"] == read_tokens
            assert value["usage"]["input_tokens"] == input_tokens
            if input_tokens is not None:
                assert value["usage"]["source"] == {"provider": "openai", "dialect": "openai.responses.v1"}
    print("cache experiment public consumer check passed (three paths; missing/zero/failure usage; offline)")


def checkout_state() -> tuple[str, bool]:
    candidate = subprocess.run(["git", "rev-parse", "HEAD"], cwd=ROOT, check=True, capture_output=True, text=True).stdout.strip()
    dirty = bool(subprocess.run(["git", "status", "--porcelain"], cwd=ROOT, check=True, capture_output=True, text=True).stdout)
    return candidate, dirty


def run_experiment(args: argparse.Namespace, compile_option: str | None, checkout: tuple[str, bool]) -> int:
    config = json.loads(args.config.read_text())
    if set(config) != PATHS:
        raise ValueError("configure all three native paths separately")
    if not PROBE.is_file():
        raise ValueError("build support/transcript_probe before running the experiment")
    candidate, dirty = checkout
    if dirty and not args.prepare_only:
        raise ValueError("live evidence requires a clean, fixed candidate commit")
    record = {"schema_version": 1, "experiment": "llm4cj.native-update-cache", "candidate_sha": candidate,
              "dirty_checkout": dirty, "status": "prepared_only" if args.prepare_only else "observed",
              "started_at": dt.datetime.now(dt.timezone.utc).isoformat(), "samples_per_path": args.samples,
              "history_bytes_requested": args.history_bytes, "random_seed": args.random_seed,
              "probe_compilation": {"override_compile_option": compile_option,
                                    "scope": "entry_project_and_all_dependencies" if compile_option else "default_flags",
                                    "fresh_build": True},
              "cache_benefit_claim": False, "paths": []}
    rng = random.Random(args.random_seed)
    for path, entry in sorted(config.items()):
        validate_entry(path, entry)
        options = entry["options"]
        metadata = {"path": path, "endpoint": entry["endpoint"], "model": entry["model"], "options": options,
                    "contract_version": 1, "profile_evidence": "caller_declared", "protocol_checked_at": "2026-10-02",
                    "samples": []}
        record["paths"].append(metadata)
        for sample in range(args.samples):
            seed = str(rng.randrange(10**9, 10**10))
            plans = {arm: probe(["encode", path, entry["model"], entry["endpoint"], arm, seed,
                                str(args.history_bytes), options["cache"], str(options.get("max_output_tokens", 64))])
                     for arm in ("warm", "native", "control")}
            verify_layout(path, plans["warm"], plans["native"], plans["control"])
            order = ["native", "control"]
            rng.shuffle(order)
            sample_record = {"sample": sample + 1, "prefix_seed": seed, "order": ["warm", *order], "arms": []}
            metadata["samples"].append(sample_record)
            for arm in sample_record["order"]:
                plan = plans[arm]
                observation = {"arm": arm, "request_sha256": digest(plan["body"]),
                               "model_input_sha256": digest(model_input(path, plan["body"])),
                               "request_bytes": len(canonical(plan["body"])), "headers": plan["headers"]}
                if args.prepare_only:
                    observation.update({"outcome": "not_run", "http_status": None, "elapsed_ms": None, "usage": normalize_usage(None)})
                else:
                    observation.update(request_once(path, entry, plan))
                sample_record["arms"].append(observation)
                args.output.parent.mkdir(parents=True, exist_ok=True)
                args.output.write_text(json.dumps(record, ensure_ascii=False, indent=2) + "\n")
    print(f"cache experiment {record['status']}: {args.output}; observed hits/benefits require separate analysis")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", type=Path)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--prepare-only", action="store_true", help="encode/layout check only; sends no requests")
    parser.add_argument("--samples", type=int, default=5)
    parser.add_argument("--history-bytes", type=int, default=65536)
    parser.add_argument("--random-seed", type=int, default=27003)
    parser.add_argument("--self-test", action="store_true")
    parser.add_argument("--offline-check", action="store_true", help="build and check public codec plans/usage without network calls")
    args = parser.parse_args()
    if args.self_test:
        self_test()
        return 0
    if args.offline_check:
        self_test()
        offline_check()
        return 0
    if not args.config or not args.output or args.samples < 3 or not 16384 <= args.history_bytes <= 1048576:
        parser.error("config/output, at least three samples, and a 16 KiB–1 MiB prefix are required")
    checkout = checkout_state()
    if checkout[1] and not args.prepare_only:
        raise ValueError("live evidence requires a clean, fixed candidate commit")
    with consumer_compile_options(PROBE_PROJECT) as compile_option:
        subprocess.run(["cjpm", "build"], cwd=PROBE_PROJECT, check=True)
        return run_experiment(args, compile_option, checkout)


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (ValueError, KeyError, json.JSONDecodeError, subprocess.CalledProcessError) as error:
        raise SystemExit(str(error)) from None
