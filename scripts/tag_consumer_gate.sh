#!/usr/bin/env bash
set -euo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
version=${1:-}
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  printf 'usage: scripts/tag_consumer_gate.sh <major.minor.patch>\n' >&2
  exit 2
fi

tag="v$version"
candidate=$(git -C "$root" rev-parse HEAD)
tag_commit=$(git -C "$root" rev-list -n 1 "$tag")
if [[ "$tag_commit" != "$candidate" ]]; then
  printf '%s resolves to %s, expected candidate %s\n' "$tag" "$tag_commit" "$candidate" >&2
  exit 1
fi

consumer_root=$(mktemp -d -t llm4cj-tag-consumer.XXXXXX)
trap 'rm -rf -- "$consumer_root"' EXIT
cp -a "$root/support/external_consumer/." "$consumer_root/"
python3 - "$consumer_root/cjpm.toml" "$tag" <<'PY'
import pathlib, re, sys
path, tag = pathlib.Path(sys.argv[1]), sys.argv[2]
text = path.read_text()
text, count = re.subn(r'(llm4cj = \{ git = "[^"]+", tag = ")[^"]+(" \})', rf'\g<1>{tag}\2', text)
if count != 1:
    raise SystemExit("external consumer tag dependency shape drifted")
path.write_text(text)
PY

(
  cd "$consumer_root"
  cjpm clean
  cjpm check
  cjpm build
  cjpm test
  target/release/bin/main
  if grep -R -E '/home/|\.\./' cjpm.toml cjpm.lock src; then
    printf 'tag consumer contains a local path fallback\n' >&2
    exit 1
  fi
  if ! grep -Fq "commitId = \"$candidate\"" cjpm.lock; then
    printf 'tag consumer did not resolve %s to candidate %s\n' "$tag" "$candidate" >&2
    exit 1
  fi
)

printf 'tag consumer gate passed: %s at %s\n' "$tag" "$candidate"
