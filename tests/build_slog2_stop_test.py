# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Jake Hoffman
"""Reuse the real plugin's compiler/include settings for the lifecycle test."""
import json
import pathlib
import shlex
import subprocess
import sys

root = pathlib.Path(__file__).resolve().parents[1]
build = pathlib.Path(sys.argv[1])
commands = json.loads((build / "build/compile_commands.json").read_text())
entry = next(c for c in commands if c["file"].endswith("/in_slog2.c"))
args = shlex.split(entry["command"])
output = pathlib.Path(sys.argv[2]) if len(sys.argv) > 2 else build / "bin/slog2_stop_lifecycle"
index = args.index("-o")
args[index + 1] = str(output)
args.remove("-c")
args[args.index(entry["file"])] = str(root / "tests/slog2_stop_lifecycle.c")
args += ["-ffunction-sections", "-fdata-sections", "-Wl,--gc-sections", "-lslog2parse"]
subprocess.run(args, cwd=entry["directory"], check=True)
