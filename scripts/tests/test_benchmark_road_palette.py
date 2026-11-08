#!/usr/bin/env python3
"""Isolated filesystem regression; no toolchain, device, or real output access."""
import contextlib
import importlib.util
import io
import json
from pathlib import Path
import tempfile
from unittest.mock import patch

SCRIPT = Path(__file__).resolve().parents[1] / 'benchmark-road-palette.py'
spec = importlib.util.spec_from_file_location('benchmark_road_palette', SCRIPT)
bench = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bench)

with tempfile.TemporaryDirectory() as temp:
    root = Path(temp).resolve()
    source = root / 'firmware/boards/175/MotoNav'
    def write(path, data):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
    write(source / 'MotoNav.ino', b'#include "src/diagnostics/RenderBenchmarks.h"\n  helperInit();\nesp_task_wdt_add(0);\nesp_task_wdt_reset();\n')
    write(source / 'src/map/RasterRenderer.h', b'// renderer stub\n')
    write(root / 'firmware/tests/raster-road-palette/DeviceBenchmark.h', b'// runtime stub\n')
    write(root / 'firmware/tests/raster-road-palette/fixtures/RasterRowsBefore.h', b'// baseline stub\n')
    sample = root / 'output/map-edge-bridge/road-palette-qa/06-mingbo'
    for name, marker, version in [('old-building.bin', 'd047', 0), ('building.bin', 'd087', 1)]:
        packet = bytearray(48)
        packet[14:16] = bytes.fromhex(marker)
        if version:
            packet[44:48] = bytes([0x4e, 0x4d, 0x10 | version, 0x52])
        write(sample / name, packet)
    packet[44:48] = bytes([0x4e, 0x4d, 0x12, 0x52])
    write(root / 'output/map-edge-bridge/road-multitone-export/06-mingbo/building.bin', packet)
    bench.ROOT, bench.SOURCE = root, source
    bench.OUTPUT = root / 'output/map-edge-bridge/device-bench-road-palette'
    for multitone in (False, True):
        base = root / 'output/road-multitone/device-bench' if multitone else bench.OUTPUT
        write(base / 'MotoNav/manual-sentinel.txt', b'keep manual evidence\n')
        write(base / 'manifest.json', b'keep old manifest\n')
        old = {p: p.read_bytes() for p in root.rglob('*') if p.is_file()}
        runs = []
        for _ in range(2):
            stdout = io.StringIO()
            argv = [str(SCRIPT), '--dry-run'] + (['--multitone'] if multitone else [])
            with patch('sys.argv', argv), contextlib.redirect_stdout(stdout), \
                 patch.object(bench.subprocess, 'check_output', return_value='fake-head\n') as git, \
                 patch.object(bench.subprocess, 'run', side_effect=AssertionError('must not invoke Arduino or device')) as run, \
                 patch.object(bench.importlib.util, 'spec_from_file_location', side_effect=AssertionError('must not load build dependencies')):
                bench.main()
            git.assert_called_once_with(['git', 'rev-parse', 'HEAD'], cwd=root, text=True)
            run.assert_not_called()
            paths = json.loads(stdout.getvalue())['paths']
            run_dir = Path(paths['run'])
            assert run_dir.parent == base and run_dir not in runs
            runs.append(run_dir)
            manifest = json.loads(Path(paths['manifest']).read_text())
            assert manifest['paths'] == paths
            for key, relative in [('sketch', 'MotoNav'), ('build', 'build'), ('artifacts', 'artifacts'), ('manifest', 'manifest.json')]:
                assert Path(paths[key]) == run_dir / relative
            assert (Path(paths['sketch']) / 'RoadPaletteBenchAssets.h').is_file()
            assert manifest['deviceRun'] is False and manifest['uploaded'] is False
            assert all(p.read_bytes() == data for p, data in old.items())
            old = {p: p.read_bytes() for p in root.rglob('*') if p.is_file()}
        print(f'PASS {"multitone" if multitone else "default"}: two isolated dry-runs preserve all prior files; no build/toolchain/device calls')
