#pragma once
#include <stdint.h>
#include <stddef.h>
#include <string.h>

// 校验完整游程后才允许写入备用底图；坏包不会使当前底图失效。
struct RasterHeader {
  uint16_t frame, width, height, mm;
  int32_t x0, y0;
  uint32_t dataStart, dataEnd;
  int blocksWide;
  size_t bytes;
  bool palette;
  bool buildings;
};
static inline uint16_t rasterU16(const uint8_t *p) { return (uint16_t)(p[0] | ((uint16_t)p[1] << 8)); }
static inline int32_t rasterI32(const uint8_t *p) {
  return (int32_t)((uint32_t)p[0] | ((uint32_t)p[1]<<8) | ((uint32_t)p[2]<<16) | ((uint32_t)p[3]<<24));
}
static inline bool rasterCheck(const uint8_t *p, uint32_t len, RasterHeader &h, uint32_t maxPixels, size_t capacity) {
  if (!p || len<16) return false;
  h.frame=rasterU16(p); h.x0=rasterI32(p+2); h.y0=rasterI32(p+6);
  h.width=rasterU16(p+10); h.height=rasterU16(p+12);
  uint16_t flags=rasterU16(p+14); h.palette=(flags&0x8000)!=0; h.buildings=(flags&0x4000)!=0; h.mm=flags&0x3fff;
  if ((flags & 0x3000) || (h.palette && h.buildings)) return false; // Retired experimental wire flags.
  uint32_t n=(uint32_t)h.width*h.height;
  if (!h.width || !h.height || !h.mm || n>maxPixels) return false;
  h.blocksWide=(h.width+15)/16;
  h.bytes=(size_t)h.blocksWide*((h.height+15)/16)*128;
  h.dataStart=h.palette ? 48 : 16;
  if (h.bytes>capacity || len<h.dataStart) return false;
  uint32_t pos=h.dataStart, count=0;
  while (pos<len && count<n) {
    uint8_t b=p[pos++]; uint32_t run=(b>>4)+1;
    if ((b>>4)==15) { if (pos>=len) return false; run=16+p[pos++]; }
    if ((!h.palette && (b&15)>(h.buildings ? 7 : 3)) || run>n-count) return false;
    count+=run;
  }
  if (count!=n) return false;
  h.dataEnd=pos;
  return true;
}
// RLE spans stay within one 16-pixel tile row. Write packed pairs in one
// contiguous operation instead of recomputing tiled addresses per pixel.
struct RasterDecodeCursor {
  size_t cleared=0;
  uint32_t pos=0, emitted=0, run=0;
  int x=0,y=0;
  uint8_t color=0;
  bool started=false,done=false;
};
// Each call performs at most budget bytes of clearing or budget pixels of
// decoding. A run may be suspended mid-nibble; padding remains exactly zero.
static inline bool rasterDecodeStep(const uint8_t *p,const RasterHeader &h,uint8_t *out,
                                     RasterDecodeCursor &s,uint32_t budget) {
  if(s.done || !budget)return s.done;
  if(!s.started){s.pos=h.dataStart;s.started=true;}
  if(s.cleared<h.bytes) {
    size_t take=h.bytes-s.cleared;if(take>budget)take=budget;
    memset(out+s.cleared,0,take);s.cleared+=take;
    return false;
  }
  const uint32_t n=(uint32_t)h.width*h.height;
  while(budget && s.emitted<n) {
    if(!s.run) {
      uint8_t b=p[s.pos++];s.color=b&15;s.run=(b>>4)+1;
      if((b>>4)==15)s.run=16+p[s.pos++];
    }
    uint32_t take=s.run;if(take>budget)take=budget;
    if(s.color) {
      if(take>(uint32_t)(h.width-s.x))take=h.width-s.x;
      if(take>(uint32_t)(16-(s.x&15)))take=16-(s.x&15);
      const uint32_t addr=((uint32_t)((s.y>>4)*h.blocksWide+(s.x>>4))<<7)|((s.y&15)<<3)|((s.x&15)>>1);
      uint8_t *target=out+addr;uint32_t left=take;
      if(s.x&1){*target++|=s.color<<4;left--;}
      const uint32_t pairs=left>>1;
      if(pairs)memset(target,s.color|(s.color<<4),pairs);
      if(left&1)target[pairs]|=s.color;
    }
    s.x+=take;while(s.x>=h.width){s.x-=h.width;s.y++;}
    s.run-=take;s.emitted+=take;budget-=take;
  }
  s.done=s.emitted==n;
  return s.done;
}
static inline void rasterDecode(const uint8_t *p,const RasterHeader &h,uint8_t *out) {
  RasterDecodeCursor cursor;
  while(!rasterDecodeStep(p,h,out,cursor,65536)){}
}
static inline bool rasterRead(const uint8_t *pixels, const RasterHeader &h, int x, int y, uint8_t &color) {
  if (!pixels || (uint32_t)x>=h.width || (uint32_t)y>=h.height) return false;
  uint32_t k=((uint32_t)((y>>4)*h.blocksWide+(x>>4))<<8)|((y&15)<<4)|(x&15);
  uint8_t b=pixels[k>>1]; color=(k&1) ? b>>4 : b&15;
  return true;
}
