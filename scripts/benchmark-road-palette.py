#!/usr/bin/env python3
"""Compile-only isolated stable-render diagnostic. Never flashes or opens serial."""
import argparse, hashlib, importlib.util, json, re, shutil, subprocess, tempfile, zlib
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
SOURCE=ROOT/'firmware/boards/175/MotoNav'
OUTPUT=ROOT/'output/map-edge-bridge/device-bench-road-palette'
def sha(data): return hashlib.sha256(data).hexdigest()
def fnv(data):
    value=2166136261
    for b in data: value=((value^b)*16777619)&0xffffffff
    return value
def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--dry-run',action='store_true')
    parser.add_argument('--multitone',action='store_true',help='compare frozen v1 renderer/map with current v2 renderer/map')
    parser.add_argument('--config-file',type=Path,default=Path('/private/tmp/motonav-esp32-toolchain/config.yaml'))
    args=parser.parse_args()
    output_base=ROOT/'output/road-multitone/device-bench' if args.multitone else OUTPUT
    sample=ROOT/'output/map-edge-bridge/road-palette-qa/06-mingbo'
    packets=([(sample/'building.bin').read_bytes(),(ROOT/'output/map-edge-bridge/road-multitone-export/06-mingbo/building.bin').read_bytes()]
             if args.multitone else [(sample/name).read_bytes() for name in ['old-building.bin','building.bin']])
    assert packets[0][:14]==packets[1][:14]
    assert packets[0][14:16]==bytes.fromhex('d087' if args.multitone else 'd047') and packets[1][14:16]==bytes.fromhex('d087')
    versions=[1,2] if args.multitone else [0,1]
    for packet,version in zip(packets,versions):
        if version: assert packet[44:48]==bytes([0x4e,0x4d,0x10|version,0x52])
    assert all(len(p)<=480000 for p in packets)
    # Same source-only copy boundary used by benchmark-map-edges.py.
    secret=re.compile(rb'-----BEGIN (?:[A-Z ]+ )?PRIVATE KEY-----|AKIA[0-9A-Z]{16}|AIza[0-9A-Za-z_-]{30,}|(?:api[_-]?key|password|secret[_-]?key)\s*=\s*["\x27][^"\x27\r\n]{8,}',re.I)
    for path in SOURCE.rglob('*'):
        if path.is_symlink() or (path.is_file() and (path.suffix.lower() in {'.key','.pem','.p12','.pfx'} or secret.search(path.read_bytes()))):
            raise ValueError('refusing sketch copy containing a symlink or credential-like file')
    output_base.mkdir(parents=True,exist_ok=True)
    run=Path(tempfile.mkdtemp(prefix='run-',dir=output_base))
    destination=run/'MotoNav'
    shutil.copytree(SOURCE,destination)
    original=(destination/'MotoNav.ino').read_text()
    assert 'esp_task_wdt_reset();' in original
    assert original.index('helperInit();')<original.index('esp_task_wdt_add(')
    entry=original.replace('#include "src/diagnostics/RenderBenchmarks.h"','#include "src/diagnostics/RenderBenchmarks.h"\n#include "RoadPaletteBenchDeviceBenchmark.h"')
    assert entry!=original and entry.count('  helperInit();')==1
    entry=entry.replace('  helperInit();','  helperInit();\n  runRoadPaletteBenchmark();\n  while(true){delay(1000);}')
    (destination/'MotoNav.ino').write_text(entry)
    runtime=ROOT/'firmware/tests/raster-road-palette/DeviceBenchmark.h'
    shutil.copyfile(runtime,destination/'RoadPaletteBenchDeviceBenchmark.h')
    if args.multitone:
        shutil.copyfile(ROOT/'firmware/tests/raster-road-palette/fixtures/RasterRowsBefore.h',destination/'RoadPaletteBaselineRows.h')
    raw=b''.join(packets);compressed=zlib.compress(raw,9)
    assets='#pragma once\n#define MPAL_BENCH_BASELINE_ROWS '+str(int(args.multitone))+'\n'
    assets+='static constexpr uint8_t paletteBenchVersions[2]={'+','.join(map(str,versions))+'};\n'
    assets+='static constexpr size_t paletteBenchRawBytes='+str(len(raw))+';\n'
    assets+='static constexpr size_t paletteBenchWireBytes[2]={'+','.join(str(len(p)) for p in packets)+'};\n'
    assets+=f'static constexpr uint32_t paletteBenchFNV=0x{fnv(raw):08x}u;\n'
    assets+='static const uint8_t paletteBenchCompressed[] PROGMEM={\n'+',\n'.join(','.join(str(v) for v in compressed[i:i+32]) for i in range(0,len(compressed),32))+'\n};\n'
    (destination/'RoadPaletteBenchAssets.h').write_text(assets)
    renderer=Path('src/map/RasterRenderer.h')
    assert (SOURCE/renderer).read_bytes()==(destination/renderer).read_bytes()
    source_hashes={str(p.relative_to(SOURCE)):sha(p.read_bytes()) for p in SOURCE.rglob('*') if p.is_file()}
    manifest={'sourceHEAD':subprocess.check_output(['git','rev-parse','HEAD'],cwd=ROOT,text=True).strip(),'sourceHashes':source_hashes,'runtimeSHA256':sha(runtime.read_bytes()),'entryBeforeSHA256':sha(original.encode()),'entryAfterSHA256':sha(entry.encode()),'assetRawSHA256':sha(raw),'wireBytes':[len(p) for p in packets],'sourceDecodedBytes':[720000,720000],'compressedBytes':len(compressed),'injection':'setup after helperInit before BLE and before TWDT subscription; loop WDT feed present','rendererUnmodified':True,'cases':36,'samplesPerMode':31,'warmupsPerMode':8,'baselineFormula':'median(old plain 8-material production rasterRows + parallelRows barrier), new semantic16 same full source/world pose/scale/angle; selection+palette setup outside timer; pass new*10<=old*11','timingScope':'stable two-core resident source rendering only; no decompress, flash IO, transfer or palette preparation timed','G':'NOT_RUN','deviceRun':False,'uploaded':False}
    if args.multitone:
        manifest.update(comparison='v1-before-renderer-vs-v2-current-renderer',baselineFormula='frozen pre-multitone rasterRows with v1 map vs current rasterRows with v2 map; same pose and paired order; pass new*10<=old*11',baselineRowsSHA256=sha((destination/'RoadPaletteBaselineRows.h').read_bytes()))
    manifest.update(paths={name:str(path.resolve()) for name,path in {'run':run,'sketch':destination,'build':run/'build','artifacts':run/'artifacts','manifest':run/'manifest.json'}.items()})
    (run/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
    if args.dry_run:
        print(json.dumps({'paths':manifest['paths']},indent=2))
        return
    spec=importlib.util.spec_from_file_location('firmware_build',ROOT/'firmware/build.py');build=importlib.util.module_from_spec(spec);spec.loader.exec_module(build)
    prefix='-ffile-prefix-map='+str(Path.home())+'=/builder'
    command=['arduino-cli','--config-file',str(args.config_file),'compile','--jobs','4','--libraries',str(ROOT/'firmware/libraries'),'--build-path',str(run/'build'),'--fqbn',build.FQBN,'--build-property','compiler.c.extra_flags='+prefix,'--build-property','compiler.cpp.extra_flags='+prefix,'--build-property','compiler.c.elf.extra_flags=-Wl,--wrap=xTaskCreatePinnedToCore','--output-dir',str(run/'artifacts'),str(destination)]
    subprocess.run(command,check=True)
    app=run/'artifacts/MotoNav.ino.bin';assert app.stat().st_size<=3*1024*1024
    manifest.update(appBytes=app.stat().st_size,appSHA256=sha(app.read_bytes()))
    (run/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
    print(json.dumps({k:v for k,v in manifest.items() if k!='sourceHashes'},indent=2))
if __name__=='__main__':main()
