"""Render the accepted Mingbo before/after comparison from material grids.

Consumes output/map-edge-bridge/fine-roads-sample/result/enhanced.idx produced by
the Swift FineRoads harness. No network, SDK or device access.
"""
from pathlib import Path
from PIL import Image, ImageDraw

root = Path(__file__).resolve().parents[3]
sample = root / 'output' / 'map-edge-bridge' / 'fine-roads-sample'
result = sample / 'result'
out = root / 'output' / 'map-edge-bridge' / 'fine-roads-20261106'
out.mkdir(parents=True, exist_ok=True)
docs = root / 'docs' / 'verification'
docs.mkdir(parents=True, exist_ok=True)

palette = [
    (37, 38, 40),      # 0 ground
    (166, 168, 168),   # 1 road
    (63, 81, 73),      # 2 park
    (66, 83, 94),      # 3 water
    (54, 56, 58),      # 4 roof
    (80, 82, 85),      # 5 roof edge
    (54, 56, 58),      # 6
    (80, 82, 85),      # 7
    (112, 122, 122),   # 8 warm road dark
    (154, 164, 164),   # 9 warm road
    (37, 38, 40),      # 10 protected casing
    (198, 202, 202),   # 11 warm road bright
]
n = 1200

def image(data):
    im = Image.new('RGB', (n, n))
    im.putdata([palette[v & 15] for v in data])
    return im

base = (sample / 'base' / 'game.idx').read_bytes()
enhanced = (result / 'enhanced.idx').read_bytes()
assert len(base) == len(enhanced) == n * n
left, right = image(base), image(enhanced)
roi = (740, 830, 930, 1000)

def panel(left_im, right_im, path, scale=1, labels=('Current wide base', 'Fine roads (one near patch)')):
    w, h = left_im.size
    top = 25
    canvas = Image.new('RGB', (2 * w * scale, h * scale + top), 'white')
    draw = ImageDraw.Draw(canvas)
    for i, im in enumerate((left_im, right_im)):
        canvas.paste(im.resize((w * scale, h * scale), Image.Resampling.NEAREST), (i * w * scale, top))
        draw.text((i * w * scale + 4, 6), labels[i], fill='black')
    canvas.save(path)
    return path

panel(left, right, out / 'fine-roads-full-comparison.png')
panel(left.crop(roi), right.crop(roi), out / 'fine-roads-local-comparison.png', scale=3)
# Firmware raster view: R=212 px at sc=0.6 px/m → 353 m radius, 2 m cells.
half_cells = int(round(212 / 0.6 / 2))
cx, cy = (roi[0] + roi[2]) // 2, (roi[1] + roi[3]) // 2
screen = (cx - half_cells, cy - half_cells, cx + half_cells, cy + half_cells)
panel(left.crop(screen).resize((480, 480), Image.Resampling.NEAREST),
      right.crop(screen).resize((480, 480), Image.Resampling.NEAREST),
      out / 'fine-roads-480-comparison.png', scale=1,
      labels=('Current base, firmware scale', 'Fine roads, firmware scale'))
# Deliverable copy used by the report.
panel(left.crop(roi), right.crop(roi), docs / 'fine-roads-comparison.png', scale=3)

# Counts in the accepted ROI and the visible change at screen scale.
def count(data, values, rect=roi):
    x0, y0, x1, y1 = rect
    return sum(1 for y in range(y0, y1) for v in data[y * n + x0:y * n + x1] if v in values)

print('ROI road pixels: base', count(base, {1, 8, 9, 11}), 'enhanced', count(enhanced, {1, 8, 9, 11}))
print('ROI added road pixels', sum(1 for a, b in zip(base[830 * n + 740:1000 * n + 930],
                                                   enhanced[830 * n + 740:1000 * n + 930])
                                  if (a not in (1, 8, 9, 11)) and b == 1))
print('wrote', out / 'fine-roads-full-comparison.png')
print('wrote', out / 'fine-roads-local-comparison.png')
print('wrote', out / 'fine-roads-480-comparison.png')
print('wrote', docs / 'fine-roads-comparison.png')
