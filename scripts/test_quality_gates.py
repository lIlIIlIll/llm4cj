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


class PatchCoverageTests(unittest.TestCase):
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
    def test_zero_major_requires_minor_bump(self) -> None:
        self.assertFalse(check_api_compat.permits_shape_change((0, 2, 0), (0, 2, 1)))
        self.assertTrue(check_api_compat.permits_shape_change((0, 2, 0), (0, 3, 0)))

    def test_stable_release_requires_major_bump(self) -> None:
        self.assertFalse(check_api_compat.permits_shape_change((1, 2, 0), (1, 3, 0)))
        self.assertTrue(check_api_compat.permits_shape_change((1, 2, 0), (2, 0, 0)))


if __name__ == "__main__":
    unittest.main()
