#!/usr/bin/env python3
"""Build/run the Linux example in disposable storage with a matching stdx."""

from __future__ import annotations

import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / "examples/codex_subscription"


def main() -> int:
    if sys.platform != "linux":
        raise SystemExit("The Codex subscription example currently requires Linux.")
    stdx = os.environ.get("CANGJIE_STDX_PATH")
    if not stdx or not Path(stdx).is_dir():
        raise SystemExit("Set CANGJIE_STDX_PATH to the installed stdx matching your Cangjie SDK.")
    version = subprocess.run(["cjc", "-v"], check=True, text=True, capture_output=True)
    target = re.search(r"Target:\s*(\S+)", version.stdout + version.stderr)
    if not target:
        raise SystemExit("Could not determine the Cangjie target.")
    parent = Path(os.environ.get("TMPDIR", str(Path.home() / ".cache/agent-tmp")))
    if parent.exists():
        filesystem = subprocess.run(["stat", "-f", "-c", "%T", str(parent)], check=True, text=True, capture_output=True).stdout.strip()
        if filesystem == "tmpfs":
            parent = Path.home() / ".cache/agent-tmp"
    parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="llm4cj-codex-example-", dir=parent) as raw:
        package = Path(raw)
        shutil.copytree(SOURCE / "src", package / "src")
        manifest = (SOURCE / "cjpm.toml").read_text()
        # Paths are generated only in disposable storage, never in tracked files.
        def toml_string(value: str) -> str:
            return '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'
        manifest = manifest.replace('path = "../.."', "path = " + toml_string(str(ROOT)))
        manifest += f"\n[target.{target.group(1)}.bin-dependencies]\npath-option = [{toml_string(stdx)}]\n"
        (package / "cjpm.toml").write_text(manifest)
        env = dict(os.environ, TMPDIR=raw, TMP=raw, TEMP=raw)
        subprocess.run(["cjpm", "build"], cwd=package, env=env, check=True)
        if sys.argv[1:] == ["--check"]:
            subprocess.run([str(package / "target/release/bin/main"), "--help"], env=env, check=True)
            subprocess.run(["cjpm", "test", "--no-progress"], cwd=package, env=env, check=True)
            return 0
        return subprocess.run([str(package / "target/release/bin/main"), *sys.argv[1:]], env=env).returncode


if __name__ == "__main__":
    raise SystemExit(main())
