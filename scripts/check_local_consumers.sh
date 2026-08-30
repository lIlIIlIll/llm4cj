#!/usr/bin/env bash
set -euo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
work=$(mktemp -d -t llm4cj-local-consumers.XXXXXX)
trap 'rm -rf -- "$work"' EXIT

for consumer in external_consumer experimental_consumer; do
  target="$work/$consumer"
  cp -a "$root/support/$consumer/." "$target/"
  python3 - "$target/cjpm.toml" "$root" <<'PY'
import pathlib, re, sys
path, root = pathlib.Path(sys.argv[1]), sys.argv[2]
text = path.read_text()
text, count = re.subn(
    r'llm4cj = \{ git = "[^"]+", tag = "[^"]+" \}',
    'llm4cj = { path = "' + root + '" }',
    text,
)
if count != 1:
    raise SystemExit("consumer dependency shape drifted")
path.write_text(text)
PY
  (
    cd "$target"
    cjpm check
    cjpm build
    target/release/bin/main
  )
done

printf 'stable and experimental local consumers passed\n'
