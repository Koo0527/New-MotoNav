#!/usr/bin/env python3
"""CI wrapper for the cruise rolling cache host regression."""
import pathlib, subprocess
root = pathlib.Path(__file__).resolve().parents[3]
subprocess.run(["python3", str(root / "ios/tests/cruise-cache/run.py")], check=True)
