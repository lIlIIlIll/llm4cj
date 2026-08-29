#!/usr/bin/env bash
set -euo pipefail

if [[ -z "${DIALECT:-}" || -z "${PROVIDER_SMOKE_CONFIG:-}" ]]; then
  echo 'provider smoke requires DIALECT and PROVIDER_SMOKE_CONFIG' >&2
  exit 2
fi

probe='support/provider_probe/target/release/bin/main'
if [[ ! -x "$probe" ]]; then
  echo 'provider smoke requires the public codec probe to be built' >&2
  exit 2
fi

python3 - "$DIALECT" "$PROVIDER_SMOKE_CONFIG" "${CANDIDATE_SHA:-}" "$probe" <<'PY'
import json, pathlib, subprocess, sys, tempfile, urllib.error, urllib.request
dialect, raw, candidate, probe = sys.argv[1:]
config = json.loads(raw)
entry = config.get(dialect)
if not isinstance(entry, dict) or not entry.get("endpoint") or not isinstance(entry.get("body"), dict):
    raise SystemExit(f"no verified provider smoke configuration for {dialect}")
model = entry["body"].get("model")
if not isinstance(model, str) or not model:
    raise SystemExit(f"provider smoke model is missing for {dialect}")
encoded = subprocess.run([probe, "encode", dialect, model], check=True, text=True, capture_output=True).stdout.strip()
body = json.loads(encoded)
if body.get("model") != model or body.get("stream") is not True:
    raise SystemExit(f"public encoder did not produce the expected streaming request for {dialect}")
request = urllib.request.Request(
    entry["endpoint"], data=encoded.encode(), headers=entry.get("headers", {}), method="POST",
)
try:
    with urllib.request.urlopen(request, timeout=60) as response:
        status = response.status
        content_type = response.headers.get_content_type()
        payload = bytearray()
        while chunk := response.read(8192):
            payload.extend(chunk)
            if len(payload) > 64 * 1024 * 1024:
                raise SystemExit(f"provider smoke response exceeded 64 MiB for {dialect}")
except urllib.error.HTTPError as error:
    raise SystemExit(f"provider smoke failed for {dialect}: HTTP {error.code}")
if content_type != "text/event-stream":
    raise SystemExit(f"provider smoke expected text/event-stream for {dialect}, got {content_type}")
with tempfile.NamedTemporaryFile(prefix="llm4cj-provider-", suffix=".sse") as stream:
    stream.write(payload)
    stream.flush()
    for chunk_size in (1, 3, 7, 4096):
        subprocess.run([probe, "decode-stream", dialect, stream.name, str(chunk_size)], check=True, text=True, capture_output=True)
result = {"dialect": dialect, "status": "passed", "http_status": status, "streaming": True, "public_encoder": True, "candidate_sha": candidate}
pathlib.Path(f"provider-smoke-{dialect}.json").write_text(json.dumps(result, separators=(",", ":")) + "\n")
PY
