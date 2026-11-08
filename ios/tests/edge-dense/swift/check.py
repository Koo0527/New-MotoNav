"""Host Swift prototype: exact frozen word bytes, not merely decoded labels."""
from array import array
import hashlib
import importlib.util
import json
from pathlib import Path
import platform
import random
import statistics
import struct
import subprocess
import tempfile
import sys
sys.dont_write_bytecode = True
import zlib

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[3]
OUT = ROOT / 'output/map-edge-bridge/dense-swift-prototype'
FROZEN = ROOT / 'output/map-edge-bridge/dense-feasibility'
spec = importlib.util.spec_from_file_location('dense_check', HERE.parent / 'check.py')
helper = importlib.util.module_from_spec(spec); spec.loader.exec_module(helper)

def run(args):
    return subprocess.run([str(x) for x in args], check=True, capture_output=True, text=True).stdout

def synthetic():
    n = 24
    for park in (False, True):
        for shape in range(11):
            for orientation in range(4 if shape == 2 else 1):
                mask = []
                for y in range(n):
                    for x in range(n):
                        inside = (x >= 11 if shape in (0,5,6,7,8,9,10) else x+y >= 23 if shape == 1 else
                            (x <= 10 if orientation&1 else x >= 11) and (y <= 10 if orientation&2 else y >= 11) if shape == 2 else
                            5<=x<=18 and 5<=y<=18 and not (9<=x<=14 and 9<=y<=14) if shape == 3 else
                            (((2<=x<=7 or 16<=x<=21) and 7<=y<=16) or (y==11 and 7<=x<=16)))
                        mask.append(inside)
                ground, fill = (1 if shape == 5 else 3 if shape == 6 else 2 if park else 0), (6 if park else 4)
                p = bytearray(n*n)
                for y in range(n):
                    for x in range(n):
                        i = y*n+x
                        outline = mask[i] and (x==0 or y==0 or x==n-1 or y==n-1 or not mask[i-1] or not mask[i+1] or not mask[i-n] or not mask[i+n])
                        p[i] = ground if not mask[i] else fill+1 if outline else fill
                        if shape == 7: p[i] = (x+y)&1
                        if shape == 8: p[i] = int(x==11 or y==11)
                        if shape == 9: p[i] = 4 if y>=12 else int(x>=11)
                        if shape == 10: p[i] = int(x>=11)
                yield f'palette-{int(park)}-shape-{shape}-orientation-{orientation}', bytes(p), n, n
    p = bytearray(128*128)
    for k in range(4096):
        x,y=(k%64)*2,(k//64)*2
        for j in range(2):
            for i in range(2): p[(y+j)*128+x+i]=(k>>(3*(j*2+i)))&7
    yield 'all-4096-central-material-patterns', bytes(p),128,128
    # Independent, disjoint 4x4 halos containing every binary pattern and randomized
    # triple-band, invalid multimat, road/building and water/building neighborhoods.
    rng = random.Random(20261103)
    for label, count in [('all-binary-halos', 65536), ('random-band-halos', 65536), ('random-all-material-halos', 16384)]:
        columns = 256; rows = (count+columns-1)//columns; w,h = columns*6,rows*6
        p = bytearray(w*h)
        for k in range(count):
            x,y = k%columns*6+1,k//columns*6+1
            for j in range(4):
                for i in range(4):
                    p[(y+j)*w+x+i] = ((k>>(j*4+i))&1 if label=='all-binary-halos' else
                        rng.choice((0,4,5)) if label=='random-band-halos' else rng.randrange(8))
        yield label, bytes(p), w,h

def main():
    OUT.mkdir(parents=True,exist_ok=True)
    scenes = [(f'cached-{i:02}', ROOT/f'output/map-edge-bridge/cached-real/cached-{i:02}/pixels.idx') for i in range(1,6)]
    scenes += [(f'fresh-{n}',ROOT/f'output/map-edge-bridge/fresh-replay/five-current/{n}/candidate.raw') for n in ('02-low-density','03-diagonal')]
    reports=[]; checks=[]
    frozen_before = {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in FROZEN.glob('C-*.u16')}
    with tempfile.TemporaryDirectory(prefix='dense-swift-') as tmp:
        tmp=Path(tmp); swift=tmp/'swift'; c=tmp/'reference'
        run(['swiftc','-O','-module-cache-path',tmp/'module-cache',HERE/'DenseMapGeometry.swift',HERE/'main.swift','-o',swift])
        run(['c++','-std=c++11','-O2',HERE/'reference.cpp','-o',c])
        run([c,'--selfcheck'])
        lut=json.loads(run([swift,'--selfcheck']))
        for name,path in scenes:
            target=OUT/f'C-{name}.u16'
            timing=json.loads(run([swift,path,target,1200,1200]))
            raw=target.read_bytes(); frozen=(FROZEN/f'C-{name}.u16').read_bytes()
            assert raw==frozen, name+' frozen C bytes mismatch'
            direct=tmp/'direct.u16'
            direct_timing=json.loads(run([swift,path,direct,1200,1200,'--direct']))
            assert direct.read_bytes()==raw, name+' direct/LUT bytes mismatch'
            words=array('H');words.frombytes(raw)
            import sys
            if sys.byteorder!='little': words.byteswap()
            assert helper.decode_centers(words)==path.read_bytes()
            packed=zlib.compress(helper.rle16(words),1)
            assert packed==(FROZEN/f'C-{name}.rle.zlib').read_bytes()
            restored=b''.join(struct.pack('<H',word)*count for count,word in struct.iter_unpack('<HH',zlib.decompress(packed)))
            assert restored==raw
            (OUT/f'C-{name}.rle.zlib').write_bytes(packed)
            legacy_path=path.with_name('base.bin' if name.startswith('cached') else 'candidate.bin')
            assert helper.decode_legacy(legacy_path.read_bytes())==path.read_bytes()
            total=legacy_path.stat().st_size+len(packed)+32
            assert total<=480000
            reports.append(dict(scene=name,rawBytes=len(raw),sha256=hashlib.sha256(raw).hexdigest(),frozenCByteIdentity=True,directSwiftByteIdentity=True,originalCentersExact=True,legacyFullRLEBytes=legacy_path.stat().st_size,compressedTailBytes=len(packed),fullRLEPlusTailPlus32=total,headroom=480000-total,**timing,directMedianEncodeMS=direct_timing['medianEncodeMS']))
            print(name, timing['medianEncodeMS'], total, flush=True)
        for name,p,w,h in synthetic():
            src=tmp/'synthetic.idx';src.write_bytes(p)
            expected=tmp/'c.u16';actual=tmp/'swift.u16';direct=tmp/'direct.u16'
            run([c,src,expected,w,h]);run([swift,src,actual,w,h]);run([swift,src,direct,w,h,'--direct'])
            assert expected.read_bytes()==actual.read_bytes()==direct.read_bytes(), name+' C/Swift word mismatch'
            checks.append(dict(name=name,dimensions=[w,h],bytes=actual.stat().st_size,sha256=hashlib.sha256(actual.read_bytes()).hexdigest(),CAndDirectAndLUTByteIdentity=True))
    assert frozen_before=={p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in FROZEN.glob('C-*.u16')}
    report=dict(hostOnly=True,productionIntegration=False,host=platform.platform(),compiler=run(['swiftc','--version']).strip(),lookup=lut,scenes=reports,synthetics=checks,limitations=['Phone CPU unmeasured','Independent device-side shape/material decoder not implemented','Fractional rendering and topology unmeasured','RLE and zlib transport checks use the existing Python standard-library helper; only dense word generation is ported to Swift','Timing includes input validation and output word allocation; excludes file IO, table initialization, packing and compression','Lookup capacity reports element backing capacity; allocator metadata and two Array headers are additional'])
    (OUT/'report.json').write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps(lut))

if __name__=='__main__': main()
