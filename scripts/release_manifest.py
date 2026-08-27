#!/usr/bin/env python3
"""Write machine-readable evidence for one exact llm4cj release candidate."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def coverage() -> dict[str, float]:
    lines: list[int] = []
    branches: list[int] = []
    for raw in (ROOT / "coverage/lcov.info").read_text().splitlines():
        if raw.startswith("DA:"):
            lines.append(int(raw.split(",", 1)[1]))
        elif raw.startswith("BRDA:"):
            value = raw.rsplit(",", 1)[1]
            branches.append(0 if value == "-" else int(value))
    return {
        "linePercent": round(100.0 * sum(v > 0 for v in lines) / len(lines), 1),
        "branchPercent": round(100.0 * sum(v > 0 for v in branches) / len(branches), 1),
    }


parser = argparse.ArgumentParser()
parser.add_argument("--output", type=Path, required=True)
parser.add_argument("--version", required=True)
parser.add_argument("--source-commit", required=True)
parser.add_argument("--yjson-commit", required=True)
parser.add_argument("--cjc-version", required=True)
parser.add_argument("--cjpm-version", required=True)
parser.add_argument("--smoke-evidence", type=Path, required=True)
args = parser.parse_args()

evidence = {
    "package": "llm4cj",
    "version": args.version,
    "tag": f"v{args.version}",
    "sourceCommit": args.source_commit,
    "dependencies": {"yjson": {"resolvedCommit": args.yjson_commit}},
    "toolchain": {"cjc": args.cjc_version, "cjpm": args.cjpm_version},
    "coverage": coverage(),
    "contracts": {
        "publicApiSha256": sha256(ROOT / "contract/public-api.txt"),
        "errorCodesSha256": sha256(ROOT / "contract/error-codes.txt"),
        "fixtureDigest": (ROOT / "contract/fixture-digest.txt").read_text().strip(),
    },
    "providerSmoke": {
        "candidateCommit": args.source_commit,
        "artifactCount": len(list(args.smoke_evidence.glob("*.json"))),
    },
    "gates": ["check", "coverage", "contract", "exact Git consumer", "provider smoke"],
}
args.output.write_text(json.dumps(evidence, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
