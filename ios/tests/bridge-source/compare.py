"""Read-only comparison of two exported capture scenes, including exact PNG hashes.
Usage: python3 ios/tests/bridge-source/compare.py DEFAULT_SCENE STYLE_SCENE OUTPUT.json
"""
from pathlib import Path
import hashlib, json, sys
from PIL import Image, ImageChops

def sha(path): return hashlib.sha256(path.read_bytes()).hexdigest()
def compare(left, right):
    rows=[]
    for path in sorted(left.glob('*.png')):
        other=right/path.name
        assert other.exists(), f'Missing paired PNG: {other}'
        a,b=Image.open(path).convert('RGB'),Image.open(other).convert('RGB')
        assert a.size==b.size, f'Image dimensions differ: {path.name}'
        difference=ImageChops.difference(a,b)
        rows.append(dict(file=path.name,defaultSHA256=sha(path),styleSHA256=sha(other),
            byteIdentical=path.read_bytes()==other.read_bytes(),
            changedRGBPixels=sum(any(pixel) for pixel in zip(*[iter(difference.tobytes())]*3))))
    cameras=[]
    for path in sorted(left.glob('*-camera.json')):
        other=right/path.name
        cameras.append(dict(file=path.name,equal=json.loads(path.read_text())==json.loads(other.read_text()),
            defaultSHA256=sha(path),styleSHA256=sha(other)))
    return dict(default=str(left.resolve()),style=str(right.resolve()),pngs=rows,cameras=cameras,
        styleMetadata=json.loads((right/'scene.json').read_text()),
        conclusion='Report observed pixel equality/differences only; requested style and verified asset SHA do not establish visual application or SDK compatibility.')

if __name__=='__main__':
    left,right,out=map(Path,sys.argv[1:])
    assert not out.exists(), 'Use a new report file'
    result=compare(left,right)
    assert all(row['byteIdentical']==(row['defaultSHA256']==row['styleSHA256']) for row in result['pngs'])
    out.parent.mkdir(parents=True,exist_ok=True)
    out.write_text(json.dumps(result,indent=2,ensure_ascii=False)+'\n')
    print(json.dumps(dict(pngs=len(result['pngs']),byteIdentical=sum(r['byteIdentical'] for r in result['pngs']),
        changedRGBPixels=sum(r['changedRGBPixels'] for r in result['pngs']),
        camerasEqual=all(r['equal'] for r in result['cameras']))))
