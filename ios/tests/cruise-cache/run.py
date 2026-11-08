#!/usr/bin/env python3
"""Offline host regression for the cruise rolling cache (CruiseMapCache)."""
import pathlib, subprocess, tempfile
root = pathlib.Path(__file__).resolve().parents[3]
with tempfile.TemporaryDirectory(prefix='motonav-cruise-cache-') as folder:
    folder = pathlib.Path(folder)
    exe = folder / 'cruise'
    subprocess.run(['swiftc', '-module-cache-path', str(folder / 'modules'), '-swift-version', '5',
                   str(root / 'ios/MotoNav/MapGeo.swift'), str(root / 'ios/MotoNav/CruiseMapCache.swift'),
                   str(pathlib.Path(__file__).parent / 'main.swift'), '-o', str(exe)], check=True)
    subprocess.run([str(exe)], check=True)
