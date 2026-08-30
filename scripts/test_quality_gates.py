#!/usr/bin/env python3
"""Regression tests for repository quality gates."""

from __future__ import annotations

import contextlib
import io
import tempfile
import unittest
from pathlib import Path

import check_api_compat
import check_patch_coverage
import bootstrap_repository


class PatchCoverageTests(unittest.TestCase):
    def test_compact_ranges(self) -> None:
        self.assertEqual(check_patch_coverage.compact_ranges([]), "-")
        self.assertEqual(check_patch_coverage.compact_ranges([1, 2, 3, 5, 8, 9]), "1-3,5,8-9")

    def test_patch_branches_only_count_source_decisions(self) -> None:
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        source = Path(temporary.name) / "sample.cj"
        source.write_text(
            "let value = parse()\n"
            "if (value > 0 && ready) { use(value) }\n"
            "case Some(found) => found\n"
            "catch (error: Exception) { throw error }\n",
            encoding="utf-8",
        )
        self.assertEqual(
            check_patch_coverage.source_decision_lines(source, {1, 2, 3, 4}),
            {2, 3, 4},
        )

    def fixture(self, include_second_da: bool) -> tuple[Path, list[str]]:
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        root = Path(temporary.name)
        source = root / "src/sample.cj"
        source.parent.mkdir(parents=True)
        source.write_text("let first = 1\nlet second = 2\n", encoding="utf-8")
        diff = root / "patch.diff"
        diff.write_text(
            "diff --git a/src/sample.cj b/src/sample.cj\n"
            "--- /dev/null\n"
            "+++ b/src/sample.cj\n"
            "@@ -0,0 +1,2 @@\n"
            "+let first = 1\n"
            "+let second = 2\n",
            encoding="utf-8",
        )
        gcov_root = root / "cov"
        gcov_root.mkdir()
        (gcov_root / "sample.gcov").write_text(
            f"        -:    0:Source:{source}\n"
            "        1:    1:let first = 1\n"
            "    #####:    2:let second = 2\n",
            encoding="utf-8",
        )
        lcov = root / "lcov.info"
        records = "DA:1,1\n" + ("DA:2,0\n" if include_second_da else "")
        lcov.write_text("TN:\nSF:src/sample.cj\n" + records + "end_of_record\n", encoding="utf-8")
        baseline = root / "baseline.toml"
        baseline.write_text("patch_line_percent = 40.0\npatch_branch_percent = 0.0\n", encoding="utf-8")
        arguments = [
            "--diff", str(diff), "--lcov", str(lcov), "--gcov-root", str(gcov_root),
            "--baseline", str(baseline), "--root", str(root),
        ]
        return root, arguments

    def test_missing_da_for_instrumented_line_fails(self) -> None:
        _, arguments = self.fixture(include_second_da=False)
        with self.assertRaisesRegex(SystemExit, "src/sample.cj:2"):
            check_patch_coverage.main(arguments)

    def test_zero_hit_da_remains_in_denominator(self) -> None:
        _, arguments = self.fixture(include_second_da=True)
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            self.assertEqual(check_patch_coverage.main(arguments), 0)
        self.assertIn("patch line coverage: 1/2 = 50.0%", output.getvalue())


class ApiCompatibilityTests(unittest.TestCase):
    def test_only_root_stable_package_sources_are_compared(self) -> None:
        self.assertTrue(check_api_compat.is_stable_source_path("src/model.cj"))
        self.assertFalse(check_api_compat.is_stable_source_path("src/model_test.cj"))
        self.assertFalse(check_api_compat.is_stable_source_path("src/experimental/experimental.cj"))

    def test_zero_major_requires_minor_bump(self) -> None:
        self.assertFalse(check_api_compat.permits_shape_change((0, 2, 0), (0, 2, 1)))
        self.assertTrue(check_api_compat.permits_shape_change((0, 2, 0), (0, 3, 0)))

    def test_stable_release_requires_major_bump(self) -> None:
        self.assertFalse(check_api_compat.permits_shape_change((1, 2, 0), (1, 3, 0)))
        self.assertTrue(check_api_compat.permits_shape_change((1, 2, 0), (2, 0, 0)))


class RepositoryBootstrapTests(unittest.TestCase):
    def test_settings_close_the_trunk_policy(self) -> None:
        settings = bootstrap_repository.load_settings()
        requests = bootstrap_repository.requests_for("owner/llm4cj", settings)
        self.assertEqual(requests[0][0:2], ("PATCH", "/repos/owner/llm4cj"))
        self.assertEqual(
            requests[1][0:2],
            ("PUT", "/repos/owner/llm4cj/branches/main/protection"),
        )
        self.assertTrue(requests[0][2]["allow_squash_merge"])
        self.assertFalse(requests[0][2]["allow_merge_commit"])
        self.assertTrue(requests[0][2]["delete_branch_on_merge"])
        self.assertEqual(
            set(requests[1][2]["required_status_checks"]["contexts"]),
            bootstrap_repository.EXPECTED_CONTEXTS,
        )

    def test_invalid_repository_name_is_rejected(self) -> None:
        with self.assertRaisesRegex(ValueError, "owner/name"):
            bootstrap_repository.requests_for("llm4cj", bootstrap_repository.load_settings())


if __name__ == "__main__":
    unittest.main()
