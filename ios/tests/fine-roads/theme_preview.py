"""Render four-theme before/after previews for the Mingbo AMap sample and the
Century Park OpenFreeMap sample at the 2 m grid and firmware 480 scale."""
from pathlib import Path
from PIL import Image, ImageDraw

root = Path(__file__).resolve().parents[3]
sample = root / 'output' / 'map-edge-bridge' / 'fine-roads-sample'
park = root / 'output' / 'map-edge-bridge' / 'fine-roads-20261106' / 'vector-park'
out = root / 'docs' / 'verification'
n = 1200

THEMES = {
    1: {0: (37, 38, 40), 1: (166, 168, 168), 2: (63, 81, 73), 3: (66, 83, 94),
        8: (32, 32, 35), 9: (64, 64, 68), 10: (37, 38, 40), 11: (96, 96, 101)},
    2: {0: (37, 38, 40), 1: (166, 168, 168), 2: (63, 81, 73), 3: (66, 83, 94),
        8: (112, 122, 122), 9: (154, 164, 164), 10: (37, 38, 40), 11: (198, 202, 202)},
    3: {0: (37, 38, 40), 1: (166, 168, 168), 2: (63, 81, 73), 3: (66, 83, 94),
        8: (33, 70, 72), 9: (56, 130, 129), 10: (37, 38, 40), 11: (80, 170, 168)},
    5: {0: (17, 17, 17), 1: (255, 255, 255)},
}


def image(idx, theme):
    pal = THEMES[theme]
    im = Image.new('RGB', (n, n))
    im.putdata([pal.get(v & 15, pal[0]) for v in idx])
    return im


def decode(path, header):
    b = Path(path).read_bytes()
    out = bytearray()
    p = header
    while p < len(b):
        v = b[p]
        p += 1
        run = (v >> 4) + 1
        if v >> 4 == 15:
            run = 16 + b[p]
            p += 1
        out.extend(bytes([v & 15]) * run)
    assert len(out) == n * n, (path, len(out))
    return out


def panel(rows, path, left_w, right_w, top=26):
    block_h = max(rows[0][1].height, rows[0][3].height)
    canvas = Image.new('RGB', (left_w + right_w, top + len(rows) * (block_h + top)), 'white')
    draw = ImageDraw.Draw(canvas)
    for i, (name, left, llabel, right, rlabel) in enumerate(rows):
        y = top + i * (block_h + top)
        draw.text((4, y - 18), f'{name} · {llabel}', fill='black')
        draw.text((left_w + 6, y - 18), rlabel, fill='black')
        canvas.paste(left, (0, y))
        canvas.paste(right, (left_w + 6, y))
    canvas.save(path)
    return path


base = (sample / 'base' / 'game.idx').read_bytes()
fine = (sample / 'result' / 'enhanced.idx').read_bytes()
old_min = (sample / 'base' / 'minimal.idx').read_bytes()
new_min = (sample / 'result' / 'minimal-new.idx').read_bytes()
roi = (740, 830, 930, 1000)
scale = 3

mingbo_rows = []
for theme in (1, 2, 3):
    before = image(base, theme).crop(roi).resize(((roi[2]-roi[0])*scale, (roi[3]-roi[1])*scale), Image.Resampling.NEAREST)
    after = image(fine, theme).crop(roi).resize(((roi[2]-roi[0])*scale, (roi[3]-roi[1])*scale), Image.Resampling.NEAREST)
    mingbo_rows.append((f'theme {theme}', before, 'before: wide base', after, 'after: one near patch'))
# The park ROI has no white roads in the minimal mask; use a nearby real crop
# where the old cleanup removed one-cell roads to show the actual fix.
diff = [1 if old_min[i] == 0 and new_min[i] == 1 else 0 for i in range(n * n)]
best, best_rect = -1, (0, 0, 120, 120)
for y in range(0, n - 120 + 1, 10):
    for x in range(0, n - 120 + 1, 10):
        s = sum(sum(diff[(y + dy) * n + x:(y + dy) * n + x + 120]) for dy in range(120))
        if s > best:
            best, best_rect = s, (x, y, x + 200, y + 200)
mb = image(old_min, 5).crop(best_rect).resize((600, 600), Image.Resampling.NEAREST)
ma = image(new_min, 5).crop(best_rect).resize((600, 600), Image.Resampling.NEAREST)
mingbo_rows.append(('theme 5', mb, f'before: nearby crop {best_rect[:2]}', ma, f'after: recovered {best} cells'))
panel(mingbo_rows, out / 'fine-roads-mingbo-themes.png', mingbo_rows[0][1].width, mingbo_rows[0][3].width)

park_sem = decode(park / 'mingbo-park-s2.bin', 48)
park_min = decode(park / 'mingbo-park-s5.bin', 16)
crop600 = (300, 300, 900, 900)
half = int(round(212 / 0.6 / 2))
firmware = (600 - half, 600 - half, 600 + half, 600 + half)
park_rows = []
for theme in (1, 2, 3):
    left = image(park_sem, theme).crop(crop600)
    right = image(park_sem, theme).crop(firmware).resize((480, 480), Image.Resampling.NEAREST)
    park_rows.append((f'theme {theme}', left, 'vector 600 crop, 2 m grid', right, 'firmware 480 scale'))
left = image(park_min, 5).crop(crop600)
right = image(park_min, 5).crop(firmware).resize((480, 480), Image.Resampling.NEAREST)
park_rows.append(('theme 5', left, 'minimal vector crop', right, 'firmware 480 scale'))
panel(park_rows, out / 'fine-roads-park-themes.png', 600, 480)

print('wrote', out / 'fine-roads-mingbo-themes.png')
print('wrote', out / 'fine-roads-park-themes.png')
print('mingbo minimal roads old/new', old_min.count(1), new_min.count(1))
