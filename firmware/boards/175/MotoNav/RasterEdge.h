#pragma once
#include <stdint.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <utility>

// Opt-in prototype only. Override with ps_malloc before including on ESP32.
#ifndef RASTER_EDGE_ALLOC
#if defined(ESP_PLATFORM)
// v7.x 接入守卫：默认 malloc 在 ESP32 内部堆上放不下 512KB，解码会一直失败。
// 固件接入前必须显式选择分配器（ps_malloc 或其他 PSRAM 分配器）。
#error "Define RASTER_EDGE_ALLOC as ps_malloc (or another PSRAM allocator) before including RasterEdge.h on ESP32"
#endif
#define RASTER_EDGE_ALLOC malloc
#endif
constexpr size_t RASTER_EDGE_MAX_BYTES=512u*1024u;
constexpr size_t RASTER_EDGE_MAX_PACKET=480000u;
struct RasterEdgeTile { uint32_t base; uint16_t mask[16]; uint8_t rank[16]; };
static_assert(sizeof(RasterEdgeTile)==52,"edge metadata budget requires 52-byte tiles");
// Callback must reject truncated/trailing streams and non-exact output lengths.
using RasterEdgeInflater=bool(*)(const uint8_t *,size_t,uint8_t *,size_t);
struct RasterEdgeView {
  RasterEdgeTile *tiles=nullptr;
  uint16_t *words=nullptr,*dictionary=nullptr;
  uint8_t *indices=nullptr,*rawMasks=nullptr;
  uint32_t *tileBases=nullptr;
  uint32_t epoch=0;
  uint8_t codec=0;
  uint16_t width=0,height=0,blocksWide=0;
  size_t bytes=0;
  RasterEdgeView()=default;
  ~RasterEdgeView(){free(tiles);}
  RasterEdgeView(const RasterEdgeView&)=delete;
  RasterEdgeView& operator=(const RasterEdgeView&)=delete;
};
static inline void rasterEdgeRelease(RasterEdgeView &v){
  free(v.tiles);v.tiles=nullptr;v.words=nullptr;v.dictionary=nullptr;v.indices=nullptr;v.rawMasks=nullptr;v.tileBases=nullptr;v.epoch=0;v.codec=0;v.width=v.height=v.blocksWide=0;v.bytes=0;
}
// Caller swaps only after both row workers finish; this does not synchronize cores.
static inline void rasterEdgeSwap(RasterEdgeView &a,RasterEdgeView &b){
  using std::swap;
  swap(a.tiles,b.tiles);swap(a.words,b.words);swap(a.dictionary,b.dictionary);
  swap(a.indices,b.indices);swap(a.rawMasks,b.rawMasks);swap(a.tileBases,b.tileBases);swap(a.epoch,b.epoch);swap(a.codec,b.codec);swap(a.width,b.width);
  swap(a.height,b.height);swap(a.blocksWide,b.blocksWide);swap(a.bytes,b.bytes);
}
static inline uint32_t rasterEdgeChecksum(const uint8_t *p,size_t len){
  uint32_t hash=2166136261u;
  for(size_t i=0;i<len;i++)hash=(hash^p[i])*16777619u;
  return hash;
}
static inline uint16_t rasterEdgeU16(const uint8_t *p){return uint16_t(p[0]|uint16_t(p[1])<<8);}
static inline uint32_t rasterEdgeU32(const uint8_t *p){return uint32_t(rasterEdgeU16(p))|uint32_t(rasterEdgeU16(p+2))<<16;}
static inline unsigned rasterEdgePopcount(uint16_t v){return unsigned(__builtin_popcount(unsigned(v)));}
// EDGE v1 flags0: raw masks+words; flags1: zlib(masks+dictionary+byte indices).
// Validation and publication are transactional; this isolated decoder is not a queue.
static inline bool rasterEdgeDecode(const uint8_t *p,size_t len,uint16_t width,uint16_t height,
    RasterEdgeView &out,size_t limit=RASTER_EDGE_MAX_BYTES,RasterEdgeInflater inflate=nullptr){
  if(!p || len<24 || len>RASTER_EDGE_MAX_PACKET || memcmp(p,"EDGE",4) || p[4]!=1 || p[5]>1 ||
     rasterEdgeU16(p+6)!=width || rasterEdgeU16(p+8)!=height || !width || !height)return false;
  const bool codec=p[5]==1;
  const unsigned dictCount=rasterEdgeU16(p+10);
  if(codec?(!inflate || !dictCount || dictCount>256):dictCount!=0)return false;
  const uint32_t bw=(uint32_t(width)+15)/16,bh=(uint32_t(height)+15)/16,tiles=bw*bh;
  const uint32_t count=rasterEdgeU32(p+16);
  if(rasterEdgeU32(p+12)!=tiles || tiles>RASTER_EDGE_MAX_BYTES/sizeof(RasterEdgeTile) ||
     count>RASTER_EDGE_MAX_BYTES/(codec?1:2))return false;
  const size_t masksBytes=size_t(tiles)*32;
  const size_t valueBytes=codec?size_t(dictCount)*2+count:size_t(count)*2;
  const size_t bytes=size_t(tiles)*(codec?36:sizeof(RasterEdgeTile))+valueBytes;
  const size_t payloadBytes=masksBytes+valueBytes;
  if(bytes>limit || bytes>RASTER_EDGE_MAX_BYTES || (!codec && len!=24+payloadBytes) ||
     rasterEdgeU32(p+20)!=rasterEdgeChecksum(p+24,len-24))return false;
  auto *data=static_cast<RasterEdgeTile *>(RASTER_EDGE_ALLOC(bytes));
  if(!data)return false;
  const uint8_t *payload=p+24;
  if(codec){
    // Retain raw masks/dictionary/indices after the per-tile value bases.
    auto *raw=reinterpret_cast<uint8_t *>(data)+bytes-payloadBytes;
    if(!inflate(p+24,len-24,raw,payloadBytes)){free(data);return false;}
    payload=raw;
  }
  const uint8_t *values=payload+masksBytes;
  uint32_t total=0;bool valid=true;
  for(uint32_t t=0;t<tiles;t++)for(unsigned y=0;y<16;y++){
    const uint16_t mask=rasterEdgeU16(payload+size_t(t)*32+y*2);
    const unsigned tx=t%bw,ty=t/bw;
    if((ty*16+y>=height && mask) || (tx==bw-1 && width%16 && (mask>>(width%16))))valid=false;
    total+=rasterEdgePopcount(mask);
  }
  if(total!=count)valid=false;
  for(uint32_t i=0;i<(codec?dictCount:count);i++){
    const unsigned pair=rasterEdgeU16(values+size_t(i)*2)>>11;
    if(pair<1 || pair>28)valid=false;
  }
  if(codec)for(uint32_t i=0;i<count;i++)if(values[dictCount*2+i]>=dictCount)valid=false;
  if(!valid){free(data);return false;}
  auto *bases=reinterpret_cast<uint32_t *>(data);
  auto *words=codec?reinterpret_cast<uint16_t *>(const_cast<uint8_t *>(values)):
      reinterpret_cast<uint16_t *>(data+tiles);
  uint32_t base=0;
  for(uint32_t t=0;t<tiles;t++){
    unsigned rank=0;if(codec)bases[t]=base;else data[t].base=base;
    for(unsigned y=0;y<16;y++){
      const uint16_t mask=rasterEdgeU16(payload+size_t(t)*32+y*2);
      if(!codec){data[t].mask[y]=mask;data[t].rank[y]=uint8_t(rank);}
      rank+=rasterEdgePopcount(mask);
    }
    base+=rank;
  }
  for(uint32_t i=0;i<(codec?dictCount:count);i++)words[i]=rasterEdgeU16(values+size_t(i)*2);

  rasterEdgeRelease(out);out.tiles=data;out.words=codec?nullptr:words;
  out.dictionary=codec?words:nullptr;out.indices=codec?reinterpret_cast<uint8_t *>(words+dictCount):nullptr;
  out.rawMasks=codec?const_cast<uint8_t *>(payload):nullptr;out.tileBases=codec?bases:nullptr;
  static uint32_t nextEpoch=0;if(!++nextEpoch)++nextEpoch;out.epoch=nextEpoch;
  out.codec=uint8_t(codec);out.width=width;out.height=height;out.blocksWide=uint16_t(bw);out.bytes=bytes;return true;
}
static inline uint16_t rasterEdgeMask(const RasterEdgeView &v,uint32_t t,unsigned row){
  return v.codec?rasterEdgeU16(v.rawMasks+size_t(t)*32+row*2):v.tiles[t].mask[row];
}
static inline uint16_t rasterEdgeWord(const RasterEdgeView &v,int x,int y){
  if(!v.tiles || uint32_t(x)>=v.width || uint32_t(y)>=v.height)return 0;
  const uint32_t t=(y>>4)*v.blocksWide+(x>>4);const unsigned row=y&15,bit=1u<<(x&15);
  const uint16_t mask=rasterEdgeMask(v,t,row);if(!(mask&bit))return 0;
  uint32_t at;
  if(v.codec){at=v.tileBases[t];for(unsigned r=0;r<row;r++)at+=rasterEdgePopcount(rasterEdgeMask(v,t,r));}
  else at=v.tiles[t].base+v.tiles[t].rank[row];
  at+=rasterEdgePopcount(uint16_t(mask&(bit-1)));
  return v.codec?v.dictionary[v.indices[at]]:v.words[at];
}

#ifndef RASTER_EDGE_CACHE_ALLOC
#define RASTER_EDGE_CACHE_ALLOC malloc
#endif
struct RasterEdgeBaseLUT {
  uint32_t pair[256];
  RasterEdgeBaseLUT(){for(unsigned i=0;i<256;i++)pair[i]=((i&15)<<5)|((i>>4)<<21);}
};
struct RasterEdgeCache {
  uint16_t *dense=nullptr;
  uint32_t *tags=nullptr,*ages=nullptr;
  uint8_t *slots=nullptr;
  const RasterEdgeView *view=nullptr;
  const uint8_t *source=nullptr;
  uint32_t epoch=0,sourceEpoch=0,tileCount=0,clock=0,hits=0,misses=0;
  unsigned used=0;
  RasterEdgeCache()=default;
  ~RasterEdgeCache(){free(dense);}
  RasterEdgeCache(const RasterEdgeCache&)=delete;
  RasterEdgeCache& operator=(const RasterEdgeCache&)=delete;
  void release(){free(dense);dense=nullptr;view=nullptr;source=nullptr;slots=nullptr;epoch=0;}
  const uint16_t *get(const RasterEdgeView &v,uint32_t srcEpoch,uint32_t tile,const RasterEdgeBaseLUT &lut){
    if(!dense || view!=&v || epoch!=v.epoch || sourceEpoch!=srcEpoch || tile>=tileCount)return nullptr;
    unsigned slot=slots[tile];
    if(slot!=255 && tags[slot]==tile){++hits;ages[slot]=++clock;return dense+slot*256;}
    ++misses;
    if(used<64)slot=used++;
    else {
      slot=0;for(unsigned i=1;i<64;i++)if(ages[i]<ages[slot])slot=i;
      slots[tags[slot]]=255;
    }
    tags[slot]=tile;ages[slot]=++clock;slots[tile]=uint8_t(slot);
    uint16_t *out=dense+slot*256;const uint8_t *base=source+size_t(tile)*128;
    for(unsigned i=0;i<128;i++){const uint32_t pair=lut.pair[base[i]];memcpy(out+i*2,&pair,4);}
    uint32_t at=v.codec?v.tileBases[tile]:v.tiles[tile].base;
    for(unsigned y=0;y<16;y++){
      unsigned mask=rasterEdgeMask(v,tile,y);
      while(mask){unsigned x=unsigned(__builtin_ctz(mask));mask&=mask-1;
        out[y*16+x]=v.codec?v.dictionary[v.indices[at]]:v.words[at];++at;
      }
    }
    return out;
  }
};
static inline size_t rasterEdgeCacheBytes(const RasterEdgeView &v){
  const size_t count=size_t(v.blocksWide)*((v.height+15)/16);
  return 64u*(256u*2u+8u)+count;
}
static inline size_t rasterEdgeCacheBudget(const RasterEdgeView &v){
  return v.bytes+2*rasterEdgeCacheBytes(v)+2*sizeof(RasterEdgeCache)+sizeof(RasterEdgeBaseLUT);
}
// Bind/reset only with both row workers stopped; each worker owns its cache.
static inline bool rasterEdgeCachePairPrepare(RasterEdgeCache (&cache)[2],const RasterEdgeView &v,
    const uint8_t *source,size_t sourceBytes,uint32_t sourceEpoch,const RasterEdgeBaseLUT &){
  for(auto &c:cache)c.release();
  const uint32_t count=uint32_t(v.blocksWide)*((v.height+15)/16);
  if(!v.tiles || !source || !sourceEpoch || sourceBytes<size_t(count)*128 || rasterEdgeCacheBudget(v)>RASTER_EDGE_MAX_BYTES)return false;
  for(auto &c:cache){
    c.dense=static_cast<uint16_t *>(RASTER_EDGE_CACHE_ALLOC(rasterEdgeCacheBytes(v)));
    if(!c.dense){for(auto &other:cache)other.release();return false;}
    c.tags=reinterpret_cast<uint32_t *>(c.dense+64*256);c.ages=c.tags+64;
    c.slots=reinterpret_cast<uint8_t *>(c.ages+64);memset(c.slots,255,count);
    c.view=&v;c.source=source;c.epoch=v.epoch;c.sourceEpoch=sourceEpoch;c.tileCount=count;
    c.clock=c.hits=c.misses=0;c.used=0;
  }
  return true;
}

struct RasterEdgeLUT {
  int16_t nx[64]={},ny[64]={};
  uint16_t coverage[9][257]={},colors[29][257]={};
  uint8_t angles[64]={};
  uint16_t palette[8]={};
  int32_t gain=0;
  bool initialized=false,paletteReady=false,ready=false;
  float footprintKey=0,rotationKey=0;
  // sourceCellsPerPixel is 1/(screenScale*rasMpp). Rotation is in source x/y.
  bool prepare(const uint16_t *pal,float sourceCellsPerPixel,float rotation){
    ready=false;
    if(!pal || !isfinite(sourceCellsPerPixel) || sourceCellsPerPixel<1.0f/64 ||
       sourceCellsPerPixel>64 || !isfinite(rotation))return false;
    constexpr double pi=3.14159265358979323846;
    if(!initialized){
      for(int i=0;i<64;i++){
        nx[i]=int16_t(lround(cos(i*2*pi/64)*256));ny[i]=int16_t(lround(sin(i*2*pi/64)*256));
      }
      // Same square/half-plane integral and nine-angle symmetry as VCE.
      for(int a=0;a<=8;a++){
        const double major=cos(a*pi/32),minor=sin(a*pi/32);
        for(int i=0;i<=256;i++){
          const double t=(i-128)*(1.5/256)+(major+minor)*.5;
          double c;
          if(t<=0)c=0;
          else if(t>=major+minor)c=1;
          else if(minor<.00001)c=t/major;
          else if(t<minor)c=t*t/(2*major*minor);
          else if(t<=major)c=(t-minor*.5)/major;
          else {const double tail=major+minor-t;c=1-tail*tail/(2*major*minor);}
          coverage[a][i]=uint16_t(lround(c*256));
        }
      }
      initialized=true;
    }
    if(!paletteReady || memcmp(palette,pal,sizeof(palette))){
      memcpy(palette,pal,sizeof(palette));unsigned pair=0;
      for(unsigned a=0;a<7;a++)for(unsigned b=a+1;b<8;b++){
        ++pair;for(unsigned t=0;t<=256;t++){
          const unsigned r=((pal[a]>>11)*(256-t)+(pal[b]>>11)*t+128)>>8;
          const unsigned g=(((pal[a]>>5)&63)*(256-t)+((pal[b]>>5)&63)*t+128)>>8;
          const unsigned blue=((pal[a]&31)*(256-t)+(pal[b]&31)*t+128)>>8;
          colors[pair][t]=uint16_t((r<<11)|(g<<5)|blue);
        }
      }
      paletteReady=true;
    }
    if(footprintKey!=sourceCellsPerPixel || rotationKey!=rotation){
      gain=int32_t(lround(65536.0/(1.5*sourceCellsPerPixel)));
      const int rotate=int(lround(remainder(double(rotation),2*pi)*(32/pi)));
      for(int i=0;i<64;i++){int a=(i-rotate)&15;if(a>8)a=16-a;angles[i]=uint8_t(a);}
      footprintKey=sourceCellsPerPixel;rotationKey=rotation;
    }
    ready=true;return true;
  }
  inline uint16_t color(uint16_t word,int32_t u,int32_t v,uint16_t nearest) const {
    const unsigned pair=word>>11;
    if(!ready || !pair || pair>28)return nearest;
    const unsigned n=(word>>5)&63;
    const int fx=int((uint32_t(u)>>8)&255)-128,fy=int((uint32_t(v)>>8)&255)-128;
    const int distance=(nx[n]*fx+ny[n]*fy-(int(word&31)-16)*4096)>>8;
    int index=128+((distance*gain)>>16);
    if(index<0)index=0;else if(index>256)index=256;
    return colors[pair][coverage[angles[n]][index]];
  }
};
