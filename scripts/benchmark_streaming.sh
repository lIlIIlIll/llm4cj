#!/usr/bin/env bash
set -euo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
benchmark_root="$root/support/stream_benchmark"
cd "$benchmark_root"
cjpm build
target/release/bin/main
