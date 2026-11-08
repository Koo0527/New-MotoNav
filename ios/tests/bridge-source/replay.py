"""Offline, exact-production-stage replay. See README.md; requires installed Pillow + swiftc."""
from pathlib import Path
import argparse, csv, hashlib, json, struct, subprocess, tempfile
from collections import Counter
from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parents[3]
HERE = Path(__file__).resolve().parent
PALETTE = [(242,242,242), (40,40,40), (150,215,140), (90,180,235)]

def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def decide(source, sampled, stages):
    # Each triplet is pavement, candidate boundary, pavement; identity is not a bridge detector.
    distinct = lambda values: values[1] != values[0] and values[1] != values[2]
    if not distinct(source): return 'source-absent'
    if not distinct(sampled): return 'resampling-loss'
    if not distinct(stages[0]) or not distinct(stages[1]): return 'classification-loss'
    if not distinct(stages[2]): return 'smoothing-loss'
    return 'retained'

def self_check():
    a, b = [1,0,1], [1,1,1]
    assert decide(b,a,[a,a,a]) == 'source-absent'
    assert decide(a,b,[a,a,a]) == 'resampling-loss'
    assert decide(a,a,[b,b,b]) == 'classification-loss'
    assert decide(a,a,[a,a,b]) == 'smoothing-loss'
    assert decide(a,a,[a,a,a]) == 'retained'

def main():
    self_check()
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('scene', type=Path)
    parser.add_argument('output', type=Path)
    parser.add_argument('--tile', default='base', help='base or building-N-off; OFF is independently sampled')
    parser.add_argument('--rois', type=Path)
    args = parser.parse_args()
    scene, out = args.scene.resolve(), args.output.resolve()
    assert out != scene and scene not in out.parents, 'Output must be outside the source scene'
    out.mkdir(parents=True, exist_ok=True)
    assert not (out/'report.json').exists(), 'Use a new output directory'
    tile = args.tile
    assert tile == 'base' or (tile.startswith('building-') and tile.endswith('-off'))
    projection = scene / ('base.json' if tile == 'base' else tile.replace('-off','-on')+'.json')
    image_path = scene / (tile+'.png')
    camera_path = scene / ('base-camera.json' if tile == 'base' else tile.replace('-off','-camera')+'.json')
    proj = json.loads(projection.read_text()); camera = json.loads(camera_path.read_text())
    image = Image.open(image_path).convert('RGB'); n = proj['size']
    cols, rows = proj['columns'], proj['rows']
    assert image.size == (proj['width'],proj['height']) and len(cols) == len(rows) == n
    assert all(0 <= x < image.width for x in cols) and all(0 <= y < image.height for y in rows)
    if tile != 'base':
        assert camera['onProjection'] == camera['offProjection'], 'OFF/ON camera projection mismatch'
    sampled = Image.new('RGB',(n,n)); sampled.putdata([image.getpixel((x,y)) for y in rows for x in cols])
    sampled.save(out/'sampled.png')
    # ARGB32 little endian has byte order B,G,R,A.
    raw = bytearray()
    for r,g,b in zip(*[iter(sampled.tobytes())]*3): raw.extend((b,g,r,255))
    (out/'replayed.argb32le').write_bytes(raw)
    archived = scene/(tile+'-sampled-2m.argb32le')
    if tile == 'base':
        assert archived.read_bytes() == raw, 'PNG/projected replay differs from archived production samples'
    source = ROOT/'ios/MotoNav/MapGeo.swift'
    original = source.read_text(); marker = 'private static func recoverGrayRoads('
    assert original.count(marker) == 1
    exposed = original.replace(marker, 'static func recoverGrayRoads(')
    report = dict(scene=str(scene), tile=tile, camera=camera, size=n,
        materialPalette=dict(enumerate(PALETTE)),
        sourceSHA256={str(p.relative_to(ROOT)) if p.is_relative_to(ROOT) else str(p):sha(p)
            for p in [source,HERE/'main.swift',Path(__file__),image_path,projection,camera_path]},
        productionSourceModification='Only remove private on temporary recoverGrayRoads copy',
        stageEquality='asserted smoothed == classifyAmapBase(style:1)', rois=[])
    with tempfile.TemporaryDirectory(prefix='motonav-bridge-source-') as temp:
        tmp = Path(temp); (tmp/'MapGeo.swift').write_text(exposed)
        subprocess.run(['swiftc','-O','-module-cache-path',str(tmp/'modules'),str(tmp/'MapGeo.swift'),str(HERE/'main.swift'),'-o',str(tmp/'replay')],check=True)
        result = subprocess.run([str(tmp/'replay'),str(out/'replayed.argb32le'),str(out),str(n)],check=True,capture_output=True,text=True)
        report['stages'] = json.loads(result.stdout)
    stages = [(out/(stage+'.idx')).read_bytes() for stage in ['classified','recovered','smoothed']]
    images = []
    for name,values in zip(['classified','recovered','smoothed'],stages):
        im = Image.new('RGB',(n,n)); im.putdata([PALETTE[v] for v in values]); im.save(out/(name+'.png')); images.append(im)
    rois = json.loads(args.rois.read_text()) if args.rois else []
    if args.rois: report['sourceSHA256'][str(args.rois.resolve())] = sha(args.rois)
    assert len({roi['name'] for roi in rois}) == len(rois), 'Duplicate ROI names'
    for roi in rois:
        name, rect = roi['name'], roi['rect']
        assert name.replace('-','').replace('_','').isalnum()
        x0,y0,x1,y1 = rect
        assert 0 <= x0 < x1 <= n and 0 <= y0 < y1 <= n
        folder = out/name; folder.mkdir()
        source_rect = [cols[x0],rows[y0],cols[x1-1]+1,rows[y1-1]+1]
        image.crop(source_rect).save(folder/'source.png')
        crops = [sampled.crop(rect)] + [im.crop(rect) for im in images]
        canvas = Image.new('RGB', (4*(x1-x0)*3,(y1-y0)*3+24), 'white')
        for i,(im,label) in enumerate(zip(crops,['Sampled RGB','Classify','Recover gray','Smooth'])):
            canvas.paste(im.resize((im.width*3,im.height*3),Image.Resampling.NEAREST),(i*im.width*3,24))
            ImageDraw.Draw(canvas).text((i*im.width*3+3,5),label,fill='black')
            im.save(folder/(label.replace(' ','-')+'.png'))
        canvas.save(folder/'stages.png')
        ids = [y*n+x for y in range(y0,y1) for x in range(x0,x1)]
        entry = dict(roi, sourceRect=source_rect, sampleRect=rect,
            materialCounts=[dict(Counter(values[p] for p in ids)) for values in stages],
            grayRoadChanges=sum(stages[0][p]!=stages[1][p] for p in ids),
            smoothingChanges=sum(stages[1][p]!=stages[2][p] for p in ids), probes=[])
        for probe in roi.get('probes',[]):
            points = probe['samplePoints']; source_points = probe.get('sourcePoints',[[cols[x],rows[y]] for x,y in points])
            assert len(points) == len(source_points) == 3
            assert all(0 <= x < n and 0 <= y < n for x,y in points)
            assert all(0 <= x < image.width and 0 <= y < image.height for x,y in source_points)
            rgb = [image.getpixel(tuple(p)) for p in source_points]
            values = [sampled.getpixel(tuple(p)) for p in points]
            materials = [[s[y*n+x] for x,y in points] for s in stages]
            entry['probes'].append(dict(probe,sourcePoints=source_points,sourceRGB=rgb,sampledRGB=values,
                stages=materials,category=decide(rgb,values,materials)))
        axis, fixed, start, end = roi.get('profile',['y', (y0+y1)//2, x0,x1])
        with (folder/'profile.csv').open('w') as file:
            writer = csv.writer(file);writer.writerow(['sampleX','sampleY','sourceX','sourceY','R','G','B','classified','recovered','smoothed'])
            for q in range(start,end):
                x,y = (q,fixed) if axis == 'y' else (fixed,q)
                writer.writerow([x,y,cols[x],rows[y],*sampled.getpixel((x,y)),*[s[y*n+x] for s in stages]])
        report['rois'].append(entry)
    report['outputSHA256']={p.name:sha(p) for p in out.iterdir() if p.suffix in ('.idx','.argb32le')}
    (out/'report.json').write_text(json.dumps(report,indent=2,ensure_ascii=False)+'\n')
    print(json.dumps(dict(output=str(out),**report['stages']),ensure_ascii=False))

if __name__ == '__main__': main()
