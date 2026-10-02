#!/usr/bin/env bash
set -euo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
benchmark_root="$root/support/stream_benchmark"
python3 "$root/scripts/consumer_compile.py" "$benchmark_root" bash -e -c '
cjpm build
target/release/bin/main
'
