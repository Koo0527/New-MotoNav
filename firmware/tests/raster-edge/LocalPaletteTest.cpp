#include <cassert>
#include <cstdio>
#include <vector>
#include <string>
#include <zlib.h>
#include <cstdlib>
static int localFailAfter=-1;
static void *localAlloc(size_t n){if(localFailAfter==0)return nullptr;if(localFailAfter>0)--localFailAfter;return malloc(n);}
#define RASTER_EDGE_CACHE_ALLOC localAlloc
#ifndef LOCAL_PALETTE_HEADER
#define LOCAL_PALETTE_HEADER "LocalPalette.h"
#endif
#include LOCAL_PALETTE_HEADER
#include "../../boards/175/MotoNav/RasterContinuity.h"
static std::vector<uint8_t> read(const std::string &name){FILE*f=fopen(name.c_str(),"rb");assert(f);fseek(f,0,SEEK_END);long n=ftell(f);assert(n>0 && n<2000000);rewind(f);std::vector<uint8_t>b(n);assert(fread(b.data(),1,b.size(),f)==b.size());fclose(f);return b;}
static bool inflateOld(const uint8_t *p,size_t n,uint8_t *out,size_t bytes){
 z_stream z={};z.next_in=const_cast<Bytef *>(p);z.avail_in=uInt(n);z.next_out=out;z.avail_out=uInt(bytes);
 assert(inflateInit(&z)==Z_OK);int status=inflate(&z,Z_FINISH);bool ok=status==Z_STREAM_END && z.total_in==n && z.total_out==bytes;inflateEnd(&z);return ok;
}
int main(int argc,char**argv){
 for(int arg=1;arg<argc;arg++){
  std::string dir=argv[arg];auto low=read(dir+"/palette-probe-low.idx"),meta=read(dir+"/palette-probe-meta.bin"),base=read(dir+"/base.bin"),raw=read(dir+"/pixels.idx");
  auto oldWire=read(dir+"/prototype.edge");RasterEdgeView old;assert(rasterEdgeDecode(oldWire.data(),oldWire.size(),1200,1200,old,524288,inflateOld));
  RasterHeader originalHeader={};assert(rasterCheck(base.data(),base.size(),originalHeader,1440000,720000));assert(originalHeader.dataEnd==base.size());
  std::vector<uint8_t> original(originalHeader.bytes);rasterDecode(base.data(),originalHeader,original.data());assert(raw.size()==1440000);
  LocalPaletteView view;assert(localPaletteBind(meta.data(),meta.size(),low.data(),low.size(),1200,1200,view));
  assert(localPaletteBudget(view)<=524288);
  LocalPaletteCache caches[2];assert(localPaletteCachesPrepare(caches,view));
  uint16_t colors[8]={0,1,2,3,4,5,6,7};for(auto&c:caches)c.reset(view,colors);
  uint32_t hash=2166136261u;
  for(unsigned t=0;t<5625;t++){
   auto *entry=caches[t&1].get(view,t);assert(entry);
   assert(caches[t&1].get(view,t)==entry);
   for(unsigned p=0;p<256;p++){
    uint32_t key=localPaletteKey(view,t,p);unsigned x=(t%75)*16+(p&15),y=(t/75)*16+(p>>4);
    uint8_t originalMaterial=255;assert(rasterRead(original.data(),originalHeader,x,y,originalMaterial));
    assert((key>>16)==originalMaterial && originalMaterial==raw[y*1200+x]);
    assert(uint16_t(key)==rasterEdgeWord(old,x,y));unsigned id=localPaletteIndex(view,t,p);
    uint32_t value=entry->value[id];
#ifdef LOCAL_PALETTE_KEEP_BASE
    assert(value==((key&65535)?key:(0x80000000u|colors[key>>16])));
    assert(((value>>31)?uint16_t(value):colors[(value>>16)&7])==colors[originalMaterial]);
#else
    assert(value==((key&65535)?(key&65535):(0x80000000u|colors[key>>16])));
#endif
   }
  }
  // Row-major word fingerprint matches the existing EDGE representation.
  for(unsigned y=0;y<1200;y++)for(unsigned x=0;x<1200;x++){
   unsigned t=(y>>4)*75+(x>>4),p=(y&15)*16+(x&15);uint16_t word=uint16_t(localPaletteKey(view,t,p));
   hash=(hash^uint8_t(word))*16777619u;hash=(hash^uint8_t(word>>8))*16777619u;
  }
  auto priorEpoch=view.epoch;auto priorKey=localPaletteKey(view,0,0);
  auto bad=meta;bad[0]=1;assert(!localPaletteBind(bad.data(),bad.size(),low.data(),low.size(),1200,1200,view));
  assert(view.epoch==priorEpoch && localPaletteKey(view,0,0)==priorKey);
  for(int mutation=0;mutation<4;mutation++){
   auto evil=meta;size_t start=(5625+1)*4;
   if(mutation==0)evil[start+3]=1;
   if(mutation==1)evil[start]=65;
   if(mutation==2)evil[start+6]=8;
   if(mutation==3)evil[4]++;
   assert(!localPaletteBind(evil.data(),evil.size(),low.data(),low.size(),1200,1200,view));
  }
  auto wrongLow=low;
  for(unsigned t=0;t<5625;t++){
   const uint8_t *r=view.records+rasterEdgeU32(view.meta+t*4);
   if(rasterEdgeU16(r)<16){wrongLow[t*128]|=15;break;}
  }
  assert(!localPaletteBind(meta.data(),meta.size(),wrongLow.data(),wrongLow.size(),1200,1200,view));
  assert(caches[0].entries!=caches[1].entries && caches[0].misses>24);
  auto previous=view.epoch;assert(localPaletteBind(meta.data(),meta.size(),low.data(),low.size(),1200,1200,view));
  assert(view.epoch!=previous && !caches[0].get(view,0));
  localFailAfter=1;assert(!localPaletteCachesPrepare(caches,view));assert(!caches[0].entries && !caches[1].entries);localFailAfter=-1;
  printf("PALETTE HOST metadata=%zu total=%zu wordsFNV=%08x base=exact\n",view.bytes,localPaletteBudget(view),hash);
 }
 assert(argc>1);
}
