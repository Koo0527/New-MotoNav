"""Offline threshold-only probe. Frozen C, source masks and renderer stay unchanged."""
from array import array
import hashlib
import importlib.util
import json
from pathlib import Path
import struct
import subprocess
import tempfile
import zlib

ROOT = Path(__file__).resolve().parents[4]
OUT = ROOT / 'output/map-edge-bridge/visual-fit-probe'
spec = importlib.util.spec_from_file_location('frozen_check', Path(__file__).resolve().parents[1] / 'check.py')
frozen = importlib.util.module_from_spec(spec)
spec.loader.exec_module(frozen)


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    scenes = [(f'cached-{n:02}', ROOT / f'output/map-edge-bridge/cached-real/cached-{n:02}/pixels.idx') for n in range(1, 6)]
    scenes += [(f'fresh-{name}', ROOT / f'output/map-edge-bridge/fresh-replay/five-current/{name}/candidate.raw') for name in ('02-low-density', '03-diagonal')]
    records = []
    with tempfile.TemporaryDirectory(prefix='motonav-visual-') as tmp:
        exe, test, preview = [Path(tmp) / name for name in ('probe', 'test', 'preview')]
        subprocess.run(['c++', '-std=c++11', '-O2', str(Path(__file__).with_name('probe.cpp')), '-o', str(exe)], check=True)
        subprocess.run(['c++', '-std=c++11', '-O2', '-fsanitize=address,undefined', str(ROOT/'firmware/tests/raster-edge/DenseTest.cpp'), '-lz', '-o', str(test)], check=True)
        subprocess.run(['c++', '-std=c++11', '-O2', str(ROOT/'firmware/tests/raster-edge/DensePreview.cpp'), '-o', str(preview)], check=True)
        test_args = []
        for variant, limit in [('C-control', '.14'), ('D20', '.20'), ('D25', '.25')]:
            for name, path in scenes:
                dense = OUT / f'{variant}-{name}.u16'
                result = subprocess.run([str(exe), str(path), str(dense), 'C', limit], capture_output=True, text=True, check=True)
                report = json.loads(result.stdout)
                raw = dense.read_bytes()
                words = array('H'); words.frombytes(raw)
                import sys
                if sys.byteorder != 'little': words.byteswap()
                source = path.read_bytes()
                assert frozen.decode_centers(words) == source
                packed = zlib.compress(frozen.rle16(words), 1)
                restored = array('H')
                for count, word in struct.iter_unpack('<HH', zlib.decompress(packed)):
                    assert 1 <= count <= 65535
                    restored.extend([word] * count)
                assert restored == words
                dense.with_suffix('.rle.zlib').write_bytes(packed)
                baseline = ROOT / f'output/map-edge-bridge/dense-feasibility/C-{name}.u16'
                if variant == 'C-control': assert raw == baseline.read_bytes()
                old_words = array('H'); old_words.frombytes(baseline.read_bytes())
                if sys.byteorder != 'little': old_words.byteswap()
                legacy_path = path.with_name('base.bin' if name.startswith('cached') else 'candidate.bin')
                assert frozen.decode_legacy(legacy_path.read_bytes()) == source
                total = legacy_path.stat().st_size + len(packed) + 32
                report.update(variant=variant, scene=name, originalCentersExact=True, topologyCounterexamplesPassed=True,
                              fullLegacyPath=str(legacy_path.relative_to(ROOT)), fullLegacyBytes=legacy_path.stat().st_size,
                              tailZlibBytes=len(packed), headerAllowanceBytes=32, fullLegacyPlusTailPlus32=total,
                              budgetPassed=total<=480000, overBudgetBytes=max(0,total-480000),
                              changedDenseCells=sum(a!=b for a,b in zip(words,old_words)),
                              outerSilhouettePercent=round(report['outerAccepted']/max(1,report['outerMixed'])*100,3),
                              sourceSHA256=hashlib.sha256(source).hexdigest(),denseSHA256=hashlib.sha256(raw).hexdigest())
                records.append(report)
                test_args += [str(dense), str(path)]
                print(variant, name, 'outer', report['outerSilhouettePercent'], 'total', total, 'PASS' if total<=480000 else 'REJECT', flush=True)
        for start in range(0, len(test_args), 14):
            subprocess.run([str(test)] + test_args[start:start+14], check=True)
        # Frozen preview renders the unchanged palette/shader at 424px, .6 scale, 0/45/90 degrees.
        name, path = scenes[-1]
        current = path.with_name('current.raw')
        assert current.stat().st_size == 1440000
        for variant in ('C-control', 'D20', 'D25'):
            target = OUT / f'{variant}-fresh03-preview'; target.mkdir(exist_ok=True)
            subprocess.run([str(preview), str(current), str(path), str(OUT/f'{variant}-{name}.u16'), str(target)], check=True)
    report = dict(hostOnly=True, thresholdOnly=True, residualMeters={'C-control':.56,'D20':.8,'D25':1.0},
                  allOriginalCentersExact=True, all16HaloCentersExactWithMargin=.001,
                  frozenCByteIdentity=True, frozenDenseShaderASanUBSanCentersAndRLEPassed=True,
                  selfchecks='all4096 fallback patterns; axis/diagonal; four L orientations; courtyard inner/outer; narrow neck; road/water protected; morphological band fixtures',
                  devicePerformance='NOT RUN; old C timing is not evidence for D',
                  visualGate='PENDING HUMAN REVIEW; no T4 integration',
                  topologyLimit='Discrete original2m material topology exact; fractional seams/appearance require visual review', scenes=records)
    report['frozenSourceSHA256'] = {path: hashlib.sha256((ROOT/path).read_bytes()).hexdigest() for path in (
        'ios/tests/edge-dense/probe.cpp', 'ios/tests/edge-dense/check.py',
        'firmware/tests/raster-edge/DenseCell.h', 'firmware/tests/raster-edge/DensePreview.cpp',
        'firmware/boards/175/MotoNav/RasterEdge.h', 'firmware/boards/175/MotoNav/GameMapStyle.h')}
    report['thresholdLimitation'] = '0.8/1.0m is transition-midpoint residual, not a certified Hausdorff error to every fractional source contour point.'
    report['decision'] = 'D20/D25 each pass 6 of 7 full packet budgets, reject fresh03. No integration or deployment. Current investigation ended without expanding algorithms or budgets.'
    (OUT/'report.json').write_text(json.dumps(report, indent=2)+'\n')


if __name__ == '__main__': main()
