#!/usr/bin/env bash
set -euo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
version=${1:-}
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  printf 'usage: scripts/release_gate.sh <major.minor.patch>\n' >&2
  exit 2
fi

cd "$root"
if [[ -n "$(git status --porcelain)" ]]; then
  printf 'release gate requires a clean checkout\n' >&2
  exit 2
fi
if ! grep -Eq "^version = \"${version}\"$" cjpm.toml; then
  printf 'manifest version does not match %s\n' "$version" >&2
  exit 2
fi
candidate=$(git rev-parse HEAD)
if [[ ! "$candidate" =~ ^[0-9a-f]{40}$ ]]; then
  printf 'cannot resolve candidate commit\n' >&2
  exit 2
fi
if ! git ls-files --error-unmatch cjpm.lock >/dev/null 2>&1; then
  printf 'release gate requires a tracked cjpm.lock\n' >&2
  exit 2
fi
smoke_dir=${PROVIDER_SMOKE_EVIDENCE_DIR:-}
smoke_provenance=${PROVIDER_SMOKE_PROVENANCE:-}
if [[ -z "$smoke_dir" || ! -d "$smoke_dir" ]]; then
  printf 'PROVIDER_SMOKE_EVIDENCE_DIR must contain six successful candidate smoke artifacts\n' >&2
  exit 2
fi
if [[ -z "$smoke_provenance" || ! -f "$smoke_provenance" ]]; then
  printf 'PROVIDER_SMOKE_PROVENANCE must identify the trusted workflow run and artifact digests\n' >&2
  exit 2
fi
python3 - "$smoke_dir" "$smoke_provenance" "$candidate" <<'PY'
import json, pathlib, sys
root, provenance_path, candidate = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]), sys.argv[3]
expected = {"openai-responses", "openai-chat", "anthropic-messages", "deepseek-responses", "deepseek-chat", "deepseek-messages"}
records = [json.loads(path.read_text()) for path in sorted(root.glob("*.json"))]
actual = {record.get("dialect") for record in records if record.get("status") == "passed" and record.get("candidate_sha") == candidate}
if actual != expected:
    raise SystemExit(f"provider smoke evidence mismatch: expected {sorted(expected)}, got {sorted(actual)}")
provenance = json.loads(provenance_path.read_text())
if provenance.get("workflowPath") != ".github/workflows/provider-smoke.yml" or provenance.get("event") != "workflow_dispatch":
    raise SystemExit("provider smoke provenance identifies an untrusted workflow")
if provenance.get("headBranch") != "main" or provenance.get("headSha") != candidate or provenance.get("conclusion") != "success":
    raise SystemExit("provider smoke provenance does not match the release candidate")
digests = provenance.get("artifactDigests")
if not isinstance(digests, dict) or set(digests) != {f"provider-smoke-{value}" for value in expected}:
    raise SystemExit("provider smoke provenance has an incomplete artifact digest set")
PY

scripts/check.sh
scripts/coverage.sh

consumer_root=$(mktemp -d -t llm4cj-consumer.XXXXXX)
trap 'rm -rf -- "$consumer_root"' EXIT
cp -a support/external_consumer/. "$consumer_root/"
python3 - "$consumer_root/cjpm.toml" "$candidate" <<'PY'
import pathlib, re, sys
path, candidate = pathlib.Path(sys.argv[1]), sys.argv[2]
text = path.read_text()
text, count = re.subn(r'llm4cj = \{ git = "([^"]+)", tag = "[^"]+" \}', rf'llm4cj = {{ git = "\1", commitId = "{candidate}" }}', text)
if count != 1:
    raise SystemExit("external consumer dependency shape drifted")
path.write_text(text)
PY
(
  cd "$consumer_root"
  cjpm check
  cjpm build
  cjpm test
  target/release/bin/main
  if grep -R -E '/home/|\.\./' cjpm.toml cjpm.lock src; then
    printf 'external consumer contains a local path fallback\n' >&2
    exit 1
  fi
  if ! grep -Fq "commitId = \"$candidate\"" cjpm.toml; then
    printf 'external consumer is not pinned to the candidate commit\n' >&2
    exit 1
  fi
)

yjson_commit=$(grep -E '^ *yjson = ' cjpm.lock | grep -Eo 'commitId = "[0-9a-f]{40}"' | grep -Eo '[0-9a-f]{40}')
if [[ "$yjson_commit" != "92858f75aedc3dd6f7322789117854514549e62c" ]]; then
  printf 'yjson is not pinned to the approved commit\n' >&2
  exit 1
fi

mkdir -p dist
python3 scripts/release_manifest.py \
  --output dist/release-manifest.json \
  --version "$version" \
  --source-commit "$candidate" \
  --yjson-commit "$yjson_commit" \
  --cjc-version "$(cjc -v 2>&1 | head -n 1)" \
  --cjpm-version "$(cjpm --version 2>&1 | head -n 1)" \
  --smoke-evidence "$smoke_dir" \
  --smoke-provenance "$smoke_provenance"
(
  cd dist
  sha256sum release-manifest.json > SHA256SUMS
)

printf 'llm4cj release gate passed: %s at %s\n' "$version" "$candidate"
