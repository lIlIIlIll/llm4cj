#!/usr/bin/env python3
"""Regression tests for repository quality gates."""

from __future__ import annotations

import contextlib
import io
import json
import os
import subprocess
import sys
import tempfile
import tomllib
import unittest
from pathlib import Path
from unittest.mock import patch

import check_api_compat
import check_patch_coverage
import bootstrap_repository
import consumer_compile


class ConsumerCompileTests(unittest.TestCase):
    def project(self, content: bytes | None = None) -> tuple[Path, bytes]:
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        project = Path(temporary.name)
        original = content if content is not None else (
            b"# exact bytes must survive\r\n"
            b"[package]\r\nname = \"dummy\"\r\nversion = \"1.0.0\"\r\n"
            b"[dependencies]\r\noverride-compile-option = \"leave-me\"\r\n"
        )
        (project / "cjpm.toml").write_bytes(original)
        return project, original

    def command(self, project: Path, code: str, *arguments: str, option: str = "-O1") -> subprocess.CompletedProcess[str]:
        script = project / "dummy_command.py"
        script.write_text(code, encoding="utf-8")
        environment = dict(os.environ, LLM4CJ_CONSUMER_COMPILE_OPTION=option)
        return subprocess.run(
            [sys.executable, str(Path(consumer_compile.__file__).resolve()), str(project),
             sys.executable, str(script), *arguments],
            env=environment, capture_output=True, text=True, check=False,
        )

    def test_default_is_a_no_op_even_without_a_manifest(self) -> None:
        project, original = self.project()
        with patch.dict(os.environ, {consumer_compile.ENVIRONMENT_OPTION: ""}):
            with consumer_compile.consumer_compile_options(project) as selected:
                self.assertIsNone(selected)
                self.assertEqual((project / "cjpm.toml").read_bytes(), original)
            (project / "cjpm.toml").unlink()
            with consumer_compile.consumer_compile_options(project) as selected:
                self.assertIsNone(selected)
        self.assertFalse((project / "cjpm.toml").exists())

    def test_existing_override_and_other_sections_are_restored_exactly(self) -> None:
        project, original = self.project(
            b"[dependencies]\r\noverride-compile-option = \"before\"\r\n"
            b"[package] # entry\r\nname = \"dummy\"\r\n"
            b"override-compile-option = \"-O2\" # preserve this comment\r\n"
            b"[profile]\r\noverride-compile-option = \"after\"\r\n"
        )
        with patch.dict(os.environ, {consumer_compile.ENVIRONMENT_OPTION: "-O1"}):
            with contextlib.redirect_stdout(io.StringIO()):
                with consumer_compile.consumer_compile_options(project) as selected:
                    self.assertEqual(selected, "-O1")
                    document = tomllib.loads((project / "cjpm.toml").read_text())
                    self.assertEqual(document["package"]["override-compile-option"], "-O1")
                    self.assertEqual(document["dependencies"]["override-compile-option"], "before")
                    self.assertEqual(document["profile"]["override-compile-option"], "after")
        self.assertEqual((project / "cjpm.toml").read_bytes(), original)

    def test_exception_restores_the_original_bytes(self) -> None:
        project, original = self.project()
        with patch.dict(os.environ, {consumer_compile.ENVIRONMENT_OPTION: "-O1"}):
            with contextlib.redirect_stdout(io.StringIO()):
                with self.assertRaisesRegex(RuntimeError, "build failed"):
                    with consumer_compile.consumer_compile_options(project):
                        self.assertIn(b'override-compile-option = "-O1"', (project / "cjpm.toml").read_bytes())
                        raise RuntimeError("build failed")
        self.assertEqual((project / "cjpm.toml").read_bytes(), original)

    def test_cli_keeps_the_override_for_multiple_commands_and_exact_arguments(self) -> None:
        project, original = self.project()
        literal = "literal;$(printf should-never-run) `echo untouched`"
        result = self.command(project, '''import json, subprocess, sys
step = r"""import json, sys, tomllib
from pathlib import Path
document = tomllib.loads(Path('cjpm.toml').read_text())
assert document['package']['override-compile-option'] == '-O1'
assert document['dependencies']['override-compile-option'] == 'leave-me'
with Path('steps.jsonl').open('a') as output:
    output.write(json.dumps([sys.argv[1], sys.argv[2]]) + '\\n')
"""
for stage in ['check', 'build-and-run']:
    subprocess.run([sys.executable, '-c', step, stage, sys.argv[1]], check=True)
''', literal)
        self.assertEqual(result.returncode, 0, result.stderr)
        records = [json.loads(line) for line in (project / "steps.jsonl").read_text().splitlines()]
        self.assertEqual(records, [["check", literal], ["build-and-run", literal]])
        self.assertIn("entry module and all dependencies", result.stdout)
        self.assertEqual((project / "cjpm.toml").read_bytes(), original)

    def test_nonzero_command_exit_restores_manifest_and_exit_status(self) -> None:
        project, original = self.project()
        result = self.command(project, "import sys, tomllib\nfrom pathlib import Path\n"
                              "assert tomllib.loads(Path('cjpm.toml').read_text())['package']['override-compile-option'] == '-O1'\n"
                              "sys.exit(7)\n")
        self.assertEqual(result.returncode, 7, result.stderr)
        self.assertEqual((project / "cjpm.toml").read_bytes(), original)

    def test_invalid_option_cannot_run_a_command_or_modify_the_manifest(self) -> None:
        project, original = self.project()
        for option in ["-O0", "-O2", " -O1", "-O1 --unsafe"]:
            with self.subTest(option=option):
                result = self.command(project, "from pathlib import Path\nPath('executed').touch()\n", option=option)
                self.assertEqual(result.returncode, 2)
                self.assertIn(consumer_compile.ENVIRONMENT_OPTION, result.stderr)
                self.assertFalse((project / "executed").exists())
                self.assertEqual((project / "cjpm.toml").read_bytes(), original)

    def test_workspace_override_is_applied_to_the_root_without_inventing_a_package(self) -> None:
        project, original = self.project(
            b'# workspace root\r\n[workspace]\r\nmembers = ["model_adapters"]\r\n'
            b'build-members = ["model_adapters"]\r\n'
            b'[profile.build]\r\ncompile-option = "-O2"\r\n'
        )
        result = self.command(project, "import tomllib\nfrom pathlib import Path\n"
                              "document = tomllib.loads(Path('cjpm.toml').read_text())\n"
                              "assert 'package' not in document\n"
                              "assert document['workspace']['override-compile-option'] == '-O1'\n"
                              "assert document['workspace']['members'] == ['model_adapters']\n"
                              "assert document['workspace']['build-members'] == ['model_adapters']\n"
                              "assert document['profile']['build']['compile-option'] == '-O2'\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("entry workspace and all dependencies", result.stdout)
        self.assertEqual((project / "cjpm.toml").read_bytes(), original)

    def test_existing_workspace_override_is_restored_after_a_failed_command(self) -> None:
        project, original = self.project(
            b'[workspace]\nmembers = ["model_adapters"]\n'
            b'override-compile-option = "-O2" # exact restoration\n'
        )
        result = self.command(project, "import sys, tomllib\nfrom pathlib import Path\n"
                              "assert tomllib.loads(Path('cjpm.toml').read_text())['workspace']['override-compile-option'] == '-O1'\n"
                              "sys.exit(9)\n")
        self.assertEqual(result.returncode, 9, result.stderr)
        self.assertEqual((project / "cjpm.toml").read_bytes(), original)

    def test_missing_or_ambiguous_entry_tables_are_rejected_without_writing(self) -> None:
        for original in [b'[profile]\nname = "missing-entry"\n',
                         b'[package]\nname = "ambiguous"\n[workspace]\nmembers = []\n']:
            with self.subTest(manifest=original):
                project, original = self.project(original)
                result = self.command(project, "from pathlib import Path\nPath('executed').touch()\n")
                self.assertEqual(result.returncode, 2)
                self.assertIn("exactly one [package] or [workspace]", result.stderr)
                self.assertFalse((project / "executed").exists())
                self.assertEqual((project / "cjpm.toml").read_bytes(), original)


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
            "catch (error: Exception) { throw error }\n"
            "for (item in items) { use(item) }\n"
            "try { go() } catch (_: Exception) { handled() }\n"
            "for (item in items) { if (item.ok) { use(item) } }\n"
            "try { if (ready) { go() } } catch (_: Exception) { handled() }\n",
            encoding="utf-8",
        )
        # the pure for-in header (5) and the sole discard broad-catch (6) are
        # structurally unselectable and excluded; the narrow catch (4), the
        # co-located decisions in the compound for-in header (7) and the
        # discard-catch line (8), and the rest stay counted.
        self.assertEqual(
            check_patch_coverage.source_decision_lines(source, {1, 2, 3, 4, 5, 6, 7, 8}),
            {2, 3, 4, 7, 8},
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
