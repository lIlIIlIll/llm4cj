#!/usr/bin/env python3
"""Unit tests for the trusted pull-request metadata policy."""

import unittest

from pr_metadata import GateResult, PullRequestFacts, evaluate


SHA = "0123456789abcdef0123456789abcdef01234567"


def facts(**changes: object) -> PullRequestFacts:
    values: dict[str, object] = {
        "number": 17,
        "branch": "docs/clarify-streaming",
        "title": "docs: clarify streaming lifecycle",
        "body": "Risk: routine\nIssue: N/A: documentation-only clarification",
        "author": "contributor",
        "head_sha": SHA,
        "files": (("docs/streaming.md", "modified"),),
        "open_issue_numbers": frozenset(),
        "land_permissions": (),
        "author_permission": "read",
    }
    values.update(changes)
    return PullRequestFacts(**values)  # type: ignore[arg-type]


class PullRequestMetadataTests(unittest.TestCase):
    def assert_state(self, expected: str, **changes: object) -> GateResult:
        result = evaluate(facts(**changes))
        self.assertEqual(expected, result.state, result.errors)
        return result

    def test_routine_change_accepts_explained_issue_exception(self) -> None:
        self.assert_state("success")

    def test_routine_change_rejects_placeholder_issue_exception(self) -> None:
        self.assert_state(
            "failure",
            body="Risk: routine\nIssue: N/A: <reason>",
        )

    def test_invalid_branch_and_title_fail(self) -> None:
        result = self.assert_state(
            "failure", branch="feature_bad", title="Add a feature"
        )
        self.assertEqual(2, len(result.errors))

    def test_sensitive_path_must_be_declared_high(self) -> None:
        result = self.assert_state(
            "failure", files=(("src/codec.cj", "modified"),)
        )
        self.assertIn("Risk: high", result.errors[0])

    def test_modified_test_is_high_risk(self) -> None:
        self.assert_state(
            "failure", files=(("scripts/test_quality_gates.py", "modified"),)
        )

    def test_new_test_does_not_auto_upgrade_risk(self) -> None:
        self.assert_state(
            "success", files=(("scripts/test_new_policy.py", "added"),)
        )

    def test_high_risk_requires_open_same_repository_issue(self) -> None:
        result = self.assert_state(
            "failure",
            body="Risk: high\nFixes #41",
            files=(("src/codec.cj", "modified"),),
        )
        self.assertIn("open same-repository issue", result.errors[0])

    def test_high_risk_waits_for_exact_sha_confirmation(self) -> None:
        result = self.assert_state(
            "pending",
            body="Risk: high\nFixes #41",
            files=(("src/codec.cj", "modified"),),
            open_issue_numbers=frozenset({41}),
        )
        self.assertIn(SHA, result.summary)

    def test_writer_can_land_exact_sha(self) -> None:
        self.assert_state(
            "success",
            body="Risk: high\nFixes #41",
            files=(("src/codec.cj", "modified"),),
            open_issue_numbers=frozenset({41}),
            land_permissions=((f"/land {SHA}", "write"),),
        )

    def test_old_sha_or_read_permission_cannot_land(self) -> None:
        self.assert_state(
            "pending",
            body="Risk: high\nFixes #41",
            files=(("src/codec.cj", "modified"),),
            open_issue_numbers=frozenset({41}),
            land_permissions=(("/land " + "f" * 40, "admin"),),
        )
        self.assert_state(
            "pending",
            body="Risk: high\nFixes #41",
            files=(("src/codec.cj", "modified"),),
            open_issue_numbers=frozenset({41}),
            land_permissions=((f"/land {SHA}", "read"),),
        )

    def test_dependabot_skips_issue_and_branch_exceptions_but_needs_land(self) -> None:
        self.assert_state(
            "pending",
            author="dependabot[bot]",
            branch="dependabot/github_actions/actions-checkout-5",
            title="build(deps): bump actions/checkout",
            body="Risk: high",
            files=((".github/workflows/ci.yml", "modified"),),
        )

    def test_private_advisory_exception_requires_writer_author(self) -> None:
        self.assert_state(
            "pending",
            body="Risk: high\nSecurity-Advisory: private",
            files=(("src/codec.cj", "modified"),),
            author_permission="write",
        )
        self.assert_state(
            "failure",
            body="Risk: high\nSecurity-Advisory: private",
            files=(("src/codec.cj", "modified"),),
            author_permission="read",
        )


if __name__ == "__main__":
    unittest.main()
