"""Prepare the accepted Mingbo fine-road sample on the production 2 m grid.

Reads the archived base/near replay (1200 x 1200, 0=block 1=road 2=park 3=water)
and extracts the south-east 600 x 600 quadrant used by one production near capture.
Outputs plain files for the Swift FineRoads harness; no network or SDK call.
"""
from pathlib import Path
import shutil, struct

root = Path(__file__).resolve().parents[3]
sample = Path('/var/folders/9r/w54jr4gn0hnf3s4z7xctwh6c0000gn/T/motonav-fine-roads-y2xptcrn')
out = root / 'output' / 'map-edge-bridge' / 'fine-roads-sample'
out.mkdir(parents=True, exist_ok=True)

for rel in ['base/game.idx', 'near/game.idx', 'near/sampled.argb32le', 'base/sampled.argb32le',
            'base/sampled.png', 'near/sampled.png', 'base/minimal.idx']:
    src = sample / rel
    dst = out / rel
    dst.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(src, dst)

n = 1200
near = (sample / 'near' / 'game.idx').read_bytes()
assert len(near) == n * n
# South-east quadrant x=[600,1200), y=[600,1200)
near600 = bytearray()
for y in range(600, 1200):
    near600 += near[y * n + 600: y * n + 1200]
(out / 'near600.idx').write_bytes(bytes(near600))

raw = (sample / 'near' / 'sampled.argb32le').read_bytes()
assert len(raw) == n * n * 4
colors = bytearray()
for y in range(600, 1200):
    colors += raw[(y * n + 600) * 4: (y * n + 1200) * 4]
(out / 'near600.argb32le').write_bytes(bytes(colors))

base = (sample / 'base' / 'game.idx').read_bytes()
assert len(base) == n * n
counts = {}
for v in base:
    counts[v] = counts.get(v, 0) + 1
print('wrote', out)
print('base material counts', counts)
print('near600 road pixels', sum(1 for v in near600 if v == 1))
