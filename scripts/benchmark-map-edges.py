#!/usr/bin/env python3
"""Generate/build one isolated real-map edge diagnostic; never upload or open serial."""
import argparse
import importlib.util
import json
from pathlib import Path
import re
import shutil
import struct
import subprocess
import sys
import zlib

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'firmware/boards/175/MotoNav'
OUTPUT = ROOT / 'output/map-edge-bridge/device-bench'
MAX_PACKET = 480000
MAX_METADATA = 512 * 1024


def fnv(data):
    value = 2166136261
    for byte in data:
        value = ((value ^ byte) * 16777619) & 0xffffffff
    return value


def validate_scene(base, edge):
    if len(base) + len(edge) > MAX_PACKET:
        raise ValueError('base+edge exceeds 480000 bytes')
    if len(base) < 16:
        raise ValueError('truncated raster header')
    _, _, _, width, height, flags = struct.unpack_from('<HiiHHH', base)
    if width != 1200 or height != 1200:
        raise ValueError('requires the complete original 1200x1200 source grid')
    if flags & 0xb000 or not flags & 0x3fff:
        raise ValueError('unsupported raster flags, palette or resolution')
    count, pos = 0, 16
    while pos < len(base) and count < width * height:
        value = base[pos]
        pos += 1
        run = (value >> 4) + 1
        if value >> 4 == 15:
            if pos == len(base):
                raise ValueError('truncated raster run')
            run = 16 + base[pos]
            pos += 1
        if value & 15 > (7 if flags & 0x4000 else 3) or run > width * height - count:
            raise ValueError('invalid raster material or run length')
        count += run
    if count != width * height or pos != len(base):
        raise ValueError('incomplete raster or unexpected raster tail')
    if len(edge) < 24:
        raise ValueError('truncated EDGE header')
    magic, version, options, ew, eh, dictionary_count, tiles, values, checksum = struct.unpack_from('<4sBBHHHIII', edge)
    if (magic, version, ew, eh, tiles) != (b'EDGE', 1, width, height, 5625) or options not in (0, 1):
        raise ValueError('invalid EDGE header')
    if (options == 0 and dictionary_count) or (options == 1 and not 1 <= dictionary_count <= 256):
        raise ValueError('invalid EDGE dictionary count')
    metadata = tiles * (52 if options == 0 else 36) + (values * 2 if options == 0 else values + dictionary_count * 2)
    if metadata > MAX_METADATA:
        raise ValueError('complete decoded edge metadata exceeds 512 KiB')
    if fnv(edge[24:]) != checksum:
        raise ValueError('invalid EDGE checksum')
    expected = tiles * 32 + (values * 2 if options == 0 else dictionary_count * 2 + values)
    payload = edge[24:]
    if options == 1:
        inflater = zlib.decompressobj()
        try:
            payload = inflater.decompress(payload, expected + 1)
        except zlib.error as exc:
            raise ValueError('invalid EDGE zlib stream') from exc
        if not inflater.eof or inflater.unused_data or inflater.unconsumed_tail:
            raise ValueError('invalid EDGE zlib length or trailing data')
    if len(payload) != expected:
        raise ValueError('invalid EDGE payload length')
    masks = struct.unpack_from('<' + 'H' * (tiles * 16), payload)
    if sum(mask.bit_count() for mask in masks) != values:
        raise ValueError('EDGE mask/value count mismatch')
    word_count = values if options == 0 else dictionary_count
    words = struct.unpack_from('<' + 'H' * word_count, payload, tiles * 32)
    if any(not 1 <= word >> 11 <= 28 for word in words):
        raise ValueError('invalid EDGE material pair')
    if options == 1 and any(index >= dictionary_count for index in payload[tiles * 32 + dictionary_count * 2:]):
        raise ValueError('invalid EDGE dictionary index')
    return dict(width=width, height=height, baseBytes=len(base), edgeBytes=len(edge),
                totalBytes=len(base) + len(edge), metadata=metadata, values=values, codec=options, dictionaryCount=dictionary_count)


def replace_once(text, old, new):
    if text.count(old) != 1:
        raise ValueError('production renderer/setup anchor changed; refusing ambiguous injection')
    return text.replace(old, new, 1)


def assets(base, edge, scene):
    raw = base + edge
    compressed = zlib.compress(raw, 9)
    rows = [','.join(f'0x{v:02x}' for v in compressed[i:i + 24]) for i in range(0, len(compressed), 24)]
    return ('#pragma once\n#include <stdint.h>\n'
            f'static constexpr unsigned edgeBenchScene={scene};\n'
            f'static constexpr size_t edgeBenchBaseBytes={len(base)},edgeBenchRawBytes={len(raw)};\n'
            f'static constexpr uint32_t edgeBenchRawFNV=0x{fnv(raw):08x}u;\n'
            'static const uint8_t edgeBenchCompressed[] PROGMEM = {\n' + ',\n'.join(rows) + '\n};\n')


RUNTIME = r'''#pragma once
#include "EdgeBenchAssets.h"
#include "EdgeBenchDeviceBenchmark.h"
static bool edgeBenchInflate(const uint8_t *input,size_t inputBytes,uint8_t *output,size_t outputBytes){
  auto *inflater=static_cast<tinfl_decompressor *>(ps_malloc(sizeof(tinfl_decompressor)));
  if(!inflater)return false;
  tinfl_init(inflater);size_t consumed=inputBytes,produced=outputBytes;
  const auto status=tinfl_decompress(inflater,input,&consumed,output,output,&produced,
      TINFL_FLAG_PARSE_ZLIB_HEADER|TINFL_FLAG_USING_NON_WRAPPING_OUTPUT_BUF);
  free(inflater);return status==TINFL_STATUS_DONE && consumed==inputBytes && produced==outputBytes;
}
static void edgeBenchMemory(const char *stage){
  Serial.printf("EDGE BENCH memory stage=%s internal=%u psram=%u\n",stage,
      unsigned(heap_caps_get_free_size(MALLOC_CAP_INTERNAL|MALLOC_CAP_8BIT)),
      unsigned(heap_caps_get_free_size(MALLOC_CAP_SPIRAM|MALLOC_CAP_8BIT)));
}
static void runMapEdgeBenchmark(){
  delay(8000); // Diagnostic capture window, outside every timed rasterRows call.
  Serial.printf("EDGE BENCH begin scene=%u\n",edgeBenchScene);
  edgeBenchMemory("before-map");
  if(!helperTask){Serial.println("EDGE BENCH summary status=FAIL reason=dual-core-worker");return;}
  auto *raw=static_cast<uint8_t *>(ps_malloc(edgeBenchRawBytes));
  if(!raw || !edgeBenchInflate(edgeBenchCompressed,sizeof(edgeBenchCompressed),raw,edgeBenchRawBytes) ||
      rasterEdgeChecksum(raw,edgeBenchRawBytes)!=edgeBenchRawFNV || edgeBenchRawBytes>480000){
    free(raw);Serial.println("EDGE BENCH summary status=FAIL reason=asset-integrity");return;
  }
  RasterHeader header={};
  bool valid=rasterCheck(raw,edgeBenchBaseBytes,header,RASTER_MAX_PX,RASTER_BUF_BYTES) &&
      header.width==1200 && header.height==1200 && header.dataEnd==edgeBenchBaseBytes && !header.palette;
  rasterBuildingCarryOn=false;rasterBackValid=false;
  valid=valid && parseRaster(raw,edgeBenchBaseBytes) &&
      rasterEdgeDecode(raw+edgeBenchBaseBytes,edgeBenchRawBytes-edgeBenchBaseBytes,header.width,header.height,edgeBenchView,RASTER_EDGE_MAX_BYTES,edgeBenchInflate);
  free(raw);rasterBackValid=false;
  if(!valid){rasterEdgeRelease(edgeBenchView);Serial.println("EDGE BENCH summary status=FAIL reason=map-decode");return;}
  const float centerX=rasX0+rasW*rasMpp*.5f,centerY=rasY0-rasH*rasMpp*.5f;
  edgeBenchMemory("before-cache");
  edgeBenchCacheReady=rasterEdgeCachePairPrepare(edgeBenchCaches,edgeBenchView,rasterBuf,header.bytes,edgeBenchView.epoch,edgeBenchExpansion);
  edgeBenchMemory("after-cache");
  Serial.printf("EDGE BENCH allocation mapmeta=%u metadata=%u cache=internal-8bit\n",
      unsigned(edgeBenchView.bytes),unsigned(rasterEdgeCacheBudget(edgeBenchView)));
  if(!edgeBenchCacheReady){
    edgeBenchEnabled=false;drawRasterMap(centerX,centerY,.38f,1,0);
    rasterEdgeRelease(edgeBenchView);Serial.println("EDGE BENCH summary status=FAIL reason=cache-budget-allocation baseline=rendered");return;
  }
  const int angles[]={0,45,90};const float scales[]={.38f,.6f};
  unsigned cases=0,failures=0,unchanged=0;
  for(int theme=1;theme<=3;theme++)for(int night=0;night<2;night++)
    for(int angle:angles)for(float scale:scales){
      themeIdx=theme;nightOn=night;edgeBenchEnabled=false;
      const float radians=angle*(PI/180.0f);
      drawRasterMap(centerX,centerY,scale,cosf(radians),sinf(radians));
      RasterEdgeBenchmarkResult result;
      const bool ran=rasterEdgeDeviceBenchmark(edgeBenchEnabled,result);
      ++cases;failures+=!ran || !result.withinBudget;unchanged+=ran && !result.changedPixels;
      Serial.printf("EDGE BENCH scene=%u theme=%d night=%d theta=%d scale=%.2f bytes=%u metadata=%u base_us=%u edge_us=%u changed=%u pixels=%u budget=%s\n",
          edgeBenchScene,theme,night,angle,scale,unsigned(edgeBenchRawBytes),unsigned(rasterEdgeCacheBudget(edgeBenchView)),
          result.baselineMedianUs,result.edgeMedianUs,result.changedPixels,result.comparedPixels,
          ran?(result.withinBudget?"PASS":"FAIL"):"ERROR");
      delay(1);
    }
  edgeBenchEnabled=false;for(auto &cache:edgeBenchCaches)cache.release();edgeBenchCacheReady=false;rasterEdgeRelease(edgeBenchView);
  Serial.printf("EDGE BENCH summary scene=%u cases=%u failures=%u unchanged=%u status=%s\n",
      edgeBenchScene,cases,failures,unchanged,failures?"FAIL":(unchanged==cases?"INCONCLUSIVE":"PASS"));
}
'''


def generate(destination, base, edge, scene):
    info = validate_scene(base, edge)
    cache_budget = info['metadata'] + 2 * (64 * (512 + 8) + 5625) + 1024 + 256
    if cache_budget > MAX_METADATA:
        raise ValueError('map plus two worker caches exceeds 512 KiB')
    info['cacheBudgetUpperBound'] = cache_budget
    # Source-controlled sketch only; never copy external config, credentials or symlink targets.
    secret = re.compile(rb'-----BEGIN (?:[A-Z ]+ )?PRIVATE KEY-----|AKIA[0-9A-Z]{16}|AIza[0-9A-Za-z_-]{30,}|(?:api[_-]?key|password|secret[_-]?key)\s*=\s*["\x27][^"\x27\r\n]{8,}', re.I)
    for path in SOURCE.rglob('*'):
        if path.is_symlink() or (path.is_file() and (path.suffix.lower() in {'.key', '.pem', '.p12', '.pfx'} or secret.search(path.read_bytes()))):
            raise ValueError('refusing sketch copy containing a symlink or credential-like file')
    if destination.exists():
        shutil.rmtree(destination)
    shutil.copytree(SOURCE, destination)
    renderer_path = destination / 'src/map/RasterRenderer.h'
    renderer = renderer_path.read_text()
    renderer = replace_once(renderer, '#pragma once', '#pragma once\n#define RASTER_EDGE_ALLOC ps_malloc\n#define RASTER_EDGE_CACHE_ALLOC(n) heap_caps_malloc((n),MALLOC_CAP_INTERNAL|MALLOC_CAP_8BIT)\n#include "../../RasterEdge.h"\nstatic RasterEdgeView edgeBenchView;\nstatic RasterEdgeLUT edgeBenchLUT;\nstatic RasterEdgeBaseLUT edgeBenchExpansion;\nstatic RasterEdgeCache edgeBenchCaches[2];\nstatic bool edgeBenchEnabled=false,edgeBenchCacheReady=false;')
    renderer = replace_once(renderer, '  const float R = 212;', '  auto &edgeCache=edgeBenchCaches[xPortGetCoreID()];\n  const bool edges=edgeBenchEnabled && edgeBenchCacheReady && edgeBenchLUT.ready && edgeCache.epoch==edgeBenchView.epoch && edgeCache.sourceEpoch==edgeBenchView.epoch && edgeCache.source==rasterBuf && !useBack && !RM.pix2 && !rasHasPal && !rasterViceValid;\n  uint32_t edgeLastTile=UINT32_MAX;const uint16_t *edgeDense=nullptr;\n  const float R = 212;')
    start = renderer.index('      uint8_t idx = 0;')
    end = renderer.index('      row[x] = color;', start)
    baseline = renderer[start:end].replace('uint16_t color=pal[idx];', 'color=pal[idx];')
    dense_path = r'''      uint16_t color;
      if(edges){
        color=pal[0];
        if((uint32_t)ui<(uint32_t)rasW && (uint32_t)vi<(uint32_t)rasH){
          const uint32_t tile=(vi>>4)*rasBW+(ui>>4);
          if(tile!=edgeLastTile){edgeDense=edgeCache.get(edgeBenchView,edgeBenchView.epoch,tile,edgeBenchExpansion);edgeLastTile=tile;}
          if(edgeDense){
            const uint16_t word=edgeDense[((vi&15)<<4)|(ui&15)];
            color=(word>>11)?edgeBenchLUT.color(word,U,V,pal[0]):pal[(word>>5)&15];
          }
        }
      }else{
'''
    renderer = renderer[:start] + dense_path + baseline + '      }\n' + renderer[end:]
    anchor = 'RM.cx = cx; RM.cy = cy; RM.sc = sc; RM.cs = cs; RM.sn = sn;'
    renderer = replace_once(renderer, anchor, anchor + '\n  edgeBenchLUT.prepare(RM.pal,1.0f/(sc*rasMpp),atan2f(sn,cs));')
    renderer_path.write_text(renderer)
    entry_path = destination / 'MotoNav.ino'
    entry = entry_path.read_text()
    entry = replace_once(entry, '#include "src/diagnostics/RenderBenchmarks.h"', '#include "src/diagnostics/RenderBenchmarks.h"\n#include "EdgeBenchRuntime.h"')
    entry = replace_once(entry, '  helperInit();', '  helperInit();\n  runMapEdgeBenchmark();\n  while(true){delay(1000);}')
    entry_path.write_text(entry)
    (destination / 'EdgeBenchAssets.h').write_text(assets(base, edge, scene))
    (destination / 'EdgeBenchRuntime.h').write_text(RUNTIME)
    shutil.copyfile(ROOT / 'firmware/tests/raster-edge/DeviceBenchmark.h', destination / 'EdgeBenchDeviceBenchmark.h')
    info.update(scene=scene, rawFNV=f'{fnv(base + edge):08x}', compressedBytes=len(zlib.compress(base + edge, 9)))
    (destination.parent / 'scene-manifest.json').write_text(json.dumps(info, indent=2) + '\n')
    return info


def sample_files(sample):
    canonical = sample / 'base.bin', sample / 'prototype.edge'
    if all(path.is_file() for path in canonical):
        return canonical
    bins, edges = sorted(sample.glob('*.bin')), sorted(sample.glob('*.edge'))
    if len(bins) != 1 or len(edges) != 1:
        raise ValueError('sample requires base.bin + prototype.edge, or exactly one .bin + one .edge')
    return bins[0], edges[0]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('samples', type=Path, nargs='*', help='directories containing one .bin and one .edge')
    parser.add_argument('--scene', type=int, help='1-based sample selection; required with multiple directories')
    parser.add_argument('--dense-cell', action='store_true', help='isolated frozen dense C experiment')
    parser.add_argument('--dense-tiled', action='store_true', help='dense C 16x16 resident layout; requires --dense-cell')
    parser.add_argument('--profile-stages', action='store_true', help='diagnostic old/new cache nearest versus AA; requires --local-palette')
    parser.add_argument('--local-palette', action='store_true', help='isolated exact tile palette prototype; requires probe files')
    parser.add_argument('--dry-run', action='store_true', help='validate and generate only; do not invoke compiler')
    parser.add_argument('--self-test', action='store_true', help='run host fixture checks; do not generate a device build')
    parser.add_argument('--cli', default='arduino-cli')
    parser.add_argument('--config-file', type=Path, help='existing Arduino CLI config; never copied into output')
    parser.add_argument('--jobs', type=int, default=4)
    args = parser.parse_args()
    if args.dense_tiled and not args.dense_cell:
        parser.error('--dense-tiled requires --dense-cell')
    if args.self_test:
        subprocess.run([sys.executable, str(ROOT / 'firmware/tests/raster-edge/benchmark_script_test.py')], check=True)
        return
    if not args.samples or not 1 <= args.jobs <= 32:
        parser.error('supply sample directories and jobs between 1 and 32')
    if len(args.samples) > 1 and args.scene is None:
        parser.error('select one sample with --scene 1..N to fit the 3 MiB application partition')
    scene = args.scene or 1
    if not 1 <= scene <= len(args.samples):
        parser.error('--scene must select an input sample')
    sample = args.samples[scene - 1]
    if not args.dense_cell:
        base_path, edge_path = sample_files(sample)
    if args.profile_stages and not args.local_palette:
        parser.error('--profile-stages requires --local-palette')
    output = OUTPUT.with_name('device-bench-dense-tiled' if args.dense_tiled else 'device-bench-dense') if args.dense_cell else (OUTPUT.with_name('device-bench-palette-profile' if args.profile_stages else 'device-bench-palette') if args.local_palette else OUTPUT)
    destination = output / 'MotoNav'
    if args.dense_cell:
        module_spec = importlib.util.spec_from_file_location('dense_builder', ROOT / 'firmware/tests/raster-edge/dense_builder.py')
        dense_builder = importlib.util.module_from_spec(module_spec);module_spec.loader.exec_module(dense_builder)
        info = dense_builder.generate(sys.modules[__name__], destination, sample, scene, tiled=args.dense_tiled)
    elif args.local_palette:
        module_spec = importlib.util.spec_from_file_location('local_palette_builder', ROOT / 'firmware/tests/raster-edge/local_palette_builder.py')
        palette_builder = importlib.util.module_from_spec(module_spec)
        module_spec.loader.exec_module(palette_builder)
        info = palette_builder.generate(sys.modules[__name__], destination, sample, scene, profile=args.profile_stages)
    else:
        info = generate(destination, base_path.read_bytes(), edge_path.read_bytes(), scene)
    print('EDGE BENCH generated ' + json.dumps(info, sort_keys=True), flush=True)
    if args.dry_run:
        return
    spec = importlib.util.spec_from_file_location('firmware_build', ROOT / 'firmware/build.py')
    build = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(build)
    command = [args.cli]
    if args.config_file:
        command += ['--config-file', str(args.config_file)]
    prefix_map = '-ffile-prefix-map=' + str(Path.home()) + '=/builder'
    command += ['compile', '--jobs', str(args.jobs), '--libraries', str(ROOT / 'firmware/libraries'),
                '--build-path', str(output / 'build'), '--fqbn', build.FQBN,
                '--build-property', 'compiler.c.extra_flags=' + prefix_map,
                '--build-property', 'compiler.cpp.extra_flags=' + prefix_map,
                '--build-property', 'compiler.c.elf.extra_flags=-Wl,--wrap=xTaskCreatePinnedToCore',
                '--output-dir', str(output / 'artifacts'), str(destination)]
    subprocess.run(command, check=True)
    app = output / 'artifacts/MotoNav.ino.bin'
    if not app.is_file() or app.stat().st_size > 3 * 1024 * 1024:
        raise ValueError('application image missing or exceeds 3 MiB partition')
    print(f'EDGE BENCH build scene={scene} appBytes={app.stat().st_size} uploaded=false')


if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError, subprocess.CalledProcessError) as exc:
        # Do not echo input locations or sample content in diagnostic logs.
        print('EDGE BENCH failed: ' + (str(exc) if isinstance(exc, ValueError) else type(exc).__name__), file=sys.stderr)
        sys.exit(1)
