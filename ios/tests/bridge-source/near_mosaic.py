"""Compare base and four precisely sampled OFF tiles on the same 2 m world grid.
No bridge detector: ROI identity and observed edge claims require human source review.
"""
from pathlib import Path
import argparse, csv, json, subprocess, tempfile
from PIL import Image, ImageDraw
from replay import ROOT, HERE, PALETTE, sha

STAGES = ['classified', 'recovered', 'smoothed']


def sample(scene, name):
    stem = 'base' if name == 'base' else name.replace('-off', '-on')
    projection = scene / (stem + '.json')
    camera_path = scene / ('base-camera.json' if name == 'base' else name.replace('-off', '-camera') + '.json')
    camera = json.loads(camera_path.read_text())
    proj = json.loads(projection.read_text())
    path = scene / (name + '.png')
    source = Image.open(path).convert('RGB')
    n, cols, rows = proj['size'], proj['columns'], proj['rows']
    assert source.size == (proj['width'], proj['height'])
    assert len(cols) == len(rows) == n
    assert all(0 <= x < source.width for x in cols) and all(0 <= y < source.height for y in rows)
    if name != 'base':
        assert camera['onProjection'] == camera['offProjection']
    image = Image.new('RGB', (n, n))
    image.putdata([source.getpixel((x, y)) for y in rows for x in cols])
    return image, source, proj, camera, [path, projection, camera_path]


def argb(image):
    return b''.join(bytes((b, g, r, 255)) for r, g, b in image.getdata())


def panel(images, labels, path, scale=3):
    w, h = images[0].size
    canvas = Image.new('RGB', (len(images)*w*scale, h*scale+25), 'white')
    for i, (im, label) in enumerate(zip(images, labels)):
        canvas.paste(im.resize((w*scale, h*scale), Image.Resampling.NEAREST), (i*w*scale, 25))
        ImageDraw.Draw(canvas).text((i*w*scale+3, 5), label, fill='black')
    canvas.save(path)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('scene', type=Path)
    parser.add_argument('output', type=Path)
    parser.add_argument('--rois', type=Path, help='JSON [{name, rect, observation?}]; world pixels, end exclusive')
    args = parser.parse_args()
    scene, out = args.scene.resolve(), args.output.resolve()
    assert out != scene and scene not in out.parents
    out.mkdir(parents=True, exist_ok=True)
    assert not (out/'report.json').exists(), 'Use a fresh output directory'
    base, base_source, bp, bc, files = sample(scene, 'base')
    n = base.width
    assert n == 1200 and bc['size'] == n
    assert argb(base) == (scene/'base-sampled-2m.argb32le').read_bytes()
    near = Image.new('RGB', base.size)
    tiles = []
    for i in range(4):
        im, source, proj, cam, paths = sample(scene, f'building-{i}-off')
        x = (cam['relativeX']-bc['relativeX'])/2
        y = (bc['relativeY']-cam['relativeY'])/2
        assert x == int(x) and y == int(y)
        x, y = int(x), int(y)
        assert im.size == (600, 600) and (x, y) == ((i%2)*600, (i//2)*600)
        near.paste(im, (x, y)); files += paths
        tiles.append((source, proj, cam, x, y))
    source_path = ROOT/'ios/MotoNav/MapGeo.swift'
    original = source_path.read_text()
    marker = 'private static func recoverGrayRoads('
    assert original.count(marker) == 1
    report = dict(size=n, metresPerPixel=2, sourceSHA256={str(p.relative_to(ROOT)):sha(p) for p in files+[source_path,HERE/'main.swift',Path(__file__)]},
        baseCamera=bc, nearCameras=[v[2] for v in tiles],
        alignment='relativeX/Y camera bounds and exact archived projection columns/rows; no image resize',
        cameraCaveat='Same world grid; different SDK zoom and base camera 0 vs near 0.05 degrees. Across-source differences are source cartography, not classification loss.',
        bridgeIdentity='Unverified unless supplied ROI observation explicitly records reviewed source evidence; no layer inference.', inputs={}, rois=[])
    all_images, all_indices = {}, {}
    with tempfile.TemporaryDirectory(prefix='near-road-source-') as temp:
        tmp = Path(temp)
        (tmp/'MapGeo.swift').write_text(original.replace(marker, 'static func recoverGrayRoads('))
        subprocess.run(['swiftc','-O','-module-cache-path',str(tmp/'modules'),str(tmp/'MapGeo.swift'),str(HERE/'main.swift'),'-o',str(tmp/'replay')], check=True)
        for name, im in [('base',base),('near',near)]:
            folder = out/name; folder.mkdir()
            im.save(folder/'sampled.png')
            raw = folder/'sampled.argb32le'; raw.write_bytes(argb(im))
            result = subprocess.run([str(tmp/'replay'),str(raw),str(folder),str(n)], check=True,capture_output=True,text=True)
            report['inputs'][name] = json.loads(result.stdout)
            indices = [(folder/(stage+'.idx')).read_bytes() for stage in STAGES]
            images = []
            for stage, values in zip(STAGES, indices):
                image = Image.new('RGB', (n,n)); image.putdata([PALETTE[v] for v in values]); image.save(folder/(stage+'.png')); images.append(image)
            all_images[name] = [im]+images; all_indices[name] = indices
    panel([base,near], ['Base source, low zoom','Near OFF mosaic, high zoom'],out/'source-overview.png',1)
    rois = json.loads(args.rois.read_text()) if args.rois else []
    if args.rois: report['roiDefinitionSHA256'] = sha(args.rois)
    for roi in rois:
        name = roi['name']; rect = roi['rect']; x0,y0,x1,y1 = rect
        assert name.replace('-','').replace('_','').isalnum()
        assert 0 <= x0 < x1 <= n and 0 <= y0 < y1 <= n
        folder = out/name; folder.mkdir()
        entry = dict(roi, inputs={})
        for label in ['base','near']:
            crops = [im.crop(rect) for im in all_images[label]]
            panel(crops, [label+' RGB']+STAGES,folder/(label+'-stages.png'))
            ids = [y*n+x for y in range(y0,y1) for x in range(x0,x1)]
            stages = all_indices[label]
            entry['inputs'][label] = dict(grayChanges=sum(stages[0][p]!=stages[1][p] for p in ids), smoothingChanges=sum(stages[1][p]!=stages[2][p] for p in ids))
        panel([base.crop(rect),near.crop(rect)],['Base sampled source','Near sampled source'],folder/'source-comparison.png')
        native_rect = [bp['columns'][x0],bp['rows'][y0],bp['columns'][x1-1]+1,bp['rows'][y1-1]+1]
        base_source.crop(native_rect).save(folder/'base-native-source.png')
        entry['baseNativeRect'] = native_rect
        entry['nearNativeRects'] = []
        for i,(source,proj,cam,x,y) in enumerate(tiles):
            a,b,c,d = max(x0,x)-x,max(y0,y)-y,min(x1,x+600)-x,min(y1,y+600)-y
            if a >= c or b >= d: continue
            native = [proj['columns'][a],proj['rows'][b],proj['columns'][c-1]+1,proj['rows'][d-1]+1]
            source.crop(native).save(folder/f'near-{i}-native-source.png')
            entry['nearNativeRects'].append(dict(tile=i,worldRect=[a+x,b+y,c+x,d+y],nativeRect=native))
        with (folder/'pixel-stages.csv').open('w') as file:
            writer = csv.writer(file)
            writer.writerow(['worldX','worldY','input','tile','nativeX','nativeY','R','G','B']+STAGES)
            for world_y in range(y0,y1):
                for world_x in range(x0,x1):
                    pos = world_y*n+world_x
                    for label in ['base','near']:
                        if label == 'base':
                            tile, projection, xx, yy = 'base', bp, world_x, world_y
                        else:
                            tile = (world_y//600)*2 + world_x//600
                            _,projection,_,offset_x,offset_y = tiles[tile]
                            xx, yy = world_x-offset_x, world_y-offset_y
                        writer.writerow([world_x,world_y,label,tile,projection['columns'][xx],projection['rows'][yy],
                            *all_images[label][0].getpixel((world_x,world_y)), *[v[pos] for v in all_indices[label]]])
        entry['crossSourceRGBChanges'] = sum(a!=b for a,b in zip(base.crop(rect).getdata(),near.crop(rect).getdata()))
        report['rois'].append(entry)
    report['productionReplay'] = 'Each complete 1200-square input asserts smoothed == production classifyAmapBase(style:1). Only private removed in temporary source copy.'
    report['outputSHA256'] = {str(p.relative_to(out)):sha(p) for p in out.rglob('*') if p.is_file()}
    (out/'report.json').write_text(json.dumps(report,indent=2,ensure_ascii=False)+'\n')
    print(json.dumps(report['inputs']))

if __name__ == '__main__': main()
