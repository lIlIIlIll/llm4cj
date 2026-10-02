#!/usr/bin/env python3
"""Apply an explicit, temporary compiler workaround to a consumer project.

The CJPM override affects the entry module or workspace and every dependency. It is never
applied to the core library's own default build or test commands.
"""

from __future__ import annotations

import argparse
import contextlib
import copy
import os
import re
import subprocess
import tomllib
from collections.abc import Iterator
from pathlib import Path


ENVIRONMENT_OPTION = "LLM4CJ_CONSUMER_COMPILE_OPTION"


def consumer_compile_option() -> str | None:
    option = os.environ.get(ENVIRONMENT_OPTION, "")
    if option not in ("", "-O1"):
        raise ValueError(f"{ENVIRONMENT_OPTION} must be empty or exactly -O1")
    return option or None


def _manifest_with_override(original: bytes) -> tuple[bytes, str]:
    text = original.decode("utf-8")
    parsed = tomllib.loads(text)
    entries = [name for name in ("package", "workspace") if isinstance(parsed.get(name), dict)]
    if len(entries) != 1:
        raise ValueError("consumer manifest requires exactly one [package] or [workspace] entry table")
    entry = entries[0]
    lines = text.splitlines(keepends=True)
    start = next((index for index, line in enumerate(lines) if re.fullmatch(
        rf"[ \t]*\[{entry}\][ \t]*(?:#[^\r\n]*)?(?:\r\n|\n|\r)?", line
    )), None)
    if start is None:
        raise ValueError(f"consumer manifest requires an explicit [{entry}] header")
    end = next((index for index in range(start + 1, len(lines))
                if re.match(r"[ \t]*\[", lines[index])), len(lines))
    existing = next((index for index in range(start + 1, end)
                     if re.match(r"[ \t]*override-compile-option[ \t]*=", lines[index])), None)
    newline = "\r\n" if lines[start].endswith("\r\n") else "\n"
    override = 'override-compile-option = "-O1"' + newline
    if existing is None:
        if not lines[start].endswith(("\n", "\r")):
            lines[start] += newline
        lines.insert(start + 1, override)
    else:
        lines[existing] = override
    changed = "".join(lines)
    expected = copy.deepcopy(parsed)
    expected[entry]["override-compile-option"] = "-O1"
    # Validate the edit before writing. Unusual multiline values or quoted
    # table/key layouts fail closed instead of changing a different section.
    if tomllib.loads(changed) != expected:
        raise ValueError("cannot safely replace the consumer compile option")
    return changed.encode("utf-8"), entry


@contextlib.contextmanager
def consumer_compile_options(project: Path) -> Iterator[str | None]:
    option = consumer_compile_option()
    if option is None:
        yield None
        return
    manifest = project / "cjpm.toml"
    original = manifest.read_bytes()
    changed, entry = _manifest_with_override(original)
    try:
        manifest.write_bytes(changed)
        scope = "workspace" if entry == "workspace" else "module"
        print(f"consumer compile workaround: -O1 applies to the entry {scope} and "
              "all dependencies; the original manifest is restored on exit", flush=True)
        yield option
    finally:
        manifest.write_bytes(original)


def main(arguments: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("project", type=Path)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    options = parser.parse_args(arguments)
    if not options.command:
        parser.error("a command and its arguments are required")
    try:
        with consumer_compile_options(options.project):
            return subprocess.run(options.command, cwd=options.project, check=False).returncode
    except ValueError as error:
        parser.error(str(error))
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
