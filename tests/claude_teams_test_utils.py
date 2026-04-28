#!/usr/bin/env python3

from __future__ import annotations

import os
from pathlib import Path


def resolve_zmux_cli() -> str:
    explicit = os.environ.get("ZMUX_CLI_BIN") or os.environ.get("ZMUX_CLI")
    if explicit and os.path.exists(explicit) and os.access(explicit, os.X_OK):
        return explicit

    recorded_path = Path("/tmp/zmux-last-cli-path")
    if recorded_path.exists():
        candidate = recorded_path.read_text(encoding="utf-8").strip()
        if candidate and os.path.exists(candidate) and os.access(candidate, os.X_OK):
            return candidate

    raise RuntimeError(
        "Unable to find zmux CLI binary. Set ZMUX_CLI_BIN or run ./scripts/reload.sh --tag <tag> first."
    )
