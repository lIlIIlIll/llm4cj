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
parser.add_argument("--evidence-mode", choices=("live", "offline"), default="live")
parser.add_argument("--smoke-evidence", type=Path)
parser.add_argument("--smoke-provenance", type=Path)
parser.add_argument("--api-compatibility", type=Path, required=True)
args = parser.parse_args()
if args.evidence_mode == "live" and (args.smoke_evidence is None or args.smoke_provenance is None):
    parser.error("live evidence mode requires --smoke-evidence and --smoke-provenance")
api_compatibility = json.loads(args.api_compatibility.read_text(encoding="utf-8"))

provider_smoke: dict[str, object]
if args.evidence_mode == "live":
    assert args.smoke_evidence is not None and args.smoke_provenance is not None
    smoke_provenance = json.loads(args.smoke_provenance.read_text(encoding="utf-8"))
    provider_smoke = {
        "status": "passed",
        "candidateCommit": args.source_commit,
        "artifactCount": len(list(args.smoke_evidence.glob("*.json"))),
        "runId": smoke_provenance["runId"],
        "workflowId": smoke_provenance["workflowId"],
        "workflowPath": smoke_provenance["workflowPath"],
        "artifactDigests": smoke_provenance["artifactDigests"],
    }
else:
    provider_smoke = {
        "status": "advisory_not_run",
        "candidateCommit": args.source_commit,
        "artifactCount": 0,
        "reason": "offline evidence mode; provider smoke requires protected credentials",
    }

provider_cache = {
    "status": "advisory_not_run",
    "candidateCommit": args.source_commit,
    "reason": "cache experiment is optional and was not run for this candidate",
}

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
        "apiCompatibilitySha256": sha256(args.api_compatibility),
        "apiCompatibility": api_compatibility,
    },
    "providerSmoke": provider_smoke,
    "providerCache": provider_cache,
    "gates": [
        "check", "coverage", "contract", "stable API versus release tag",
        "exact Git stable consumer", "exact Git experimental consumer",
        "provider smoke (advisory; not run in offline mode)" if args.evidence_mode == "offline" else "provider smoke",
        "provider cache experiment (advisory; not run)"
    ],
}
args.output.write_text(json.dumps(evidence, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
