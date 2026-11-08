"""Bounded host-only probe. No device, production files, network, or new protocol."""
from array import array
from pathlib import Path
import hashlib
import json
import math
import struct
import subprocess
import tempfile
import zlib

ROOT = Path(__file__).resolve().parents[3]
OUT = ROOT / 'output/map-edge-bridge/dense-feasibility'


def rle16(words):
    encoded = bytearray()
    previous, count = words[0], 0
    for word in words:
        if word == previous and count < 65535:
            count += 1
        else:
            encoded += struct.pack('<HH', count, previous)
            previous, count = word, 1
    encoded += struct.pack('<HH', count, previous)
    return bytes(encoded)


def decode_centers(words):
    pairs = [(0, 0)] + [(a, b) for a in range(8) for b in range(a+1, 8)]
    lut = {}
    for word in set(words):
        if word & 32768:
            lut[word] = tuple((word >> (3*i)) & 7 for i in range(4))
        elif word >> 10 == 0:
            lut[word] = (word & 7,) * 4
        else:
            a, b = pairs[word >> 10] if word >> 10 < 29 else (0, 4) if word >> 10 == 29 else (2, 6)
            angle = ((word >> 5) & 31) * math.pi / 16
            d = ((word & 31) - 16) / 32
            lut[word] = tuple((a if (side := math.cos(angle)*x + math.sin(angle)*y-d) < 0 else
                               b if word >> 10 < 29 or side >= .5*max(abs(math.cos(angle)),abs(math.sin(angle))) else b+1)
                              for y in (-.25, .25) for x in (-.25, .25))
    decoded = bytearray(1200*1200)
    for y in range(600):
        row = [lut[word] for word in words[y*600:(y+1)*600]]
        top, bottom = 2*y*1200, (2*y+1)*1200
        decoded[top:top+1200:2] = bytes(m[0] for m in row)
        decoded[top+1:top+1200:2] = bytes(m[1] for m in row)
        decoded[bottom:bottom+1200:2] = bytes(m[2] for m in row)
        decoded[bottom+1:bottom+1200:2] = bytes(m[3] for m in row)
    return bytes(decoded)


def decode_legacy(data):
    assert len(data) <= 480000 and struct.unpack_from('<HHH', data, 10) == (1200, 1200, 2000 | 0x4000)
    out, pos = bytearray(), 16
    while pos < len(data):
        value = data[pos]; pos += 1
        count = (value >> 4) + 1
        if count == 16:
            count += data[pos]; pos += 1
        assert value & 15 < 8 and len(out) + count <= 1440000
        out.extend([value & 15] * count)
    assert len(out) == 1440000
    return bytes(out)


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    scenes = [(f'cached-{n:02}', ROOT / f'output/map-edge-bridge/cached-real/cached-{n:02}/pixels.idx')
              for n in range(1, 6)]
    scenes += [(f'fresh-{name}', ROOT / f'output/map-edge-bridge/fresh-replay/five-current/{name}/candidate.raw')
               for name in ('02-low-density', '03-diagonal')]
    reports = []
    with tempfile.TemporaryDirectory(prefix='motonav-dense-') as tmp:
        exe = Path(tmp)/'probe'
        subprocess.run(['c++', '-std=c++11', '-O2', str(Path(__file__).with_name('probe.cpp')), '-o', str(exe)], check=True)
        subprocess.run([str(exe)], check=True)
        for variant, name, path in [(variant, name, path) for variant in ('A', 'B', 'C') for name, path in scenes]:
            dense = OUT / f'{variant}-{name}.u16'
            result = subprocess.run([str(exe), str(path), str(dense)] + ([variant] if variant != 'A' else []), capture_output=True, text=True, check=True)
            report = json.loads(result.stdout)
            raw = dense.read_bytes()
            words = array('H'); words.frombytes(raw)
            import sys
            if sys.byteorder != 'little':
                words.byteswap()
            source = path.read_bytes()
            decoded = decode_centers(words)
            assert decoded == source  # Full material-label equality implies every 4/8-connected topology invariant.
            rle = rle16(words)
            packed = zlib.compress(rle, 1)
            restored = array('H')
            for count, word in struct.iter_unpack('<HH', zlib.decompress(packed)):
                restored.extend([word] * count)
            assert restored == words
            (OUT / f'{variant}-{name}.rle.zlib').write_bytes(packed)
            legacy_path = path.with_name('base.bin' if name.startswith('cached-') else 'candidate.bin')
            legacy = legacy_path.stat().st_size
            assert decode_legacy(legacy_path.read_bytes()) == source
            categories = dict(roadWaterBuilding=0, exactBuildingTriple=0, twoMaterialRemaining=0, otherMultimaterial=0)
            for key, value in report['fallbackHaloMaterialSets'].items():
                mask = int(key)
                category = ('roadWaterBuilding' if mask & 0x0a and mask & 0xf0 else 'exactBuildingTriple' if mask in (0x31, 0xc4)
                            else 'twoMaterialRemaining' if mask.bit_count() == 2 else 'otherMultimaterial')
                categories[category] += value
            assert sum(categories.values()) == report['fallback']
            report.update(variant=variant, scene=name, source=str(path.relative_to(ROOT)), legacyFullRLEPath=str(legacy_path.relative_to(ROOT)), legacyFullRLEExactSource=True, sourceSHA256=hashlib.sha256(source).hexdigest(),
                          decodedSHA256=hashlib.sha256(decoded).hexdigest(), decodedBytes=len(raw), fallbackCategories=categories, legacyFullRLEBytes=legacy,
                          legacyPlusDenseTailBytes=legacy+32+len(packed), legacyPlusDenseTailBudgetPassed=legacy+32+len(packed)<=480000,
                          rleBytes=len(rle), rleZlibBytes=len(packed), rawZlibBytes=len(zlib.compress(raw, 1)),
                          denseTailWithHeaderBytes=32+len(packed), denseTailOnlyBudgetPassed=32+len(packed)<=480000,
                          changedMaterialMaskPixels=0, changedRoadWaterBuildingPixels=0,
                          topologyGate='PASS: every original 2m material label identical, hence same 4/8 connectivity and holes',
                          outerSilhouettePercent=round(report['outerAccepted']/max(1,report['outerMixed'])*100,3),
                          planePercentAll=round(report['plane']/360000*100, 3),
                          planePercentMixed=round(report['plane']/max(1,report['plane']+report['fallback'])*100, 3))
            reports.append(report)
            print(json.dumps(report), flush=True)
    report = dict(hostOnly=True, dimensions=[600,600], mpp=4, coveredMeters=[2400,2400],
                  decodedBytes=720000, previous1200Squared4bitBytes=720000,
                  proposedBitLayout='bit15 fallback: four 3bit original materials in lower12; else pair5<<10 | normal5<<5 | offset5; pair0 low3 pure',
                  offsetUnits='4m cell units: (offset-16)/32, [-.5,.46875]; unrepresentable offsets fallback',
                  bandCodes='C only: pair29 ground0/outline5/fill4, pair30 park2/outline7/fill6; inner d = outer d + .5*max(abs(nx),abs(ny)) in4m units; all16 exact plus both boundary residuals <=.14',
                  evidence='4x4 original2m halo includes every constituent 3x3; two materials only, midpoint line residual <=.14 cell units, all16 centers exact, A central3:1/checker fallback; B allows3:1 but rejects globally nonstraight4x4; both road-water/building contacts fallback',
                  rejectionOrder=['more_than_two_center_materials','central_3to1_or_checker','map_border','road_water_building_contact','halo_material_or_support','quantized_line_residual_or_center'],
                  projectedRendererLUTBytes=32*2*2+32*4+29*2+28*257*2+9*257+32*4+6,
                  projectedRendererLUTBudgetPassed=True,
                  topologyLimitation='Discrete 2m topology certified; fractional AA or multi-cell seam appearance has not been rendered or certified',
                  CPUStatus='UNMEASURED: one uint16 memory read is structurally possible; <=10% board CPU gate remains open',
                  packetLimitation='legacyPlusDenseTailBytes preserves complete valid base.bin/candidate.bin RLE prefix plus dense tail. 32-byte allowance is illustrative only; RLE uint16 count+word and zlib are host encoding experiments, not protocol-compatible packets',
                  selfchecks='C morphological cardinal-one-cell outline: axis and diagonal acceptance; L, courtyard inner/outer corners, narrow bridge and road/water rejection. all 4096 2x2 fallback combinations; axis lines; L hard corner; courtyard; narrow crossing; checker; triple junction; diagonal; independent Python decode; RLE-zlib roundtrip',
                  scenes=reports)
    assert report['projectedRendererLUTBytes'] < 512*1024
    (OUT/'report.json').write_text(json.dumps(report, indent=2)+'\n')


if __name__ == '__main__':
    main()
