#pragma once
#include "../../boards/175/MotoNav/RasterEdge.h"
// Diagnostic borrowed view: owner must retain low+metadata until both workers stop.
struct LocalPaletteView {
 const uint8_t *meta=nullptr,*low=nullptr,*records=nullptr;
 size_t bytes=0;uint32_t tiles=0,epoch=0;uint16_t width=0,height=0,bw=0;
};
struct LocalPaletteEntry {
 uint32_t value[40];uint8_t high[64];uint32_t tag;uint8_t kind;uint8_t padding[3];
};
constexpr unsigned LOCAL_PALETTE_SLOTS=36;
struct LocalPaletteCache {
 LocalPaletteEntry *entries=nullptr;const LocalPaletteView *view=nullptr;uint32_t epoch=0;
 uint16_t colors[8]={};uint32_t hits=0,misses=0;
 LocalPaletteCache()=default;~LocalPaletteCache(){free(entries);}
 LocalPaletteCache(const LocalPaletteCache&)=delete;LocalPaletteCache& operator=(const LocalPaletteCache&)=delete;
 void release(){free(entries);entries=nullptr;view=nullptr;epoch=0;}
 void reset(const LocalPaletteView &v,const uint16_t *pal){
  view=&v;epoch=v.epoch;memcpy(colors,pal,16);hits=misses=0;
  if(entries)for(unsigned i=0;i<LOCAL_PALETTE_SLOTS;i++)entries[i].tag=UINT32_MAX;
 }
 const LocalPaletteEntry *get(const LocalPaletteView &v,uint32_t tile){
  if(!entries || view!=&v || epoch!=v.epoch || tile>=v.tiles)return nullptr;
  auto &e=entries[tile%LOCAL_PALETTE_SLOTS];
  if(e.tag==tile){++hits;return &e;}++misses;
  const uint8_t *record=v.records+rasterEdgeU32(v.meta+tile*4);unsigned k=rasterEdgeU16(record);e.kind=record[2];
  for(unsigned i=0;i<k;i++){
   uint32_t key=rasterEdgeU32(record+4+i*4);e.value[i]=(key&65535)?(key&65535):(0x80000000u|colors[key>>16]);
  }
  if(e.kind)memcpy(e.high,record+4+k*4,64);
  e.tag=tile;return &e;
 }
};
static inline size_t localPaletteBudget(const LocalPaletteView &v){
 return v.bytes+2*LOCAL_PALETTE_SLOTS*sizeof(LocalPaletteEntry)+2*sizeof(LocalPaletteCache)+sizeof(RasterEdgeLUT)+sizeof(LocalPaletteView);
}
static inline unsigned localPaletteIndex(const LocalPaletteView &v,uint32_t tile,unsigned p){
 unsigned low=v.low[tile*128+(p>>1)],index=(low>>((p&1)*4))&15;
 const uint8_t *r=v.records+rasterEdgeU32(v.meta+tile*4);unsigned k=rasterEdgeU16(r);
 if(r[2])index|=((r[4+k*4+(p>>2)]>>((p&3)*2))&3)<<4;return index;
}
static inline uint32_t localPaletteKey(const LocalPaletteView &v,uint32_t tile,unsigned p){
 if(!v.meta || tile>=v.tiles || p>=256)return 0;
 const uint8_t *r=v.records+rasterEdgeU32(v.meta+tile*4);return rasterEdgeU32(r+4+localPaletteIndex(v,tile,p)*4);
}
static inline bool localPaletteBind(const uint8_t *meta,size_t bytes,const uint8_t *low,size_t lowBytes,
 uint16_t width,uint16_t height,LocalPaletteView &out){
 if(!meta || !low || !width || !height || width%16 || height%16)return false;
 const uint32_t tiles=uint32_t(width/16)*(height/16);const size_t header=size_t(tiles+1)*4;
 LocalPaletteView v;v.meta=meta;v.low=low;v.records=nullptr;v.bytes=bytes;v.tiles=tiles;v.width=width;v.height=height;v.bw=width/16;
 if(bytes<header || lowBytes!=size_t(tiles)*128 || localPaletteBudget(v)>RASTER_EDGE_MAX_BYTES ||
    rasterEdgeU32(meta)!=0 || rasterEdgeU32(meta+tiles*4)!=bytes-header)return false;
 v.records=meta+header;
 for(uint32_t t=0;t<tiles;t++){
  const uint32_t start=rasterEdgeU32(meta+t*4),end=rasterEdgeU32(meta+(t+1)*4);
  if(start>end || end>bytes-header || end-start<8)return false;
  const uint8_t *r=v.records+start;const unsigned k=rasterEdgeU16(r),kind=r[2];
  if(!k || k>40 || kind!=(k>16?1u:0u) || r[3] || end-start!=4+k*4+(kind?64u:0u))return false;
  uint32_t last=0;
  for(unsigned i=0;i<k;i++){
   const uint32_t key=rasterEdgeU32(r+4+i*4);const unsigned word=key&65535,pair=word>>11;
   if(key>>16>7 || (word && (!pair || pair>28)) || (i && key<=last))return false;last=key;
  }
  for(unsigned p=0;p<256;p++)if(localPaletteIndex(v,t,p)>=k)return false;
 }
 static uint32_t epoch=0;if(!++epoch)++epoch;v.epoch=epoch;out=v;return true;
}
static inline bool localPaletteCachesPrepare(LocalPaletteCache (&caches)[2],const LocalPaletteView &v){
 for(auto &c:caches)c.release();
 if(!v.meta || localPaletteBudget(v)>RASTER_EDGE_MAX_BYTES)return false;
 for(auto &c:caches){
  c.entries=static_cast<LocalPaletteEntry *>(RASTER_EDGE_CACHE_ALLOC(LOCAL_PALETTE_SLOTS*sizeof(LocalPaletteEntry)));
  if(!c.entries){for(auto &other:caches)other.release();return false;}
 }
 return true;
}
