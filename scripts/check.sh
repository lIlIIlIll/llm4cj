#!/usr/bin/env bash
set -euo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"

cjpm clean
cjpm check
cjpm build
cjpm test

printf 'llm4cj check passed\n'
