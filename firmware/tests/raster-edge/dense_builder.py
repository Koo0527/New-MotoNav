"""Frozen C dense experiment; no production format or device access."""
from pathlib import Path
import hashlib,json,shutil,zlib,struct
import importlib.util


def validate_dense(base,raw,packed,expected_sha):
 if len(raw)!=720000 or hashlib.sha256(raw).hexdigest()!=expected_sha:raise ValueError('frozen dense C identity')
 if len(base)+len(packed)+32>480000:raise ValueError('complete dense wire budget')
 decoder=zlib.decompressobj();runs=decoder.decompress(packed,1440001)
 if not decoder.eof or decoder.unused_data or decoder.unconsumed_tail or len(runs)%4:raise ValueError('dense RLE zlib stream')
 pos=0
 for count,word in struct.iter_unpack('<HH',runs):
  end=pos+count*2
  if not count or end>len(raw) or raw[pos:end]!=struct.pack('<H',word)*count:raise ValueError('dense RLE identity')
  pos=end
 if pos!=len(raw):raise ValueError('dense RLE length')
 return runs


def generate(common,destination,sample,scene,tiled=False):
 name=sample.name
 base_path=sample/('base.bin' if (sample/'base.bin').is_file() else 'candidate.bin')
 base=base_path.read_bytes();raw_path=common.ROOT/'output/map-edge-bridge/dense-feasibility'/f'C-{name}.u16'
 raw=raw_path.read_bytes();packed=raw_path.with_suffix('.rle.zlib').read_bytes()
 frozen=json.loads((raw_path.parent/'C-raw-sha256.json').read_text())
 runs=validate_dense(base,raw,packed,frozen[raw_path.name])
 # Source copy never includes external identity/config files or symlinks.
 for p in common.SOURCE.rglob('*'):
  if p.is_symlink() or (p.is_file() and (p.suffix in ('.key','.pem','.p12') or b'PRIVATE KEY-----' in p.read_bytes())):raise ValueError('refusing credential/symlink source')
 if destination.exists():shutil.rmtree(destination)
 shutil.copytree(common.SOURCE,destination)
 shutil.copyfile(common.ROOT/'firmware/tests/raster-edge/DeviceBenchmark.h',destination/'EdgeBenchDeviceBenchmark.h')
 header=(Path(__file__).parent/'DenseCell.h').read_text().replace('#include "../../boards/175/MotoNav/RasterEdge.h"','#include "RasterEdge.h"');(destination/'DenseCell.h').write_text(header)
 source=(common.SOURCE/'src/map/RasterRenderer.h').read_text();a=source.index('void __attribute__((optimize("O3"))) rasterRows(');b=source.index('static inline uint16_t vicePatchColor',a);original=source[a:b]
 baseline=original.replace('rasterRows(','rasterRowsBaseline(',1).replace('void __attribute__','void __attribute__((noinline)) __attribute__',1)
 rows=DENSE_ROWS.replace('denseWords[vi*600+ui]','denseWords[denseCellTiledIndex(ui,vi)]') if tiled else DENSE_ROWS
 renderer=source[:a]+baseline+rows+source[b:]
 renderer=common.replace_once(renderer,'#pragma once', '#pragma once\n#include "../../DenseCell.h"\nstatic DenseCellLUT denseLUT;\nstatic uint16_t *denseWords=nullptr;\nstatic bool denseEnabled=false,denseValid=false;')
 anchor='RM.cx = cx; RM.cy = cy; RM.sc = sc; RM.cs = cs; RM.sn = sn;';renderer=common.replace_once(renderer,anchor,anchor+'\n  denseLUT.prepare(RM.pal,1.0f/(sc*rasMpp*2),atan2f(sn,cs));')
 (destination/'src/map/RasterRenderer.h').write_text(renderer)
 entry=(destination/'MotoNav.ino').read_text();entry=common.replace_once(entry,'#include "src/diagnostics/RenderBenchmarks.h"','#include "src/diagnostics/RenderBenchmarks.h"\n#include "EdgeBenchRuntime.h"');entry=common.replace_once(entry,'  helperInit();','  helperInit();\n  runMapEdgeBenchmark();\n  while(true){delay(1000);}')
 (destination/'MotoNav.ino').write_text(entry)
 spec=importlib.util.spec_from_file_location('palette_arrays',Path(__file__).with_name('local_palette_builder.py'));m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
 body=original[original.index('{'):];sha=hashlib.sha256(body.encode()).hexdigest()
 if sha!='f2d16dd7b263bd3e75718d33770ef13b821961c22521e05006e93bed7328dba0':raise ValueError('baseline body differs from d2f49a7')
 assets='#pragma once\n#include <stdint.h>\n'+f'static constexpr unsigned denseScene={scene};\nstatic constexpr size_t denseBaseBytes={len(base)},denseRunBytes={len(runs)},denseWireBytes={len(base)+len(packed)+32};\n'
 assets+=f'static constexpr uint32_t denseBaseFNV=0x{common.fnv(base):08x}u,denseRawFNV=0x{common.fnv(raw):08x}u,densePackedFNV=0x{common.fnv(packed):08x}u;\nstatic const char denseBaselineSHA[]="{sha}";\n'
 assets+=m.array('denseBaseZ',zlib.compress(base,9))+m.array('densePacked',packed)
 runtime=RUNTIME
 if tiled:
  runtime=runtime.replace('prototype=dense-C','prototype=dense-C-tiled')
  runtime=runtime.replace('DenseRunDecoder decoder(out,360000);','DenseRunDecoder decoder(out,360000,true);')
  runtime=runtime.replace('if(!rasterBackBuf)rasterBackBuf=static_cast<uint8_t *>(ps_malloc(720000));','free(rasterBackBuf);rasterBackBuf=static_cast<uint8_t *>(ps_malloc(DENSE_TILED_WORDS*2));')
  runtime=runtime.replace('rasterEdgeChecksum(rasterBackBuf,720000)==denseRawFNV','denseTiledChecksum(denseWords)==denseRawFNV')
  runtime=runtime.replace('allocation dense=720000','allocation dense=739328')
  runtime=runtime.replace('static void runMapEdgeBenchmark(){',TILED_CHECKSUM+'static void runMapEdgeBenchmark(){')
 (destination/'EdgeBenchAssets.h').write_text(assets);(destination/'EdgeBenchRuntime.h').write_text(runtime)
 info=dict(prototype='dense-C-tiled' if tiled else 'dense-C',scene=scene,source=name,baseBytes=len(base),tailBytes=len(packed),totalBytes=len(base)+len(packed)+32,rawBytes=720000,residentBytes=739328 if tiled else 720000,rawSHA256=hashlib.sha256(raw).hexdigest(),baselineBodySHA256=sha,baselineBodyIdentical=True)
 (destination.parent/'scene-manifest.json').write_text(json.dumps(info,indent=2)+'\n');return info

TILED_CHECKSUM=r'''static uint32_t denseTiledChecksum(const uint16_t *words){
 uint32_t hash=2166136261u;
 for(unsigned y=0;y<600;y++)for(unsigned x=0;x<600;x++){
  uint16_t w=words[denseCellTiledIndex(x,y)];hash=(hash^uint8_t(w))*16777619u;hash=(hash^uint8_t(w>>8))*16777619u;
 }
 return hash;
}
'''

DENSE_ROWS=r'''void __attribute__((noinline)) __attribute__((optimize("O3"))) rasterRowsDense(int y0,int y1,int step){
 uint16_t *fb=RM.fb;const uint16_t *pal=RM.pal;
 float cx=RM.cx,cy=RM.cy,sc=RM.sc,cs=RM.cs,sn=RM.sn;
 float inv=1.0f/sc,mpp=rasMpp*2,kpx=inv/mpp;
 int32_t DU=int32_t(cs*kpx*65536.0f),DV=int32_t(sn*kpx*65536.0f);
 for(int y=y0;y<y1;y+=step){
  float dyc=y+.5f-CX;if(fabsf(dyc)>=212)continue;
  int xa=mapCircleRows.left[y],xb=mapCircleRows.right[y];
  float rx=(xa+.5f-CX)*inv,ry=(MAP_PY-(y+.5f))*inv;
  float dx=rx*cs+ry*sn,dy=-rx*sn+ry*cs;
  float u=(cx+dx-rasX0)/mpp,v=(rasY0-(cy+dy))/mpp;
  int32_t U=int32_t(u*65536.0f),V=int32_t(v*65536.0f);uint16_t *row=fb+y*LCD_WIDTH;
  for(int x=xa;x<=xb;x++,U+=DU,V+=DV){
   const int ui=U>>16,vi=V>>16;uint16_t color=pal[0];
   if(uint32_t(ui)<600 && uint32_t(vi)<600)color=denseLUT.color(denseWords[vi*600+ui],U,V);
   row[x]=color;
  }
 }
}
void rasterRows(int y0,int y1,int step){
 if(denseEnabled && denseValid && denseLUT.lut.ready && !RM.pix2 && !rasHasPal && !rasterViceValid)rasterRowsDense(y0,y1,step);
 else rasterRowsBaseline(y0,y1,step);
}

'''

RUNTIME=r'''#pragma once
#include "EdgeBenchAssets.h"
#include "EdgeBenchDeviceBenchmark.h"
static void denseMemory(const char *stage){Serial.printf("EDGE BENCH memory stage=%s internal=%u psram=%u\n",stage,unsigned(heap_caps_get_free_size(MALLOC_CAP_INTERNAL|MALLOC_CAP_8BIT)),unsigned(heap_caps_get_free_size(MALLOC_CAP_SPIRAM|MALLOC_CAP_8BIT)));}
static bool denseBaseInflate(uint8_t *out){
 auto *s=static_cast<tinfl_decompressor *>(ps_malloc(sizeof(tinfl_decompressor)));if(!s)return false;tinfl_init(s);
 size_t in=sizeof(denseBaseZ),n=denseBaseBytes;auto result=tinfl_decompress(s,denseBaseZ,&in,out,out,&n,TINFL_FLAG_PARSE_ZLIB_HEADER|TINFL_FLAG_USING_NON_WRAPPING_OUTPUT_BUF);
 free(s);return result==TINFL_STATUS_DONE && in==sizeof(denseBaseZ) && n==denseBaseBytes;
}
static bool denseStreamInflate(uint16_t *out){
 auto *s=static_cast<tinfl_decompressor *>(ps_malloc(sizeof(tinfl_decompressor)));auto *ring=static_cast<uint8_t *>(ps_malloc(32768));
 if(!s || !ring){free(s);free(ring);return false;}tinfl_init(s);DenseRunDecoder decoder(out,360000);size_t pos=0,produced=0;bool okay=false;
 for(;;){
  size_t in=sizeof(densePacked)-pos,n=32768;
  auto result=tinfl_decompress(s,densePacked+pos,&in,ring,ring,&n,TINFL_FLAG_PARSE_ZLIB_HEADER);pos+=in;produced+=n;
  if(!decoder.feed(ring,n) || produced>denseRunBytes)break;
  if(result==TINFL_STATUS_DONE){okay=pos==sizeof(densePacked) && produced==denseRunBytes && decoder.finish();break;}
  if(result!=TINFL_STATUS_HAS_MORE_OUTPUT || n!=32768 || (!in&&!n))break;
 }
 free(s);free(ring);return okay;
}
static void runMapEdgeBenchmark(){
 delay(8000);Serial.printf("EDGE BENCH begin scene=%u prototype=dense-C\n",denseScene);denseMemory("before-map");
 Serial.printf("EDGE BENCH baseline_sha=%s baseline=verbatim palette=production\n",denseBaselineSHA);
 if(!helperTask || denseWireBytes>480000){Serial.println("EDGE BENCH summary status=FAIL reason=worker-budget");return;}
 auto *base=static_cast<uint8_t *>(ps_malloc(denseBaseBytes));
 if(!base || !denseBaseInflate(base) || rasterEdgeChecksum(base,denseBaseBytes)!=denseBaseFNV){free(base);Serial.println("EDGE BENCH summary status=FAIL reason=base-integrity");return;}
 RasterHeader h={};bool valid=rasterCheck(base,denseBaseBytes,h,1440000,720000) && h.width==1200 && h.height==1200 && h.dataEnd==denseBaseBytes;
 rasterBuildingCarryOn=false;rasterBackValid=false;valid=valid && parseRaster(base,denseBaseBytes);free(base);rasterBackValid=false;
 if(!valid){Serial.println("EDGE BENCH summary status=FAIL reason=base-decode");return;}
 if(!rasterBackBuf)rasterBackBuf=static_cast<uint8_t *>(ps_malloc(720000));denseWords=reinterpret_cast<uint16_t *>(rasterBackBuf);
 denseMemory("before-dense");
 denseValid=denseWords && rasterEdgeChecksum(densePacked,sizeof(densePacked))==densePackedFNV && denseStreamInflate(denseWords) && rasterEdgeChecksum(rasterBackBuf,720000)==denseRawFNV;
 denseMemory("after-dense");
 const size_t metadata=sizeof(DenseCellLUT)+sizeof(DenseRunDecoder)+sizeof(tinfl_decompressor)+32768+32;
 Serial.printf("EDGE BENCH allocation dense=720000 metadata=%u\n",unsigned(metadata));
 float cx=rasX0+rasW*rasMpp*.5f,cy=rasY0-rasH*rasMpp*.5f;
 if(!denseValid || metadata>524288){denseEnabled=false;drawRasterMap(cx,cy,.38f,1,0);Serial.println("EDGE BENCH summary status=FAIL reason=dense-integrity baseline=rendered");return;}
 unsigned cases=0,failures=0,unchanged=0;
 for(int theme=1;theme<=3;theme++)for(int night=0;night<2;night++)for(int angle:{0,45,90})for(float scale:{.38f,.6f}){
  themeIdx=theme;nightOn=night;denseEnabled=false;float radians=angle*(PI/180.0f);drawRasterMap(cx,cy,scale,cosf(radians),sinf(radians));
  RasterEdgeBenchmarkResult result;bool ran=rasterEdgeDeviceBenchmark(denseEnabled,result);
  ++cases;failures+=!ran || !result.withinBudget;unchanged+=ran && !result.changedPixels;
  Serial.printf("EDGE BENCH scene=%u theme=%d night=%d theta=%d scale=%.2f bytes=%u metadata=%u base_us=%u edge_us=%u changed=%u pixels=%u budget=%s\n",denseScene,theme,night,angle,scale,unsigned(denseWireBytes),unsigned(metadata),result.baselineMedianUs,result.edgeMedianUs,result.changedPixels,result.comparedPixels,ran?(result.withinBudget?"PASS":"FAIL"):"ERROR");delay(1);
 }
 denseEnabled=false;denseValid=false;denseWords=nullptr;
 Serial.printf("EDGE BENCH summary scene=%u cases=%u failures=%u unchanged=%u status=%s\n",denseScene,cases,failures,unchanged,failures?"FAIL":(unchanged==cases?"INCONCLUSIVE":"PASS"));
}
'''
