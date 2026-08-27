#!/usr/bin/env python3
"""Fail if provider secrets can be exposed to an arbitrary candidate checkout."""

from pathlib import Path

workflow = (Path(__file__).resolve().parent.parent / ".github/workflows/provider-smoke.yml").read_text(encoding="utf-8")

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

print("provider smoke trust boundary passed")
