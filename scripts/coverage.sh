#!/usr/bin/env bash
set -euo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"

python3 -c 'import shutil; shutil.rmtree("coverage", ignore_errors=True)'
cjpm clean
cjpm test --coverage --no-progress
mkdir -p coverage
cjcov --root . --source src --include src --exclude src/transport_test.cj \
  --output coverage/cjcov --branches --json --xml --html-details --keep
python3 scripts/cjcov_to_lcov.py \
  --root . --gcov-root cov_output --output coverage/lcov.info --baseline coverage-baseline.toml

printf 'llm4cj coverage passed\n'
