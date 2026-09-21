#!/usr/bin/env bash
set -euo pipefail

if [[ -z "${DIALECT:-}" || -z "${PROVIDER_CACHE_CONFIG:-}" || -z "${CANDIDATE_SHA:-}" ]]; then
  echo 'provider cache experiment requires DIALECT, PROVIDER_CACHE_CONFIG, and CANDIDATE_SHA' >&2
  exit 2
fi

if [[ ! "${CANDIDATE_SHA}" =~ ^[0-9a-f]{40}$ ]]; then
  echo 'provider cache experiment requires a full candidate SHA' >&2
  exit 2
fi

probe='support/provider_probe/target/release/bin/main'
if [[ ! -x "$probe" ]]; then
  echo 'provider cache experiment requires the public codec probe to be built' >&2
  exit 2
fi

python3 - "$DIALECT" "$PROVIDER_CACHE_CONFIG" "$CANDIDATE_SHA" "$probe" <<'PY'
from __future__ import annotations

import json
import pathlib
import re
import subprocess
import tempfile
import time
import urllib.error
import urllib.request

import sys

DIALECT, raw_config, candidate, probe = sys.argv[1:]
PROFILE_IDS = {
    "openai-responses-additional-tools": "openai.responses.v1",
    "anthropic-messages-tool-changes": "anthropic.messages.v1",
    "kimi-chat-dynamic-tools": "kimi.chat.v1",
}
try:
    config = json.loads(raw_config)
except json.JSONDecodeError as error:
    raise SystemExit(f"provider cache configuration is not valid JSON: {error.msg}")
entry = config.get(DIALECT)
if not isinstance(entry, dict):
    raise SystemExit(f"no provider cache configuration for {DIALECT}")
scenario = entry.get("scenario")
endpoint = entry.get("endpoint")
model = entry.get("model")
model_label = entry.get("model_label")
prefix = entry.get("stable_prefix")
stage_suffixes = entry.get("stage_suffixes")
headers = entry.get("headers", {})
repeats = entry.get("repeats", 5)
if scenario not in PROFILE_IDS or not isinstance(endpoint, str) or not endpoint:
    raise SystemExit(f"provider cache configuration is missing a supported scenario or endpoint for {DIALECT}")
if not isinstance(model, str) or not model or not isinstance(model_label, str) or not re.fullmatch(r"[A-Za-z0-9._-]{1,64}", model_label):
    raise SystemExit(f"provider cache configuration requires a sanitized model_label for {DIALECT}")
if not isinstance(prefix, str) or not (128 <= len(prefix.encode("utf-8")) <= 65536):
    raise SystemExit("provider cache stable_prefix must be between 128 and 65536 UTF-8 bytes")
if not isinstance(stage_suffixes, dict) or not all(isinstance(stage_suffixes.get(name), str) for name in ("cold", "warm", "update")):
    raise SystemExit("provider cache stage_suffixes must define cold, warm, and update strings")
if not stage_suffixes["update"]:
    raise SystemExit("provider cache update stage must change the prompt suffix")
if not isinstance(headers, dict) or any(not isinstance(key, str) or not isinstance(value, str) for key, value in headers.items()):
    raise SystemExit("provider cache headers must be a string-to-string object")
if not isinstance(repeats, int) or isinstance(repeats, bool) or not (5 <= repeats <= 20):
    raise SystemExit("provider cache repeats must be between 5 and 20")


def encode(prompt: str) -> dict:
    result = subprocess.run(
        [probe, "encode-transcript-fixture", scenario, model, prompt],
        check=True,
        text=True,
        capture_output=True,
    )
    plan = json.loads(result.stdout)
    if plan.get("body", {}).get("model") != model:
        raise SystemExit("public transcript probe produced a different model")
    return plan


def merged_headers(plan: dict) -> dict[str, str]:
    merged = dict(headers)
    for header in plan.get("headers", []):
        name = header["name"]
        existing = next((key for key in merged if key.lower() == name), None)
        if existing is not None and merged[existing] != header["value"]:
            raise SystemExit(f"provider cache headers conflict with public requirements: {name}")
        merged[existing or name] = header["value"]
    return merged


def decode_usage(payload: bytes) -> tuple[str, dict | None, str | None]:
    with tempfile.NamedTemporaryFile(prefix="llm4cj-cache-response-", suffix=".json") as response:
        response.write(payload)
        response.flush()
        decoded = subprocess.run(
            [probe, "decode-response-usage", DIALECT.replace("-additional-tools", "").replace("-tool-changes", "").replace("-dynamic-tools", ""), model, response.name],
            check=False,
            text=True,
            capture_output=True,
        )
    if decoded.returncode != 0:
        return "error", None, decoded.stdout.strip()[-128:] or "decode_failed"
    try:
        state = json.loads(decoded.stdout)
    except json.JSONDecodeError:
        return "error", None, "decode_invalid_json"
    usage = state.get("usage")
    return state.get("terminal", "unknown"), usage if isinstance(usage, dict) else None, None


samples = []
network_failures = 0
decode_failures = 0
for stage in ("cold", "warm", "update"):
    prompt = prefix + stage_suffixes[stage]
    plan = encode(prompt)
    wire_body = json.dumps(plan["body"], separators=(",", ":")).encode("utf-8")
    request_headers = merged_headers(plan)
    for attempt in range(1, repeats + 1):
        request = urllib.request.Request(endpoint, data=wire_body, headers=request_headers, method="POST")
        started = time.perf_counter_ns()
        status = None
        payload = b""
        failure_class = None
        try:
            with urllib.request.urlopen(request, timeout=120) as response:
                status = response.status
                while chunk := response.read(8192):
                    payload += chunk
                    if len(payload) > 64 * 1024 * 1024:
                        raise RuntimeError("response_too_large")
        except urllib.error.HTTPError as error:
            status = error.code
            payload = error.read(64 * 1024 * 1024 + 1)
            failure_class = "HTTPError"
        except Exception as error:
            failure_class = type(error).__name__
            network_failures += 1
        elapsed_ms = round((time.perf_counter_ns() - started) / 1_000_000, 3)
        if payload:
            terminal, usage, decode_error = decode_usage(payload)
            if decode_error is not None:
                decode_failures += 1
        else:
            terminal, usage, decode_error = "unknown", None, "no_response_body"
            decode_failures += 1
        samples.append({
            "stage": stage,
            "attempt": attempt,
            "http_status": status,
            "elapsed_ms": elapsed_ms,
            "terminal": terminal,
            "usage": usage,
            "decode_error": decode_error,
            "network_failure": failure_class,
        })

observed_reads = sum(1 for sample in samples if isinstance(sample["usage"], dict) and "cache_read_tokens" in sample["usage"])
observed_writes = sum(1 for sample in samples if isinstance(sample["usage"], dict) and "cache_write_tokens" in sample["usage"])
report = {
    "status": "complete" if network_failures == 0 and decode_failures == 0 else "incomplete",
    "dialect": DIALECT,
    "scenario": scenario,
    "profile_id": PROFILE_IDS[scenario],
    "contract_version": "1",
    "model_label": model_label,
    "candidate_sha": candidate,
    "repeats": repeats,
    "stages": ["cold", "warm", "update"],
    "cache_read_observed_samples": observed_reads,
    "cache_write_observed_samples": observed_writes,
    "cache_unknown_samples": len(samples) - observed_reads,
    "samples": samples,
}
pathlib.Path(f"provider-cache-{DIALECT}.json").write_text(json.dumps(report, separators=(",", ":")) + "\n", encoding="utf-8")
if report["status"] != "complete":
    raise SystemExit("provider cache experiment completed with incomplete network or decode evidence")
PY
