#!/usr/bin/env python3
"""Regression: terminal views should be portal-hosted near the window root.

This catches regressions where terminal NSViews are reattached deep inside the SwiftUI
hierarchy, which increases Core Animation commit traversal depth and input latency.
"""

import os
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from zmux import zmux, zmuxError


SOCKET_PATH = os.environ.get("ZMUX_SOCKET", "/tmp/zmux-debug.sock")


def main() -> int:
    with zmux(SOCKET_PATH) as c:
        c.activate_app()

        c.new_workspace()
        time.sleep(0.2)
        c.new_split("right")
        time.sleep(0.8)

        health = c.surface_health()
        terminals = [row for row in health if row.get("type") == "terminal"]
        if len(terminals) < 2:
            raise zmuxError(f"expected >=2 terminal surfaces after split, got={terminals}")

        for row in terminals:
            if not row.get("in_window", False):
                raise zmuxError(f"terminal not attached to window: {row}")
            if row.get("portal") is not True:
                raise zmuxError(f"terminal is not portal-hosted: {row}")
            depth = row.get("view_depth")
            if not isinstance(depth, int):
                raise zmuxError(f"missing view_depth in surface_health: {row}")
            if depth > 8:
                raise zmuxError(f"terminal view depth too deep ({depth}): {row}")

        print("PASS: terminal surfaces are portal-hosted with shallow view depth")
        return 0


if __name__ == "__main__":
    raise SystemExit(main())
