"""Export a manually inspected OFF3 gray-median segment, never infer a bridge.
Usage: python3 ios/tests/bridge-source/candidate.py REPLAY_DIRECTORY
Only creates source-evidence masks/CSV; does not modify any stage or production.
"""
from pathlib import Path
import csv, hashlib, json, sys
from PIL import Image

folder = Path(sys.argv[1])
report = json.loads((folder/'report.json').read_text())
assert Path(report['scene']).name == '04-interchange'
assert report['tile'] == 'building-3-off' and report['size'] == 600
sampled = Image.open(folder/'sampled.png').convert('RGB')
a = (folder/'classified.idx').read_bytes()
b = (folder/'recovered.idx').read_bytes()
c = (folder/'smoothed.idx').read_bytes()
# shortcut: manually inspected 04-interchange OFF3 median trace, inspect new source before reuse.
points = []
for y in range(124, 134):
    centre = 92 + (y-124)*0.47
    for x in range(int(centre)-1, int(centre)+3):
        rgb = sampled.getpixel((x,y)); p = y*600+x
        if a[p] == b[p] == 0 and max(rgb)-min(rgb) <= 20 and max(rgb) < 250:
            points.append((x,y,*rgb,a[p],b[p],c[p]))
assert points and all(row[5:7] == (0,0) for row in points)
mask = Image.new('L',(600,600))
for x,y,*_ in points: mask.putpixel((x,y),255)
mask.save(folder/'candidate-source-gray-mask.png')
with (folder/'candidate-points.csv').open('w') as file:
    writer = csv.writer(file);writer.writerow(['sampleX','sampleY','R','G','B','classify','recover','smooth']);writer.writerows(points)
info = dict(scope='Manually inspected existing median gray pixels only; no inferred continuation, road identity, z-order or bridge outline',
    selected=len(points),localSmoothingErosion=sum(row[-1]==1 for row in points),
    coordinates='600x600 sample grid; source mapping in paired projection JSON',
    generatorSHA256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest())
(folder/'candidate-report.json').write_text(json.dumps(info,indent=2)+'\n')
print(json.dumps(info))
