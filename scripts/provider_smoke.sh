#!/usr/bin/env bash
set -euo pipefail

if [[ -z "${DIALECT:-}" || -z "${PROVIDER_SMOKE_CONFIG:-}" ]]; then
  echo 'provider smoke requires DIALECT and PROVIDER_SMOKE_CONFIG' >&2
  exit 2
fi

python3 - "$DIALECT" "$PROVIDER_SMOKE_CONFIG" "${CANDIDATE_SHA:-}" <<'PY'
import json, pathlib, sys, urllib.error, urllib.request
dialect, raw, candidate = sys.argv[1:]
config = json.loads(raw)
entry = config.get(dialect)
if not isinstance(entry, dict) or not entry.get("endpoint") or not isinstance(entry.get("body"), dict):
    raise SystemExit(f"no verified provider smoke configuration for {dialect}")
request = urllib.request.Request(
    entry["endpoint"], data=json.dumps(entry["body"]).encode(),
    headers=entry.get("headers", {}), method="POST",
)
try:
    with urllib.request.urlopen(request, timeout=60) as response:
        status = response.status
        json.loads(response.read())
except urllib.error.HTTPError as error:
    raise SystemExit(f"provider smoke failed for {dialect}: HTTP {error.code}")
result = {"dialect": dialect, "status": "passed", "http_status": status, "candidate_sha": candidate}
pathlib.Path("provider-smoke-result.json").write_text(json.dumps(result, separators=(",", ":")) + "\n")
PY
