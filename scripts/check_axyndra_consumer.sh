#!/usr/bin/env bash
set -euo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
checkout=${1:-}
mode=${2:-local}
if [[ -z "$checkout" || ! -d "$checkout" || "$#" -gt 2 || ( "$mode" != local && "$mode" != --git-pin ) ]]; then
  printf 'usage: scripts/check_axyndra_consumer.sh <Axyndra checkout> [--git-pin]\n' >&2
  exit 2
fi
if [[ -z "${CANGJIE_STDX_PATH:-}" || ! -f "$CANGJIE_STDX_PATH/stdx.net.http.cjo" ]]; then
  printf 'matching dynamic CANGJIE_STDX_PATH with stdx.net.http.cjo is required\n' >&2
  exit 2
fi
IFS= read -r base < "$root/support/axyndra/base-commit.txt"
if [[ "$(git -C "$checkout" rev-parse "$base^{commit}")" != "$base" ]]; then
  printf 'Axyndra consumer base commit %s is unavailable\n' "$base" >&2
  exit 2
fi
work=$(mktemp -d -t llm4cj-axyndra-consumer.XXXXXX)
trap 'rm -rf -- "$work"' EXIT
git -C "$checkout" archive "$base" | tar -x -C "$work"
git -C "$work" apply "$root/support/axyndra/contract-migration.patch"
(
  cd "$work"
  python3 scripts/dependency_pin_gate.py
  python3 scripts/dependency_pin_gate_test.py
)
if [[ "$mode" == local ]]; then
  python3 - "$work" "$root" <<'PY'
import pathlib, re, sys
work, root = pathlib.Path(sys.argv[1]), sys.argv[2]
manifest = work / "model_adapters/cjpm.toml"
text, count = re.subn(
    r'"llm4cj" = \{ git = "[^"]+", (?:(?:tag|commitId) = "[^"]+", ){1,2}output-type = "static" \}',
    '"llm4cj" = { path = "' + root + '", output-type = "static" }',
    manifest.read_text(),
)
if count != 1:
    raise SystemExit("Axyndra llm4cj dependency shape drifted")
manifest.write_text(text)
for lock in work.rglob("cjpm.lock"):
    # Retain all other reviewed dependency pins; only the replaced llm4cj
    # remote entry is no longer meaningful for this local integration check.
    lock.write_text(re.sub(r'(?m)^ *llm4cj = .*\n', '', lock.read_text()))
PY
fi
export LD_LIBRARY_PATH="$work/libs/process4cj/native:$CANGJIE_STDX_PATH:${LD_LIBRARY_PATH:-}"
python3 "$root/scripts/consumer_compile.py" "$work" bash -eu -c '
  scripts/prepare_native_deps.sh
  cjpm check --member model_adapters
  if [ -n "${LLM4CJ_CONSUMER_COMPILE_OPTION:-}" ]; then
    cjpm build --member model_adapters -V
  else
    cjpm build --member model_adapters
  fi
  cjpm test --member model_adapters
'
printf 'Axyndra model_adapters consumer gate passed at %s (%s dependency)\n' "$base" "$mode"
