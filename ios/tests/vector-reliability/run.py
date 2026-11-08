#!/usr/bin/env python3
"""Offline host regression for VectorTileClient reliability semantics.

Compiles the production client (VectorTiles.swift is self-contained Foundation +
Compression) with an injected-network test driver: request coalescing, cancel
semantics with waiters, 429 Retry-After cooldowns, data-generation identity,
persisted TileJSON bootstrap, 24h revalidation and event whitelisting.
"""
import pathlib, subprocess, tempfile
root = pathlib.Path(__file__).resolve().parents[3]
with tempfile.TemporaryDirectory(prefix='motonav-vector-reliability-') as folder:
    folder = pathlib.Path(folder)
    exe = folder / 'reliability'
    subprocess.run(['swiftc', '-module-cache-path', str(folder / 'modules'), '-swift-version', '5',
                   str(root / 'ios/MotoNav/VectorTiles.swift'), str(pathlib.Path(__file__).parent / 'main.swift'),
                   '-o', str(exe)], check=True)
    subprocess.run([str(exe)], check=True)
