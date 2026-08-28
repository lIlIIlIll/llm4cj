#!/usr/bin/env python3
"""Fail if provider secrets can be exposed to an arbitrary candidate checkout."""

import json
import subprocess
import tempfile
from pathlib import Path

workflow = (Path(__file__).resolve().parent.parent / ".github/workflows/provider-smoke.yml").read_text(encoding="utf-8")
release = (Path(__file__).resolve().parent.parent / ".github/workflows/release.yml").read_text(encoding="utf-8")

required = [
    "if: github.ref == 'refs/heads/main'",
    "environment: provider-smoke",
    "ref: ${{ github.sha }}",
    'test "${REQUESTED_SHA}" = "${TRUSTED_SHA}"',
]
missing = [value for value in required if value not in workflow]
if missing:
    raise SystemExit(f"provider smoke trust boundary drifted; missing={missing}")
if "ref: ${{ inputs.candidate_sha }}" in workflow:
    raise SystemExit("provider smoke must not checkout candidate-controlled code in the secret-bearing job")

release_required = [
    "Verify provider smoke run provenance",
    "scripts/verify_provider_smoke_run.py",
    "PROVIDER_SMOKE_PROVENANCE:",
]
release_missing = [value for value in release_required if value not in release]
if release_missing:
    raise SystemExit(f"release smoke provenance boundary drifted; missing={release_missing}")

with tempfile.TemporaryDirectory() as raw:
    temp = Path(raw)
    candidate = "a" * 40
    run_id = 42
    run = {
        "id": run_id,
        "workflow_id": 7,
        "path": ".github/workflows/provider-smoke.yml@main",
        "event": "workflow_dispatch",
        "head_branch": "main",
        "head_sha": candidate,
        "status": "completed",
        "conclusion": "success",
    }
    names = [
        "openai-responses", "openai-chat", "anthropic-messages",
        "deepseek-responses", "deepseek-chat", "deepseek-messages",
    ]
    artifacts = {"artifacts": [
        {
            "name": f"provider-smoke-{name}", "expired": False,
            "digest": f"sha256:{index:064x}",
            "workflow_run": {"id": run_id, "head_sha": candidate},
        }
        for index, name in enumerate(names, 1)
    ]}
    run_path = temp / "run.json"
    artifacts_path = temp / "artifacts.json"
    output_path = temp / "provenance.json"
    run_path.write_text(json.dumps(run), encoding="utf-8")
    artifacts_path.write_text(json.dumps(artifacts), encoding="utf-8")
    verifier = Path(__file__).resolve().parent / "verify_provider_smoke_run.py"
    command = [str(verifier), "--run", str(run_path), "--artifacts", str(artifacts_path), "--run-id", str(run_id), "--candidate", candidate, "--output", str(output_path)]
    subprocess.run(command, check=True, capture_output=True, text=True)
    run["workflow_id"] = 8
    run["path"] = ".github/workflows/forged.yml@main"
    run_path.write_text(json.dumps(run), encoding="utf-8")
    forged = subprocess.run(command, check=False, capture_output=True, text=True)
    if forged.returncode == 0:
        raise SystemExit("release accepted provider smoke artifacts from another workflow")

print("provider smoke trust boundary passed")
