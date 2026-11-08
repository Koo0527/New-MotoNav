"""Standalone diagnostic authoring, imported only by --local-palette."""
import json
import hashlib
from pathlib import Path
import shutil
import struct
import zlib


def validate(low, meta):
    tiles = 5625
    if len(low) != tiles * 128 or len(meta) < (tiles + 1) * 4:
        raise ValueError('invalid local palette dimensions')
    offsets = struct.unpack_from('<' + 'I' * (tiles + 1), meta)
    header = (tiles + 1) * 4
    if offsets[0] or offsets[-1] != len(meta) - header:
        raise ValueError('invalid local palette offsets')
    for tile in range(tiles):
        begin, end = offsets[tile:tile+2]
        if begin > end or end > len(meta)-header or end-begin < 8:
            raise ValueError('invalid local palette record')
        k, kind, reserved = struct.unpack_from('<HBB', meta, header+begin)
        if not 1 <= k <= 40 or kind != int(k > 16) or reserved or end-begin != 4+k*4+(64 if kind else 0):
            raise ValueError('unsupported local palette width/record')
        words = struct.unpack_from('<'+'I'*k, meta, header+begin+4)
        if list(words) != sorted(set(words)) or any(v>>16 > 7 or (v&65535 and not 1 <= (v&65535)>>11 <= 28) for v in words):
            raise ValueError('invalid local palette key')
        for p in range(256):
            index = (low[tile*128+p//2] >> ((p&1)*4)) & 15
            if kind:
                index |= ((meta[header+begin+4+k*4+p//4] >> ((p&3)*2)) & 3) << 4
            if index >= k:
                raise ValueError('invalid local palette pixel index')
    # Conservative portable contexts + shared coverage/color LUT, not hidden overhead.
    budget = len(meta) + 2*36*232 + 2*128 + 20000 + 128
    if budget > 524288:
        raise ValueError('local palette + caches + color LUT exceeds 512 KiB')
    return budget


def array(name, data):
    lines = [','.join(f'0x{v:02x}' for v in data[p:p+24]) for p in range(0,len(data),24)]
    return f'static const uint8_t {name}[] PROGMEM = {{\n' + ',\n'.join(lines) + '\n};\n'


def generate(common, destination, sample, scene, profile=False):
    original = (sample/'base.bin').read_bytes()
    edge = (sample/'prototype.edge').read_bytes()
    compact = (sample/'compact-base.bin').read_bytes()
    low, meta = (sample/'palette-probe-low.idx').read_bytes(), (sample/'palette-probe-meta.bin').read_bytes()
    budget = validate(low, meta) + (2*232+64 if profile else 0)
    if budget>524288:
        raise ValueError('profile caches and diagnostic counters exceed 512 KiB')
    side = zlib.compress(low+meta, 6)
    wire = len(compact)+24+len(side)
    if wire > 480000:
        raise ValueError('compact base + exact local palette exceeds 480000 bytes')
    info = common.generate(destination, original, edge, scene)
    source = (common.SOURCE/'src/map/RasterRenderer.h').read_text()
    begin = source.index('void __attribute__((optimize("O3"))) rasterRows(')
    end = source.index('static inline uint16_t vicePatchColor', begin)
    original_fn = source[begin:end]
    baseline_hash=hashlib.sha256(original_fn[original_fn.index('{'):].encode()).hexdigest()
    baseline = original_fn.replace('rasterRows(', 'rasterRowsBaseline(', 1).replace('void __attribute__', 'void __attribute__((noinline)) __attribute__',1)
    palette = original_fn.replace('rasterRows(', 'rasterRowsLocalPalette(',1).replace('void __attribute__', 'void __attribute__((noinline)) __attribute__',1)
    palette = common.replace_once(palette, '  const float R = 212;', '  auto &cache=paletteCaches[xPortGetCoreID()];\n  uint32_t lastTile=UINT32_MAX;const LocalPaletteEntry *entry=nullptr;\n  const float R = 212;')
    start = palette.index('      uint8_t idx = 0;')
    stop = palette.index('      row[x] = color;',start)
    hot = r'''      uint16_t color=pal[0];
      if((uint32_t)ui<(uint32_t)rasW && (uint32_t)vi<(uint32_t)rasH){
        const uint32_t tile=(vi>>4)*rasBW+(ui>>4),pos=((vi&15)<<4)|(ui&15);
        if(tile!=lastTile){entry=cache.get(paletteView,tile);lastTile=tile;}
        if(entry){
          const uint8_t packed=paletteView.low[tile*128+(pos>>1)];
          unsigned index=(packed>>((pos&1)*4))&15;
          if(entry->kind)index|=((entry->high[pos>>2]>>((pos&3)*2))&3)<<4;
          const uint32_t value=entry->value[index];
          color=(value>>31)?uint16_t(value):paletteLUT.color(uint16_t(value),U,V,pal[0]);
        }
      }
'''
    palette = palette[:start]+hot+palette[stop:]
    wrapper = r'''void rasterRows(int y0,int y1,int step){
  if(paletteEnabled && paletteReady && paletteLUT.ready && !RM.pix2 && !rasHasPal && !rasterViceValid &&
     paletteCaches[0].epoch==paletteView.epoch && paletteCaches[1].epoch==paletteView.epoch)
    rasterRowsLocalPalette(y0,y1,step);
  else rasterRowsBaseline(y0,y1,step);
}

'''
    injected = source[:begin]+baseline+palette+wrapper+source[end:]
    globals_ = '''#pragma once
#define RASTER_EDGE_CACHE_ALLOC(n) heap_caps_malloc((n),MALLOC_CAP_INTERNAL|MALLOC_CAP_8BIT)
#include "../../LocalPalette.h"
static LocalPaletteView paletteView;
static LocalPaletteCache paletteCaches[2];
static RasterEdgeLUT paletteLUT;
static bool paletteEnabled=false,paletteReady=false;
'''
    injected = common.replace_once(injected, '#pragma once', globals_)
    anchor = 'RM.cx = cx; RM.cy = cy; RM.sc = sc; RM.cs = cs; RM.sn = sn;'
    injected = common.replace_once(injected, anchor, anchor+'\n  paletteLUT.prepare(RM.pal,1.0f/(sc*rasMpp),atan2f(sn,cs));')
    if profile:
        injected = profile_renderer(injected,palette,wrapper)
    (destination/'src/map/RasterRenderer.h').write_text(injected)
    header = (Path(__file__).parent/'LocalPalette.h').read_text().replace('#include "../../boards/175/MotoNav/RasterEdge.h"','#include "RasterEdge.h"')
    if profile:
        header='#define LOCAL_PALETTE_KEEP_BASE 1\n'+header
        header=header.replace('LOCAL_PALETTE_SLOTS=36','LOCAL_PALETTE_SLOTS=37')
        header=header.replace(' const LocalPaletteEntry *get(', ' template<unsigned Slots=LOCAL_PALETTE_SLOTS> const LocalPaletteEntry *get(')
        header=header.replace('tile%LOCAL_PALETTE_SLOTS','tile%Slots')
        header=header.replace('e.value[i]=(key&65535)?(key&65535):','e.value[i]=(key&65535)?key:')
    (destination/'LocalPalette.h').write_text(header)
    asset = '#pragma once\n#include <stdint.h>\n'
    asset += f'static constexpr unsigned paletteScene={scene};\n'
    asset += f'static const char paletteBaselineSHA[]="{baseline_hash}";\n'
    asset += f'static constexpr size_t paletteBaseBytes={len(compact)},paletteMetaBytes={len(meta)},paletteSideBytes={len(low)+len(meta)},paletteWireBytes={wire};\n'
    asset += f'static constexpr uint32_t paletteBaseFNV=0x{common.fnv(compact):08x}u,paletteSideFNV=0x{common.fnv(low+meta):08x}u,paletteGridFNV=0x{common.fnv((sample/"pixels.idx").read_bytes()):08x}u;\n'
    asset += array('paletteBaseZ',zlib.compress(compact,9))+array('paletteSideZ',side)
    (destination/'EdgeBenchAssets.h').write_text(asset)
    (destination/'EdgeBenchRuntime.h').write_text(PROFILE_RUNTIME if profile else RUNTIME)
    info=dict(scene=scene,width=1200,height=1200,prototype='local-palette-stage-profile' if profile else 'local-palette',baseBytes=len(compact),compressedSideBytes=len(side),totalBytes=wire,metadata=len(meta),cacheBudgetUpperBound=budget,sideFNV=f'{common.fnv(low+meta):08x}',baselineBodySHA256=baseline_hash,baselineBodyIdentical=True)
    (destination.parent/'scene-manifest.json').write_text(json.dumps(info,indent=2)+'\n')
    return info


def profile_renderer(renderer,palette,wrapper):
    declarations="""struct PaletteProfileCount {uint32_t pixels=0,mixed=0,high=0;};
static PaletteProfileCount paletteCounts[2];
static int paletteStage=1;
"""
    renderer=renderer.replace('static bool paletteEnabled=false,paletteReady=false;', 'static bool paletteEnabled=false,paletteReady=false;\n'+declarations)
    aa=palette.replace('cache.get(paletteView,tile)','cache.get<37>(paletteView,tile)')
    nearest=[]
    counted=[]
    for slots in (36,37):
        fn=palette.replace('rasterRowsLocalPalette(',f'rasterRowsNearest{slots}(')
        fn=fn.replace('cache.get(paletteView,tile)',f'cache.get<{slots}>(paletteView,tile)')
        fn=fn.replace('paletteLUT.color(uint16_t(value),U,V,pal[0])','pal[(value>>16)&7]')
        nearest.append(fn)
        count=fn.replace(f'rasterRowsNearest{slots}(',f'rasterRowsCount{slots}(')
        count=count.replace('  auto &cache=paletteCaches[xPortGetCoreID()];','  auto &cache=paletteCaches[xPortGetCoreID()];\n  auto &counts=paletteCounts[xPortGetCoreID()];')
        count=count.replace('          const uint32_t value=entry->value[index];','          const uint32_t value=entry->value[index];\n          ++counts.pixels;counts.mixed+=!(value>>31);counts.high+=entry->kind!=0;')
        counted.append(count)
    dispatch=wrapper.replace('    rasterRowsLocalPalette(y0,y1,step);','    {if(paletteStage==1)rasterRowsNearest36(y0,y1,step);else if(paletteStage==2)rasterRowsNearest37(y0,y1,step);else rasterRowsLocalPalette(y0,y1,step);}')
    return renderer.replace(palette,aa+''.join(nearest)+''.join(counted)).replace(wrapper,dispatch)


RUNTIME = r'''#pragma once
#include "EdgeBenchAssets.h"
#include "EdgeBenchDeviceBenchmark.h"
static bool paletteInflate(const uint8_t *input,size_t inputBytes,uint8_t *output,size_t outputBytes){
 auto *state=static_cast<tinfl_decompressor *>(ps_malloc(sizeof(tinfl_decompressor)));if(!state)return false;
 tinfl_init(state);size_t in=inputBytes,out=outputBytes;
 auto result=tinfl_decompress(state,input,&in,output,output,&out,TINFL_FLAG_PARSE_ZLIB_HEADER|TINFL_FLAG_USING_NON_WRAPPING_OUTPUT_BUF);
 free(state);return result==TINFL_STATUS_DONE && in==inputBytes && out==outputBytes;
}
static void paletteMemory(const char *stage){
 Serial.printf("EDGE BENCH memory stage=%s internal=%u psram=%u\n",stage,
 unsigned(heap_caps_get_free_size(MALLOC_CAP_INTERNAL|MALLOC_CAP_8BIT)),unsigned(heap_caps_get_free_size(MALLOC_CAP_SPIRAM|MALLOC_CAP_8BIT)));
}
static void runMapEdgeBenchmark(){
 delay(8000);Serial.printf("EDGE BENCH begin scene=%u prototype=local-palette\n",paletteScene);paletteMemory("before-map");
 Serial.printf("EDGE BENCH baseline_sha=%s baseline=verbatim palette=production\n",paletteBaselineSHA);
 if(!helperTask || paletteWireBytes>480000){Serial.println("EDGE BENCH summary status=FAIL reason=worker-budget");return;}
 auto *base=static_cast<uint8_t *>(ps_malloc(paletteBaseBytes));
 if(!base || !paletteInflate(paletteBaseZ,sizeof(paletteBaseZ),base,paletteBaseBytes) || rasterEdgeChecksum(base,paletteBaseBytes)!=paletteBaseFNV){free(base);Serial.println("EDGE BENCH summary status=FAIL reason=base-integrity");return;}
 RasterHeader header={};bool valid=rasterCheck(base,paletteBaseBytes,header,1440000,720000) && header.dataEnd==paletteBaseBytes && header.width==1200 && header.height==1200;
 rasterBuildingCarryOn=false;rasterBackValid=false;valid=valid && parseRaster(base,paletteBaseBytes);free(base);rasterBackValid=false;
 if(!valid){Serial.println("EDGE BENCH summary status=FAIL reason=base-decode");return;}
 // Reuse the ordinary back-raster allocation for low indices plus metadata tail.
 free(rasterBackBuf);rasterBackBuf=static_cast<uint8_t *>(ps_malloc(paletteSideBytes));
 if(!rasterBackBuf || !paletteInflate(paletteSideZ,sizeof(paletteSideZ),rasterBackBuf,paletteSideBytes) ||
 rasterEdgeChecksum(rasterBackBuf,paletteSideBytes)!=paletteSideFNV ||
 !localPaletteBind(rasterBackBuf+720000,paletteMetaBytes,rasterBackBuf,720000,1200,1200,paletteView)){
 free(rasterBackBuf);rasterBackBuf=nullptr;Serial.println("EDGE BENCH summary status=FAIL reason=palette-integrity");return;
 }
 // Restore exact original base material, including every roof, for the verbatim baseline.
 for(unsigned t=0;t<5625;t++)for(unsigned p=0;p<256;p+=2){
  unsigned a=localPaletteKey(paletteView,t,p)>>16,b=localPaletteKey(paletteView,t,p+1)>>16;
  rasterBuf[t*128+p/2]=uint8_t(a|(b<<4));
 }
 uint32_t hash=2166136261u;
 for(int y=0;y<1200;y++)for(int x=0;x<1200;x++){
  uint8_t value=0;rasterRead(rasterBuf,header,x,y,value);hash=(hash^value)*16777619u;
 }
 if(hash!=paletteGridFNV){paletteView=LocalPaletteView{};free(rasterBackBuf);rasterBackBuf=nullptr;Serial.println("EDGE BENCH summary status=FAIL reason=exact-base-mismatch");return;}
 Serial.println("EDGE BENCH base-exact=PASS");paletteMemory("before-cache");
 paletteReady=localPaletteCachesPrepare(paletteCaches,paletteView);paletteMemory("after-cache");
 Serial.printf("EDGE BENCH allocation mapmeta=%u metadata=%u cache=internal-8bit\n",unsigned(paletteView.bytes),unsigned(localPaletteBudget(paletteView)));
 float cx=rasX0+rasW*rasMpp*.5f,cy=rasY0-rasH*rasMpp*.5f;unsigned cases=0,failures=0,unchanged=0;
 if(!paletteReady){paletteEnabled=false;drawRasterMap(cx,cy,.38f,1,0);paletteView=LocalPaletteView{};free(rasterBackBuf);rasterBackBuf=nullptr;Serial.println("EDGE BENCH summary status=FAIL reason=cache-allocation baseline=rendered");return;}
 for(int theme=1;theme<=3;theme++)for(int night=0;night<2;night++)for(int angle:{0,45,90})for(float scale:{.38f,.6f}){
  themeIdx=theme;nightOn=night;paletteEnabled=false;float radians=angle*(PI/180.0f);
  drawRasterMap(cx,cy,scale,cosf(radians),sinf(radians));
  for(auto &cache:paletteCaches)cache.reset(paletteView,RM.pal);
  RasterEdgeBenchmarkResult result;bool ran=rasterEdgeDeviceBenchmark(paletteEnabled,result);
  ++cases;failures+=!ran || !result.withinBudget;unchanged+=ran && !result.changedPixels;
  Serial.printf("EDGE BENCH scene=%u theme=%d night=%d theta=%d scale=%.2f bytes=%u metadata=%u base_us=%u edge_us=%u changed=%u pixels=%u budget=%s\n",
   paletteScene,theme,night,angle,scale,unsigned(paletteWireBytes),unsigned(localPaletteBudget(paletteView)),result.baselineMedianUs,result.edgeMedianUs,result.changedPixels,result.comparedPixels,ran?(result.withinBudget?"PASS":"FAIL"):"ERROR");delay(1);
 }
 paletteEnabled=false;paletteReady=false;for(auto &cache:paletteCaches)cache.release();paletteView=LocalPaletteView{};
 free(rasterBackBuf);rasterBackBuf=nullptr;
 Serial.printf("EDGE BENCH summary scene=%u cases=%u failures=%u unchanged=%u status=%s\n",paletteScene,cases,failures,unchanged,failures?"FAIL":(unchanged==cases?"INCONCLUSIVE":"PASS"));
}
'''

# Same assets/record codec. Profiling stages deliberately never claim acceptance.
PROFILE_RUNTIME = RUNTIME[:RUNTIME.index(' float cx=')] + r'''
 const size_t profileBudget=localPaletteBudget(paletteView)+sizeof(paletteCounts)+sizeof(paletteStage);
 if(profileBudget>524288){Serial.println("EDGE BENCH summary status=FAIL reason=profile-budget");return;}
 float cx=rasX0+rasW*rasMpp*.5f,cy=rasY0-rasH*rasMpp*.5f;unsigned cases=0,errors=0;
 if(!paletteReady){paletteEnabled=false;drawRasterMap(cx,cy,.38f,1,0);Serial.println("EDGE BENCH summary status=FAIL reason=cache-allocation baseline=rendered");return;}
 const char *names[]={"unused","nearest36","nearest37","fullAA37"};
 themeIdx=1;nightOn=false;
 for(int angle:{0,45,90})for(float scale:{.38f,.6f}){
  paletteEnabled=false;float radians=angle*(PI/180.0f);
  drawRasterMap(cx,cy,scale,cosf(radians),sinf(radians));
  for(paletteStage=1;paletteStage<=3;paletteStage++){
   for(auto &cache:paletteCaches)cache.reset(paletteView,RM.pal);
   RasterEdgeBenchmarkResult result;bool ran=rasterEdgeDeviceBenchmark(paletteEnabled,result);
   const bool exact=paletteStage==3 || result.changedPixels==0;
   ++cases;errors+=!ran || !exact;
   // Dedicated untimed pass: no counters or serial added to the timed pixel loops.
   for(auto &cache:paletteCaches){cache.hits=0;cache.misses=0;}
   for(auto &count:paletteCounts)count=PaletteProfileCount{};
   parallelRows(paletteStage==1?rasterRowsCount36:rasterRowsCount37,int(CX-213),int(CX+213));
   Serial.printf("EDGE PROFILE scene=%u stage=%s theta=%d scale=%.2f metadata=%u base_us=%u stage_us=%u changed=%u pixels=%u exactNearest=%s fullAABudget=%s profile_only=true\n",
    paletteScene,names[paletteStage],angle,scale,unsigned(profileBudget),result.baselineMedianUs,result.edgeMedianUs,result.changedPixels,result.comparedPixels,
    paletteStage==3?"NA":(exact?"PASS":"FAIL"),paletteStage==3?(result.withinBudget?"WITHIN":"OVER"):"NA");
   Serial.printf("EDGE PROFILE counters stage=%s hits=%u misses=%u sampled=%u AA=%u high=%u\n",names[paletteStage],
    paletteCaches[0].hits+paletteCaches[1].hits,paletteCaches[0].misses+paletteCaches[1].misses,
    paletteCounts[0].pixels+paletteCounts[1].pixels,paletteCounts[0].mixed+paletteCounts[1].mixed,paletteCounts[0].high+paletteCounts[1].high);
   delay(1);
  }
 }
 paletteEnabled=false;paletteReady=false;for(auto &cache:paletteCaches)cache.release();paletteView=LocalPaletteView{};
 free(rasterBackBuf);rasterBackBuf=nullptr;
 Serial.printf("EDGE BENCH summary scene=%u cases=%u errors=%u status=PROFILE_ONLY\n",paletteScene,cases,errors);
}
'''
PROFILE_RUNTIME=PROFILE_RUNTIME.replace('prototype=local-palette\\n','prototype=local-palette-stage-profile\\n')

PROFILE_RUNTIME=PROFILE_RUNTIME.replace('unsigned(localPaletteBudget(paletteView))','unsigned(localPaletteBudget(paletteView)+sizeof(paletteCounts)+sizeof(paletteStage))')
