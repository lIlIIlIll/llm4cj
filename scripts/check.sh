#!/usr/bin/env bash
set -euo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"

python3 scripts/check_docs.py
python3 scripts/check_examples.py
python3 scripts/check_contract.py
python3 scripts/check_api_compat.py
python3 scripts/test_quality_gates.py
python3 scripts/check_provider_smoke_security.py
python3 scripts/check_fixtures.py
cjpm clean
cjpm check
cjpm build
cjpm test

printf 'llm4cj check passed\n'
