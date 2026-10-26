#!/usr/bin/env python3
"""Run the real-module CCB ModCheck multinode tests on an embedded Lua 5.1.

The project ships lupa 2.8 in an isolated dir (build/test_runtime) so the
tests exercise CCBModCheckProtocol.lua / CCBModCheckController.lua under the
same Lua version as Civ6 (5.1), not a mirror implementation.
"""
from __future__ import annotations

import os
import pathlib
import sys
import traceback


ROOT = pathlib.Path(__file__).resolve().parents[2]


def main() -> int:
    runtime = ROOT / "build" / "test_runtime"
    if runtime.is_dir():
        sys.path.insert(0, str(runtime))

    try:
        from lupa.lua51 import LuaRuntime
        runtime_name = "lupa.lua51"
    except ImportError:
        from lupa import LuaRuntime  # type: ignore
        runtime_name = "lupa (default)"

    os.environ["CCB_TOOLKITS_ROOT"] = str(ROOT)

    lua = LuaRuntime(unpack_returned_tuples=True)
    print(f"runtime: {runtime_name}; {lua.eval('_VERSION')}")

    test_lua = ROOT / "tests" / "modcheck" / "test_multinode.lua"
    source = test_lua.read_text(encoding="utf-8")
    try:
        lua.execute(source)
    except Exception:
        traceback.print_exc()
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
