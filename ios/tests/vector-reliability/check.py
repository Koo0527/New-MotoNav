#!/usr/bin/env python3
"""CI wrapper for the offline vector reliability host regression."""
import pathlib, subprocess
root = pathlib.Path(__file__).resolve().parents[3]
subprocess.run(["python3", str(root / "ios/tests/vector-reliability/run.py")], check=True)
