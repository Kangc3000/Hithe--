#!/usr/bin/env python3
"""hithe — Vision Companion (解語) global activate/deactivate control.

Manipulates a single state flag at ~/.hermes/voice-companion/state/active.flag.
The voice-id and face-id daemons check this flag before emitting recognition
events. When the flag is absent, daemons keep their models loaded and continue
capturing audio/video, but discard everything (no events, no TTS, no compute
on the hot path) — so re-activation is near-instant.

Pure standard library; safe to run with the system Python (no venv needed).

Usage:
  hithe on                # activate (creates the flag)
  hithe off               # deactivate (removes the flag)
  hithe toggle            # flip current state
  hithe status            # print "active" or "paused" plus how long
"""
from __future__ import annotations

import argparse
import sys
import time
from pathlib import Path
from typing import Sequence

DEFAULT_STATE_DIR = Path("~/.hermes/voice-companion/state").expanduser()
FLAG_NAME = "active.flag"


def _flag_path(state_dir: Path) -> Path:
    return state_dir / FLAG_NAME


def is_active(state_dir: Path = DEFAULT_STATE_DIR) -> bool:
    return _flag_path(state_dir).exists()


def _format_elapsed(seconds: float) -> str:
    seconds = int(max(0, seconds))
    if seconds < 60:
        return f"{seconds}s"
    if seconds < 3600:
        return f"{seconds // 60}m {seconds % 60}s"
    return f"{seconds // 3600}h {(seconds % 3600) // 60}m"


def _activate(state_dir: Path) -> str:
    state_dir.mkdir(parents=True, exist_ok=True)
    flag = _flag_path(state_dir)
    if flag.exists():
        return "already active"
    flag.touch()
    return "activated"


def _deactivate(state_dir: Path) -> str:
    flag = _flag_path(state_dir)
    if not flag.exists():
        return "already paused"
    flag.unlink()
    return "deactivated"


def _status(state_dir: Path) -> str:
    flag = _flag_path(state_dir)
    if not flag.exists():
        return "paused"
    elapsed = time.time() - flag.stat().st_mtime
    return f"active (since {_format_elapsed(elapsed)} ago)"


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Vision Companion (解語) global on/off control."
    )
    parser.add_argument(
        "action",
        choices=["on", "off", "status", "toggle"],
        help="on=activate, off=deactivate, toggle=flip, status=show",
    )
    parser.add_argument(
        "--state-dir",
        type=Path,
        default=DEFAULT_STATE_DIR,
        help=f"State directory (default {DEFAULT_STATE_DIR})",
    )
    args = parser.parse_args(argv)

    state_dir: Path = args.state_dir

    if args.action == "status":
        print(_status(state_dir))
        return 0

    if args.action == "toggle":
        if is_active(state_dir):
            print(_deactivate(state_dir))
        else:
            print(_activate(state_dir))
        return 0

    if args.action == "on":
        print(_activate(state_dir))
        return 0

    if args.action == "off":
        print(_deactivate(state_dir))
        return 0

    return 2


if __name__ == "__main__":
    sys.exit(main())
