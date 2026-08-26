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
if ! git ls-files --error-unmatch cjpm.lock >/dev/null 2>&1; then
  printf 'release gate requires a tracked cjpm.lock\n' >&2
  exit 2
fi

bash scripts/check.sh

consumer_root=$(mktemp -d -t llm4cj-consumer.XXXXXX)
trap 'rm -rf -- "$consumer_root"' EXIT
cp -a support/external_consumer/. "$consumer_root/"
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
)

bundle="target/llm4cj-${version}.cjp"
if [[ ! -f "$bundle" ]]; then
  printf 'bundle not found: %s\n' "$bundle" >&2
  exit 1
fi

yjson_commit=$(grep -E '^ *yjson = ' cjpm.lock | grep -Eo 'commitId = "[0-9a-f]{40}"' | grep -Eo '[0-9a-f]{40}')
if [[ ! "$yjson_commit" =~ ^[0-9a-f]{40}$ ]]; then
  printf 'cannot resolve yjson commit from cjpm.lock\n' >&2
  exit 1
fi

mkdir -p dist
cp -f "$bundle" "dist/llm4cj-${version}.cjp"
(
  cd dist
  sha256sum "llm4cj-${version}.cjp" > SHA256SUMS
)

python3 scripts/release_manifest.py \
  --output dist/release-manifest.json \
  --version "$version" \
  --source-commit "$(git rev-parse HEAD)" \
  --yjson-commit "$yjson_commit" \
  --cjc-version "$(cjc -v 2>&1 | head -n 1)" \
  --cjpm-version "$(cjpm --version 2>&1 | head -n 1)"

printf 'llm4cj release gate passed: %s\n' "$version"
