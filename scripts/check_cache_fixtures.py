#!/usr/bin/env python3
"""Compare public typed cache requests with independent, sourced offline oracles."""

from __future__ import annotations

import argparse
from pathlib import Path
import subprocess

from check_fixtures import assert_equal, parse_json, validate_source
from consumer_compile import consumer_compile_options

ROOT = Path(__file__).resolve().parent.parent
PROBE = ROOT / "support/provider_probe"
ORACLE = ROOT / "fixtures/cache-requests.json"
REQUIRED_CASES = {
    "no-markers", "marker-five", "marker-hour", "marker-moved", "four-locations",
    "automatic-three", "image-target", "tool-lifecycle", "automatic-four",
    "ttl-order", "ttl-conflict", "deferred-target", "duplicate-target",
    "out-of-bounds", "missing-capability", "deepseek-rejected", "spoof-rejected",
    "second-tool-target", "custom-target-rejected", "custom-neighbor-rejected",
}


def validate_fixture(fixture: dict) -> list[dict]:
    validate_source(fixture["source"], "cache request fixtures")
    if fixture["live_provider"] != "not_run":
        raise ValueError("cache request fixtures are offline schema-derived evidence")
    cases = fixture["cases"]
    identifiers = [case["id"] for case in cases]
    if len(set(identifiers)) != len(identifiers) or set(identifiers) != REQUIRED_CASES:
        raise ValueError("cache request fixture coverage is incomplete or duplicated")
    for case in cases:
        if ("error" in case) == ("expected" in case):
            raise ValueError("cache fixture needs exactly one request or error oracle")
    return cases


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--probe", type=Path)
    parser.add_argument("--fixture", type=Path, default=ORACLE,
                        help="use the exact fixture registered by the shared public-check manifest")
    options = parser.parse_args()
    fixture = parse_json(options.fixture.read_text(encoding="utf-8"))
    cases = validate_fixture(fixture)
    executable = options.probe
    if executable is None:
        with consumer_compile_options(PROBE):
            subprocess.run(["cjpm", "build"], cwd=PROBE, check=True)
        executable = PROBE / "target/release/bin/main"
    count = 0
    for case in cases:
        if "error" in case:
            expected = {"kind": "error", "error": fixture["error_defaults"] | case["error"]}
        else:
            expected = fixture["request_defaults"] | case["expected"]
        forms = []
        for mode in ("direct", "restored", "builder"):
            result = subprocess.run([str(executable), "inspect-cache", case["id"], mode],
                                    cwd=ROOT, check=True, capture_output=True, text=True)
            actual = parse_json(result.stdout)
            assert_equal(actual, expected, f"cache.{case['id']}.{mode}")
            forms.append(actual)
            count += 1
        assert_equal(forms[0], forms[1], f"cache.{case['id']}.snapshot-pair")
        assert_equal(forms[0], forms[2], f"cache.{case['id']}.builder-pair")
    print(f"public cache requests verified: {len(cases)} scenarios, {count} full oracle comparisons, live provider not_run")


if __name__ == "__main__":
    main()
