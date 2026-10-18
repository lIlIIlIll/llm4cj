#!/usr/bin/env python3
"""Regression tests for repository quality gates."""

from __future__ import annotations

import contextlib
import hashlib
import io
import json
import os
import subprocess
import sys
import tempfile
import tomllib
import unittest
from decimal import Decimal
from pathlib import Path
from unittest.mock import patch

import check_api_compat
import check_contract
import check_fixtures
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


class ApiShapeTests(unittest.TestCase):
    def test_explicit_snapshot_writer_changes_only_readable_shape_and_digest(self) -> None:
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        root = Path(temporary.name)
        (root / "contract").mkdir()
        sentinel = root / "contract/public-api.txt"
        sentinel.write_bytes(b"untouched inventory\n")
        source = "public enum Result<T> { Ok(T) | Err(String); public func isOk(): Bool { true } }"
        with patch.object(check_contract, "ROOT", root), patch.object(check_contract, "source", source):
            with contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(check_contract.main(["--write-api-shape"]), 0)
        actual = (root / "contract/public-api-shape.txt").read_text()
        self.assertEqual(actual, "\n".join(check_contract.public_api_shape(source)) + "\n")
        self.assertEqual((root / "contract/public-api-shape.sha256").read_text(),
                         hashlib.sha256(actual.encode()).hexdigest() + "\n")
        self.assertEqual(sentinel.read_bytes(), b"untouched inventory\n")
        self.assertEqual({path.name for path in (root / "contract").iterdir()},
                         {"public-api.txt", "public-api-shape.txt", "public-api-shape.sha256"})

    def test_real_enum_method_signature_changes_are_observable(self) -> None:
        original = check_contract.source
        signature = "public func isOk(): Bool"
        self.assertEqual(original.count(signature), 1)
        before = check_api_compat.shape_digest(original)
        for replacement in ["public func renamedIsOk(): Bool",
                            "public func isOk(required: Bool): Bool",
                            "public func isOk(): String"]:
            with self.subTest(replacement=replacement):
                self.assertNotEqual(before, check_api_compat.shape_digest(original.replace(signature, replacement)))
        self.assertEqual(before, check_api_compat.shape_digest(original.replace(
            "public func isOk(): Bool {", "public func isOk(): Bool { /* implementation only */")))

    def test_enum_cases_and_complete_public_member_signatures_are_captured(self) -> None:
        source = '''@Derive[Equatable]
public enum Result<T> {
    Ok(T) | Err(String)
    private let hidden: Int64 = 1
    public static func convert<U>(value: U, named!: String = "a { // b", required!: Bool): Result<U>
        where U <: Equatable<U> { Result<U>.Ok(value) }
    public operator func ==(other: Result<T>): Bool { true }
    public prop value: T { get() { lookup() } set(value) { store(value) } }
}
'''
        shape = check_contract.public_api_shape(source)
        self.assertIn("Result cases Ok ( T ) | Err ( String )", shape)
        self.assertTrue(any("public static func convert < U >" in line and
                            "named ! : String =" in line and "where U < : Equatable < U >" in line
                            for line in shape))
        self.assertTrue(any("public operator func = =" in line for line in shape))
        self.assertTrue(any("accessors get ( ) ; set ( value )" in line for line in shape))
        self.assertFalse(any("hidden" in line for line in shape))
        for old, new in [("Ok(T)", "Ok(Int64)"), ("convert<U>", "convert<V>"),
                         ("value: U", "item: U"), ("named!:", "named:"),
                         ('"a { // b"', '"other"'), ("required!: Bool", "required!: Int64"),
                         ("Result<U>\n", "Result<T>\n"), ("public static func", "public func"),
                         ("func ==", "func !="), ("set(value) { store(value) }", "")]:
            with self.subTest(change=(old, new)):
                self.assertNotEqual(shape, check_contract.public_api_shape(source.replace(old, new)))

    def test_comments_bodies_whitespace_and_nested_defaults_are_handled_lexically(self) -> None:
        source = '''public open class Box<T> {
    public init(make!: () -> T = { => create("}") }) { initialize() }
    public func map<U>(value: U,
        text!: String = ##"{ /* raw */ \\\" }"##,
        lines!: String = """a { //\nb }""",
        transform!: (U) -> U = { item => if (ready) { item } else { item } }
    ): U where U <: Equatable<U> { return transform(value) }
    public prop value: T { get() { lookup() } }
}
'''
        shape = check_contract.public_api_shape(source)
        changed = source.replace("public open", "public /* one /* nested */ end */ open")
        changed = changed.replace("return transform(value)", 'let ignored = "} //"; transform(value)')
        changed = changed.replace("lookup()", 'if (true) { lookup("{") } else { lookup() }')
        changed = changed.replace("value: U,", "value : /* parameter */ U ,")
        self.assertEqual(shape, check_contract.public_api_shape(changed))
        self.assertTrue(all("\n" not in line for line in shape))
        self.assertNotEqual(shape, check_contract.public_api_shape(source.replace("a { //", "a  { //")))

    def test_interface_signatures_and_same_line_members_exclude_default_bodies(self) -> None:
        source = '''public interface Resolver<T> {
    func resolve<U>(value: U): T where U <: Equatable<U>
    prop name: String; public func ready(): Bool { true }
}
public struct Value { public let count: Int64 = 1; public func size(): Int64 { count } }
public func factory<T>(value: T): Value { Value() }
'''
        shape = check_contract.public_api_shape(source)
        self.assertIn("Resolver member prop name : String", shape)
        self.assertIn("Resolver member public func ready ( ) : Bool", shape)
        self.assertIn("Value member public let count : Int64", shape)
        self.assertTrue(any(line.startswith("public func factory < T >") for line in shape))
        self.assertEqual(shape, check_contract.public_api_shape(source.replace("{ true }", "{ false }")))

    def test_malformed_lexical_input_fails_closed(self) -> None:
        for source in ['public enum E { A /*', 'public enum E { A("unterminated) }',
                       "public class C { public func f(value: Int64] {} }"]:
            with self.subTest(source=source), self.assertRaises(SystemExit):
                check_contract.public_api_shape(source)


class ApiCompatibilityTests(unittest.TestCase):
    @staticmethod
    def git(root: Path, *arguments: str) -> str:
        return subprocess.run(
            ["git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid",
             "-c", "commit.gpgsign=false", "-c", "tag.gpgsign=false",
             "-c", "core.hooksPath=/dev/null", *arguments],
            cwd=root, check=True, text=True, capture_output=True,
        ).stdout.strip()

    def repository(self, version: str = "0.2.0") -> Path:
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        root = Path(temporary.name)
        self.git(root, "init", "-q")
        (root / "src").mkdir()
        self.write_candidate(root, version, removed=False)
        self.commit(root, "baseline")
        return root

    @staticmethod
    def write_candidate(root: Path, version: str, *, removed: bool) -> None:
        (root / "cjpm.toml").write_text('[package]\nname = "probe"\nversion = "' + version + '"\n')
        (root / "src/api.cj").write_text(
            "package probe\npublic func retained(): Int64 { 1 }\n" +
            ("" if removed else "public func removed(): Int64 { 2 }\n"))

    def commit(self, root: Path, message: str) -> str:
        self.git(root, "add", ".")
        self.git(root, "commit", "-qm", message)
        return self.git(root, "rev-parse", "HEAD")

    def tag(self, root: Path, name: str, *, annotated: bool = False) -> None:
        self.git(root, "tag", *(["-a", "-m", "release"] if annotated else []), name)

    def report(self, root: Path, error: str | None = None) -> dict[str, object]:
        output = root / "report.json"
        with patch.object(check_api_compat, "ROOT", root), contextlib.redirect_stdout(io.StringIO()):
            if error:
                with self.assertRaisesRegex(SystemExit, error):
                    check_api_compat.main(["--output", str(output)])
            else:
                self.assertEqual(check_api_compat.main(["--output", str(output)]), 0)
        report = json.loads(output.read_text())
        for field in ["baselineCommit", "candidateCommit", "candidateTag", "candidateSourceDirty"]:
            self.assertIn(field, report)
        self.assertEqual(report["candidateCommit"], self.git(root, "rev-parse", "HEAD"))
        return report

    def test_breaking_patch_fails_before_and_after_lightweight_or_annotated_candidate_tag(self) -> None:
        for annotated in [False, True]:
            with self.subTest(annotated=annotated):
                root = self.repository()
                baseline = self.git(root, "rev-parse", "HEAD")
                self.tag(root, "v0.2.0", annotated=not annotated)
                self.write_candidate(root, "0.2.1", removed=True)
                candidate = self.commit(root, "breaking patch")
                before = self.report(root, "without a breaking semver bump")
                self.tag(root, "v0.2.1", annotated=annotated)
                after = self.report(root, "without a breaking semver bump")
                for report in [before, after]:
                    self.assertEqual(report["baselineTag"], "v0.2.0")
                    self.assertEqual(report["baselineCommit"], baseline)
                    self.assertEqual(report["candidateCommit"], candidate)
                    self.assertFalse(report["candidateSourceDirty"])
                    self.assertTrue(report["shapeChanged"])
                    self.assertFalse(report["semverPermitsChange"])
                self.assertIsNone(before["candidateTag"])
                self.assertEqual(after["candidateTag"], "v0.2.1")

    def test_dirty_same_version_compares_published_head_tag(self) -> None:
        root = self.repository()
        self.tag(root, "v0.2.0")
        self.write_candidate(root, "0.2.0", removed=True)
        report = self.report(root, "without a breaking semver bump")
        self.assertEqual(report["baselineTag"], "v0.2.0")
        self.assertEqual(report["baselineCommit"], report["candidateCommit"])
        self.assertTrue(report["candidateSourceDirty"])

    def test_breaking_minor_and_major_bumps_are_allowed(self) -> None:
        for previous, candidate in [("0.2.0", "0.3.0"), ("1.2.0", "2.0.0")]:
            with self.subTest(previous=previous, candidate=candidate):
                root = self.repository(previous)
                self.tag(root, "v" + previous)
                self.write_candidate(root, candidate, removed=True)
                self.commit(root, "breaking version")
                self.tag(root, "v" + candidate, annotated=True)
                report = self.report(root)
                self.assertEqual(report["baselineTag"], "v" + previous)
                self.assertTrue(report["shapeChanged"])
                self.assertTrue(report["semverPermitsChange"])

    def test_no_api_patch_allows_body_changes_and_ignores_prerelease_or_noncanonical_tags(self) -> None:
        root = self.repository()
        self.tag(root, "v0.2.0")
        self.write_candidate(root, "0.2.1", removed=False)
        path = root / "src/api.cj"
        path.write_text(path.read_text().replace("{ 1 }", "{ /* body only */ 3 }"))
        self.commit(root, "patch implementation")
        for name in ["v9.0.0-rc.1", "v9.0.0+build", "v09.0.0", "other-release"]:
            self.tag(root, name)
        report = self.report(root)
        self.assertEqual(report["baselineTag"], "v0.2.0")
        self.assertIsNone(report["candidateTag"])
        self.assertFalse(report["shapeChanged"])
        self.tag(root, "v0.2.1")
        self.assertEqual(self.report(root)["baselineTag"], "v0.2.0")

    def test_only_effective_production_and_manifest_changes_make_candidate_dirty(self) -> None:
        root = self.repository()
        self.tag(root, "v0.2.0")
        self.write_candidate(root, "0.2.1", removed=False)
        self.commit(root, "candidate")
        self.tag(root, "v0.2.1")
        (root / "src/api_test.cj").write_text("test only")
        (root / "src/experimental").mkdir()
        (root / "src/experimental/api.cj").write_text("experimental only")
        self.assertFalse(self.report(root)["candidateSourceDirty"])
        addition = root / "src/new.cj"
        addition.write_text("package probe\nfunc privateHelper(): Unit {}\n")
        report = self.report(root)
        self.assertTrue(report["candidateSourceDirty"])
        self.assertEqual(report["baselineTag"], "v0.2.1")
        addition.unlink()
        (root / "cjpm.toml").write_text((root / "cjpm.toml").read_text() + "# changed\n")
        self.assertTrue(self.report(root)["candidateSourceDirty"])
        self.write_candidate(root, "0.2.1", removed=False)
        source = root / "src/api.cj"
        source.write_bytes(source.read_bytes().replace(b"\n", b"\r\n"))
        self.assertTrue(self.report(root)["candidateSourceDirty"])
        (root / "src/api.cj").unlink()
        self.assertTrue(self.report(root, "without a breaking semver bump")["candidateSourceDirty"])

    def test_no_previous_stable_baseline_fails_and_writes_provenance(self) -> None:
        root = self.repository()
        report = self.report(root, "requires a previous stable release tag")
        self.assertIsNone(report["baselineCommit"])
        self.assertFalse(report["candidateSourceDirty"])
        self.tag(root, "v0.2.0", annotated=True)
        report = self.report(root, "requires a previous stable release tag")
        self.assertEqual(report["candidateTag"], "v0.2.0")
        self.assertIsNone(report["baselineTag"])

    def test_highest_numeric_stable_tag_is_used_and_manifest_mismatch_fails(self) -> None:
        root = self.repository("0.9.0")
        self.tag(root, "v0.9.0")
        self.write_candidate(root, "0.10.0", removed=False)
        self.commit(root, "release")
        self.tag(root, "v0.10.0")
        self.write_candidate(root, "0.10.1", removed=False)
        self.commit(root, "candidate")
        self.assertEqual(self.report(root)["baselineTag"], "v0.10.0")
        self.tag(root, "v0.11.0")
        self.write_candidate(root, "0.12.0", removed=False)
        self.commit(root, "later candidate")
        report = self.report(root, "does not match package version")
        self.assertEqual(report["baselineTag"], "v0.11.0")
        self.assertIsNotNone(report["baselineCommit"])

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


class FixtureOracleTests(unittest.TestCase):
    @staticmethod
    def source() -> dict:
        return {
            "url": "https://developers.openai.com/api/reference/responses/create",
            "checked_at": "2026-01-01",
            "revision": "validator-fixture-v1",
            "kind": "schema_derived",
            "notes": "Synthetic provenance record for validator tests.",
        }

    def manifest(self) -> tuple[Path, dict]:
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        root = Path(temporary.name)
        fixtures = root / "fixtures"
        fixtures.mkdir()
        manifest = {
            "version": 1,
            "live_provider": "not_run",
            "dialects": [
                {"id": dialect, "probe": probe,
                 "protocol": "responses" if ".responses." in dialect else
                             "chat_completions" if ".chat." in dialect else "messages"}
                for dialect, probe in check_fixtures.DIALECTS.items()
            ],
            "cases": [],
            "requests": [f"requests/{probe}.json" for probe in check_fixtures.DIALECTS.values()],
            "transcripts": ["transcripts/openai-responses.json", "transcripts/anthropic-messages.json",
                            "transcripts/kimi-chat.json"],
        }
        scenarios = ["text", "tool", "refusal", "usage", "provider-failure", "truncated",
                     "continuation", "phase", "reasoning", "native-replay", "logprobs"]
        for dialect, probe in check_fixtures.DIALECTS.items():
            case = {
                "id": probe, "dialect": dialect, "probe": probe, "scenario": scenarios[:],
                "source": self.source(), "pair": False,
                "expected": f"expected/{probe}.json", "wire": {"fixed": f"responses/{probe}.json"},
            }
            manifest["cases"].append(case)
            for relative, value in [(case["expected"], {"canonical": {}}),
                                    (case["wire"]["fixed"], {"response": {}})]:
                path = fixtures / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(json.dumps(value))
        for relative in manifest["requests"] + manifest["transcripts"]:
            path = fixtures / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("{}\n")
        self.write_manifest(fixtures, manifest)
        for name, value in [("FIXTURES", fixtures), ("MANIFEST", fixtures / "manifest.json")]:
            patcher = patch.object(check_fixtures, name, value)
            patcher.start()
            self.addCleanup(patcher.stop)
        return fixtures, manifest

    @staticmethod
    def write_manifest(fixtures: Path, manifest: dict) -> None:
        (fixtures / "manifest.json").write_text(json.dumps(manifest), encoding="utf-8")

    def test_oracle_rejects_type_coercion_missing_fields_and_reordered_blocks(self) -> None:
        for actual, expected in [(True, 1), (False, 0), (None, 0), ({}, {"value": None}),
                                 ({"usage": {}}, {"usage": {"outputTokens": 0}}),
                                 ({"blocks": [{"kind": "text", "text": "answer"}]},
                                  {"blocks": [{"kind": "text", "text": "answer", "phase": "final"}]}),
                                 ([{"kind": "text"}, {"kind": "tool"}],
                                  [{"kind": "tool"}, {"kind": "text"}])]:
            with self.subTest(actual=actual, expected=expected), self.assertRaises(AssertionError):
                check_fixtures.assert_equal(actual, expected, "oracle")
        check_fixtures.assert_equal({"text": "answer", "usage": 1},
                                    {"usage": Decimal("1.0"), "text": "answer"}, "oracle")

    def test_oracle_compares_exact_numeric_and_logprob_values_without_float_rounding(self) -> None:
        for actual, expected in [("9007199254740992", "9007199254740993"),
                                 ("0.123456789012345678901", "0.123456789012345678902"),
                                 ("-1e-1000", "-2e-1000")]:
            with self.subTest(actual=actual), self.assertRaises(AssertionError):
                check_fixtures.assert_equal(check_fixtures.parse_json(actual),
                                            check_fixtures.parse_json(expected), "oracle.logprob")
        text = '{"logprobs":[{"token":"x","logprob":-0.123456789012345678901,"top":[1e-1000]}]}'
        value = check_fixtures.parse_json(text)
        encoded = check_fixtures.dump_json(value)
        self.assertIn("-0.123456789012345678901", encoded)
        check_fixtures.assert_equal(check_fixtures.parse_json(encoded), value, "oracle")
        self.assertIsInstance(value["logprobs"][0]["logprob"], Decimal)

    def test_oracle_json_rejects_duplicate_keys_non_json_numbers_and_python_floats(self) -> None:
        for text in ['{"value":1,"value":2}', "NaN", "Infinity", "-Infinity"]:
            with self.subTest(text=text), self.assertRaises(ValueError):
                check_fixtures.parse_json(text)
        for value in [0.1, {"logprob": 0.1}, {1, 2}]:
            with self.subTest(value=value), self.assertRaises(ValueError):
                check_fixtures.dump_json(value)

    def test_source_validation_requires_primary_revision_kind_and_authorized_capture(self) -> None:
        for change in [{"url": "http://developers.openai.com/api"},
                       {"url": "https://example.test/protocol"},
                       {"url": "https://user@developers.openai.com/api"},
                       {"checked_at": "2026-02-30"}, {"revision": ""}, {"notes": ""},
                       {"kind": "unattributed"}, {"kind": "authorized_capture"}]:
            source = self.source() | change
            with self.subTest(change=change), self.assertRaises(ValueError):
                check_fixtures.validate_source(source, "synthetic")
        capture = self.source() | {
            "kind": "authorized_capture", "authorization": "Fixture owner approved this synthetic capture.",
            "captured_at": "2026-01-01", "sanitization": "No credentials or identifying data.",
        }
        check_fixtures.validate_source(capture, "synthetic")
        for field in ["authorization", "captured_at", "sanitization"]:
            with self.subTest(field=field), self.assertRaises(ValueError):
                check_fixtures.validate_source(capture | {field: ""}, "synthetic")

    def test_manifest_inventory_is_exact_and_does_not_adopt_unlisted_files(self) -> None:
        fixtures, manifest = self.manifest()
        validated = check_fixtures.validate_manifest()
        expected = {"manifest.json", *manifest["requests"], *manifest["transcripts"]}
        for case in manifest["cases"]:
            expected.add(case["expected"])
            expected.update(case["wire"].values())
        (fixtures / "unlisted.json").write_text("{}\n")
        inventory = check_fixtures.fixture_inventory(validated)
        self.assertEqual([path.relative_to(fixtures).as_posix() for path in inventory], sorted(expected))
        self.assertEqual(len(inventory), len(expected))

    def test_manifest_rejects_changed_evidence_boundary_and_incomplete_dialect_set(self) -> None:
        fixtures, manifest = self.manifest()
        for change in [{"version": 2}, {"live_provider": "verified"},
                       {"dialects": manifest["dialects"][:-1]},
                       {"dialects": manifest["dialects"] + manifest["dialects"][:1]}]:
            self.write_manifest(fixtures, manifest | change)
            with self.subTest(change=change), self.assertRaises(ValueError):
                check_fixtures.validate_manifest()

    def test_manifest_requires_continuation_and_logprob_semantic_coverage(self) -> None:
        fixtures, manifest = self.manifest()
        for dialect, scenario in [("openai.responses.v1", "continuation"),
                                  ("openai.responses.v1", "phase"),
                                  ("openai.chat.v1", "logprobs"),
                                  ("kimi.chat.v1", "native-replay")]:
            modified = json.loads(json.dumps(manifest))
            case = next(case for case in modified["cases"] if case["dialect"] == dialect)
            case["scenario"].remove(scenario)
            self.write_manifest(fixtures, modified)
            with self.subTest(dialect=dialect, scenario=scenario), self.assertRaisesRegex(ValueError, "missing semantic coverage"):
                check_fixtures.validate_manifest()

    def test_manifest_rejects_incorrect_protocol_pair_policy_and_cancel_flags(self) -> None:
        fixtures, manifest = self.manifest()
        modified = json.loads(json.dumps(manifest))
        modified["dialects"][0]["protocol"] = "messages"
        self.write_manifest(fixtures, modified)
        with self.assertRaisesRegex(ValueError, "dialect and protocol disagree"):
            check_fixtures.validate_manifest()
        for case_change in [{"pair": "unknown"}, {"pair": 1},
                            {"wire": manifest["cases"][0]["wire"] | {"cancel": True}},
                            {"wire": {"stream": manifest["cases"][0]["wire"]["fixed"], "cancel": 1}}]:
            modified = json.loads(json.dumps(manifest))
            modified["cases"][0].update(case_change)
            self.write_manifest(fixtures, modified)
            with self.subTest(change=case_change), self.assertRaises(ValueError):
                check_fixtures.validate_manifest()

    def test_manifest_rejects_duplicate_scenarios_missing_provenance_or_missing_mode_oracle(self) -> None:
        fixtures, manifest = self.manifest()
        mutations = [lambda value: value["cases"].append(value["cases"][0]),
                     lambda value: value["cases"][0].update(source={}),
                     lambda value: value["cases"][0].update(probe="wrong-codec"),
                     lambda value: value["cases"][0].update(pair=True)]
        for mutate in mutations:
            modified = json.loads(json.dumps(manifest))
            mutate(modified)
            self.write_manifest(fixtures, modified)
            with self.subTest(mutation=mutations.index(mutate)), self.assertRaises(ValueError):
                check_fixtures.validate_manifest()
        self.write_manifest(fixtures, manifest)
        (fixtures / manifest["cases"][0]["expected"]).write_text('{"stream":{}}')
        with self.assertRaisesRegex(ValueError, "missing independent fixed oracle"):
            check_fixtures.validate_manifest()

    def test_manifest_rejects_missing_request_transcript_and_referenced_files(self) -> None:
        fixtures, manifest = self.manifest()
        for change in [{"requests": manifest["requests"][:-1]},
                       {"transcripts": manifest["transcripts"][:-1]},
                       {"requests": manifest["requests"] + manifest["requests"][:1]},
                       {"transcripts": manifest["transcripts"] + manifest["transcripts"][:1]}]:
            self.write_manifest(fixtures, manifest | change)
            with self.subTest(change=change), self.assertRaises(ValueError):
                check_fixtures.validate_manifest()
        self.write_manifest(fixtures, manifest)
        (fixtures / manifest["cases"][0]["wire"]["fixed"]).unlink()
        with self.assertRaisesRegex(ValueError, "invalid fixture reference"):
            check_fixtures.validate_manifest()

    def test_cache_public_check_joins_inventory_and_keeps_registration_validation(self) -> None:
        fixtures, manifest = self.manifest()
        (fixtures / "cache.json").write_text("{}\n")
        entry = {"id": "cache-breakpoints", "command": "check-cache",
                 "fixture": "cache.json", "source": self.source()}
        manifest["public_checks"] = [entry]
        self.write_manifest(fixtures, manifest)
        validated = check_fixtures.validate_manifest()
        self.assertIn(fixtures / "cache.json", check_fixtures.fixture_inventory(validated))
        for change in [{"command": "run-arbitrary-script"},
                       {"source": self.source() | {"url": "https://example.test/not-primary"}}]:
            modified = manifest | {"public_checks": [entry | change]}
            self.write_manifest(fixtures, modified)
            with self.subTest(change=change), self.assertRaises(ValueError):
                check_fixtures.validate_manifest()

    def test_public_checks_use_fixed_feature_runners_and_reject_unknown_dispatch(self) -> None:
        fixtures, manifest = self.manifest()
        checks = []
        for command, name in [("check-cache", "cache"), ("check-audio", "audio"), ("check-schema", "schema"),
                              ("check-structured", "structured"), ("check-transcript-branches", "branches"),
                              ("check-capabilities", "capabilities")]:
            (fixtures / f"{name}.json").write_text("{}\n")
            checks.append({"command": command, "fixture": f"{name}.json"})
        executable = fixtures.parent / "public-probe"
        with patch.object(check_fixtures.subprocess, "run") as run:
            self.assertEqual(check_fixtures.verify_public_checks(executable, {"public_checks": checks}), 6)
            arguments = [call.args[0] for call in run.call_args_list]
            self.assertIn([sys.executable, str(check_fixtures.ROOT / "scripts/check_cache_fixtures.py"),
                           "--probe", str(executable), "--fixture", str(fixtures / "cache.json")], arguments)
            self.assertIn([sys.executable, str(check_fixtures.ROOT / "support/provider_probe/check_audio.py"),
                           str(executable), str(fixtures / "audio.json")], arguments)
            self.assertIn([str(executable), "check-schema", str(fixtures / "schema.json")], arguments)
            self.assertIn([str(executable), "check-structured", str(fixtures / "structured.json")], arguments)
            self.assertIn([str(executable), "check-capabilities", str(fixtures / "capabilities.json")], arguments)
            self.assertIn([sys.executable, str(check_fixtures.ROOT / "scripts/check_transcript_branch_fixtures.py"),
                           "--probe", str(executable), "--fixture", str(fixtures / "branches.json")], arguments)
            run.reset_mock()
            with self.assertRaisesRegex(ValueError, "unknown public fixture check command"):
                check_fixtures.verify_public_checks(executable, {"public_checks": [
                    {"command": "run-arbitrary-script", "fixture": "cache.json"}]})
            run.assert_not_called()

    def test_inventory_rejects_path_traversal_absolute_paths_and_escaping_symlinks(self) -> None:
        fixtures, manifest = self.manifest()
        outside = fixtures.parent / "outside.json"
        outside.write_text("{}\n")
        (fixtures / "escape.json").symlink_to(outside)
        for relative in ["../outside.json", str(outside), "escape.json", "missing.json"]:
            modified = json.loads(json.dumps(manifest))
            modified["cases"][0]["expected"] = relative
            with self.subTest(relative=relative), self.assertRaises(ValueError):
                check_fixtures.fixture_inventory(modified)


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
