#!/usr/bin/env bash
set -euo pipefail

if [[ -z "${DIALECT:-}" || -z "${PROVIDER_SMOKE_CONFIG:-}" ]]; then
  echo 'provider smoke requires DIALECT and PROVIDER_SMOKE_CONFIG' >&2
  exit 2
fi

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
probe_root="$root/support/protocol_probe"
(cd "$probe_root" && cjpm build)
response_file=$(mktemp -t llm4cj-provider-response.XXXXXX.json)
trap 'rm -f -- "$response_file"' EXIT
export LLM4CJ_PROTOCOL_PROBE="$probe_root/target/release/bin/main"

python3 - "$DIALECT" "$response_file" "${CANDIDATE_SHA:-}" <<'PY'
import json, os, pathlib, subprocess, sys, urllib.error, urllib.request
dialect, response_path, candidate = sys.argv[1:]
config = json.loads(os.environ["PROVIDER_SMOKE_CONFIG"])
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
        body = response.read()
        json.loads(body)
except urllib.error.HTTPError as error:
    raise SystemExit(f"provider smoke failed for {dialect}: HTTP {error.code}")
pathlib.Path(response_path).write_bytes(body)
subprocess.run([os.environ["LLM4CJ_PROTOCOL_PROBE"], dialect, response_path], check=True)
result = {"dialect": dialect, "status": "passed", "http_status": status, "candidate_sha": candidate}
pathlib.Path("provider-smoke-result.json").write_text(json.dumps(result, separators=(",", ":")) + "\n")
PY
