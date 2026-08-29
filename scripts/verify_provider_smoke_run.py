#!/usr/bin/env python3
"""Verify that release smoke artifacts came from the trusted workflow run."""

from __future__ import annotations

import argparse
import json
from pathlib import Path

EXPECTED_ARTIFACTS = {
    "provider-smoke-openai-responses",
    "provider-smoke-openai-chat",
    "provider-smoke-anthropic-messages",
    "provider-smoke-deepseek-responses",
    "provider-smoke-deepseek-chat",
    "provider-smoke-deepseek-messages",
}
EXPECTED_WORKFLOW = ".github/workflows/provider-smoke.yml"


parser = argparse.ArgumentParser()
parser.add_argument("--run", type=Path, required=True)
parser.add_argument("--artifacts", type=Path, required=True)
parser.add_argument("--run-id", type=int, required=True)
parser.add_argument("--candidate", required=True)
parser.add_argument("--output", type=Path, required=True)
args = parser.parse_args()

run = json.loads(args.run.read_text(encoding="utf-8"))
artifacts = json.loads(args.artifacts.read_text(encoding="utf-8")).get("artifacts", [])
workflow_path = str(run.get("path", "")).split("@", 1)[0]
checks = {
    "run id": run.get("id") == args.run_id,
    "workflow path": workflow_path == EXPECTED_WORKFLOW,
    "workflow id": isinstance(run.get("workflow_id"), int),
    "event": run.get("event") == "workflow_dispatch",
    "branch": run.get("head_branch") == "main",
    "candidate": run.get("head_sha") == args.candidate,
    "status": run.get("status") == "completed",
    "conclusion": run.get("conclusion") == "success",
}
failed = [name for name, passed in checks.items() if not passed]
if failed:
    raise SystemExit(f"provider smoke run provenance mismatch: {failed}")

names = {artifact.get("name") for artifact in artifacts}
if names != EXPECTED_ARTIFACTS or len(artifacts) != len(EXPECTED_ARTIFACTS):
    raise SystemExit(f"provider smoke artifact set mismatch: {sorted(str(name) for name in names)}")

digests: dict[str, str] = {}
for artifact in artifacts:
    name = artifact["name"]
    digest = artifact.get("digest")
    workflow_run = artifact.get("workflow_run") or {}
    if artifact.get("expired") is not False or not isinstance(digest, str) or not digest.startswith("sha256:"):
        raise SystemExit(f"provider smoke artifact metadata is incomplete: {name}")
    if workflow_run.get("id") != args.run_id or workflow_run.get("head_sha") != args.candidate:
        raise SystemExit(f"provider smoke artifact belongs to another run: {name}")
    digests[name] = digest

provenance = {
    "runId": args.run_id,
    "workflowId": run["workflow_id"],
    "workflowPath": workflow_path,
    "event": run["event"],
    "headBranch": run["head_branch"],
    "headSha": run["head_sha"],
    "conclusion": run["conclusion"],
    "artifactDigests": dict(sorted(digests.items())),
}
args.output.write_text(json.dumps(provenance, indent=2) + "\n", encoding="utf-8")
print(f"provider smoke run provenance passed: {args.run_id}")
