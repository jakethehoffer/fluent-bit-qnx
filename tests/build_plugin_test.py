# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Jake Hoffman
"""Build a standalone test that includes one QNX plugin's source.

    python3 tests/build_plugin_test.py <FBQ_BUILD> <plugin.c> <test.c> <output>

Reuses the compiler and include settings Fluent Bit's own build used for the
plugin, so the test compiles the production code exactly as shipped.
"""
import json
import pathlib
import shlex
import subprocess
import sys

root = pathlib.Path(__file__).resolve().parents[1]
build = pathlib.Path(sys.argv[1])
plugin = "/" + sys.argv[2]
test_src = root / "tests" / sys.argv[3]
output = pathlib.Path(sys.argv[4])
commands = json.loads((build / "build/compile_commands.json").read_text())
entry = next(c for c in commands if c["file"].endswith(plugin))
args = shlex.split(entry["command"])
index = args.index("-o")
args[index + 1] = str(output)
args.remove("-c")
args[args.index(entry["file"])] = str(test_src)
args += ["-ffunction-sections", "-fdata-sections", "-Wl,--gc-sections", "-lslog2parse"]
subprocess.run(args, cwd=entry["directory"], check=True)
