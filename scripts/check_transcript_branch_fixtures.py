#!/usr/bin/env python3
"""Compare public transcript branches with independent native fixture oracles."""

from __future__ import annotations

import argparse
from pathlib import Path

from check_fixtures import assert_equal, fixture_path, load_json, run_probe


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--probe", type=Path, required=True)
    parser.add_argument("--fixture", type=Path, required=True)
    options = parser.parse_args()
    fixture = load_json(options.fixture)
    names = ["openai-responses", "anthropic-messages", "kimi-chat"]
    assert_equal(fixture["live_provider"], "not_run", "branches.live_provider")
    assert_equal(fixture["source_fixtures"], [f"transcripts/{name}.json" for name in names], "branches.sources")
    assert_equal(fixture["fork_index"], 3, "branches.boundary")
    assert_equal([case["name"] for case in fixture["cases"]], names, "branches.names")
    actual = run_probe(options.probe, "inspect-transcript-branches", str(options.fixture))
    expected = []
    for case in fixture["cases"]:
        provenance = load_json(fixture_path(f"transcripts/{case['name']}.json"))
        context = {
            "instructions": [{"role": "system", "text": "Initial instruction"}],
            "tools": [{"name": name, "description": f"Tool {name}", "schema": {"type": "object", "properties": {}},
                       "version": "1", "deferred": name == "B" and case["name"] == "anthropic-messages"}
                      for name in ("A", "B")],
        }
        expected.append({
            "name": case["name"],
            "prefix_snapshot": {"format": "llm4cj.transcript", "version": 2, "initial_context": context, "items": case["prefix_items"]},
            "plans": [{"body": provenance["body"], "headers": case["headers"]},
                      {"body": case["prefix_body"], "headers": case["headers"]},
                      {"body": case["continuation_body"], "headers": case["headers"]}],
            "restored": [True, True, True], "source_unchanged": True,
        })
    assert_equal(actual, {"cases": expected}, "transcript-branches")
    print("transcript branch fixtures passed: 3 native dialects, 9 complete plans")


if __name__ == "__main__":
    main()
