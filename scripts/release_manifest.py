#!/usr/bin/env python3
"""Write machine-readable evidence for one llm4cj release candidate."""

from __future__ import annotations

import argparse
import json
from pathlib import Path


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--source-commit", required=True)
    parser.add_argument("--yjson-commit", required=True)
    parser.add_argument("--cjc-version", required=True)
    parser.add_argument("--cjpm-version", required=True)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    evidence = {
        "package": "llm4cj",
        "version": args.version,
        "tag": f"v{args.version}",
        "sourceCommit": args.source_commit,
        "dependencies": {
            "yjson": {"branch": "main", "resolvedCommit": args.yjson_commit}
        },
        "toolchain": {
            "cjc": args.cjc_version,
            "cjpm": args.cjpm_version,
            "channel": "nightly",
        },
        "gates": [
            "cjpm check",
            "cjpm build",
            "cjpm test",
            "cjpm bundle",
            "clean external Git consumer",
        ],
    }
    args.output.write_text(
        json.dumps(evidence, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
