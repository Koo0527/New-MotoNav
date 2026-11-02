#pragma once
#include "RasterContinuity.h"

// Load eight packed source pixels, including a source-tile boundary. Each
// read stays within allocated tile rows; partial/right edges use the scalar path.
static inline uint32_t rasterRoofWord(const uint8_t *pixels,const RasterHeader &h,int x,int y) {
  if(!((uintptr_t)pixels&3)) {
    const size_t row=((size_t)(y>>4)*h.blocksWide+(x>>4))*128+((y&15)*8);
    const uint8_t *base=(const uint8_t *)__builtin_assume_aligned(pixels+row,4);
    const int half=(x&8)>>1,shift=(x&7)*4;
    uint32_t lo=0;memcpy(&lo,base+half,4);
    if(!shift)return lo;
    const uint8_t *next=base+(half ? 128:4);
    uint32_t hi=0;memcpy(&hi,next,4);
    return (lo>>shift)|(hi<<(32-shift));
  }
  const int first=(16-(x&15))<8 ? (16-(x&15)):8;
  const size_t a=((size_t)(y>>4)*h.blocksWide+(x>>4))*128+((y&15)*8)+((x&15)>>1);
  const uint8_t *src=pixels+a;
  uint32_t value=0;const int available=8-((x&15)>>1);
  memcpy(&value,src,available<4 ? available:4);
  value>>=(x&1)*4;
  if((x&1) && first==8)value|=(uint32_t)src[4]<<28;
  if(first<8)value&=((uint32_t)1<<(first*4))-1;
  if(first<8) {
    const int nx=x+first;
    const size_t b=((size_t)(y>>4)*h.blocksWide+(nx>>4))*128+((y&15)*8);
    uint32_t next=0;memcpy(&next,pixels+b,4);
    const int rest=8-first;next&=((uint32_t)1<<(rest*4))-1;
    value|=next<<(first*4);
  }
  return value;
}
// Merge once at packet decode time, using the two existing raster buffers.
// No extra BLE payload, framebuffer allocation or per-render sample is needed.
struct RasterCarryCursor {
  int ox=0,oy=0,left=0,right=0,bottom=0,tileX=0,tileY=0;
  uint32_t retained=0;
  bool done=true;
};
static inline RasterCarryCursor rasterCarryBegin(const uint8_t *oldPixels,const RasterHeader &old,
                                                  uint8_t *pixels,const RasterHeader &next) {
  RasterCarryCursor s;
  if(!oldPixels || !pixels || oldPixels==pixels || old.palette || next.palette || !old.buildings ||
     old.frame!=next.frame || !old.mm || old.mm!=next.mm) return s;
  const int64_t dx=((int64_t)next.x0-old.x0)*1000,dy=((int64_t)old.y0-next.y0)*1000;
  if(dx%old.mm || dy%old.mm) return s; // Never round a half-pixel shift into a ghost outline.
  const int64_t ox=dx/old.mm,oy=dy/old.mm;
  if(ox>=old.width || ox<=-(int64_t)next.width || oy>=old.height || oy<=-(int64_t)next.height) return s;
  const int left=ox<0 ? (int)-ox:0,top=oy<0 ? (int)-oy:0;
  const int right=(int)((int64_t)old.width-ox<next.width ? (int64_t)old.width-ox:next.width);
  const int bottom=(int)((int64_t)old.height-oy<next.height ? (int64_t)old.height-oy:next.height);
  s.ox=(int)ox;s.oy=(int)oy;s.left=left;s.right=right;s.bottom=bottom;
  s.tileX=left;s.tileY=top;s.done=false;
  return s;
}
static inline bool rasterCarryStep(const uint8_t *oldPixels,const RasterHeader &old,
                                   uint8_t *pixels,RasterHeader &next,RasterCarryCursor &s,uint32_t tiles) {
  if(s.done || !tiles)return s.done;
  const int ox=s.ox,oy=s.oy,right=s.right,bottom=s.bottom;
  uint32_t retained=0;
  // Visit complete destination tiles while their source/target cache lines
  // are hot. Scanning entire rows jumped 128 bytes every eight useful bytes.
  int tileY=s.tileY,tileX=s.tileX;
  while(tileY<bottom && tiles) {
    const int endY=bottom<((tileY|15)+1) ? bottom:((tileY|15)+1);
    while(tileX<right && tiles) {
      const int endX=right<((tileX|15)+1) ? right:((tileX|15)+1);
      for(int y=tileY;y<endY;y++) {
    const int sy=y+(int)oy;
    const uint32_t row=((uint32_t)(y>>4)*next.blocksWide)<<7;
    const uint32_t sourceRow=((uint32_t)(sy>>4)*old.blocksWide)<<7;
    auto mergeOne=[&](int x) {
      const uint32_t a=row+((uint32_t)(x>>4)<<7)+((y&15)<<3)+((x&15)>>1);
      uint8_t &target=pixels[a];const uint8_t ground=(x&1) ? target>>4:target&15;
      if(ground!=0 && ground!=2)return;
      const int sx=x+(int)ox;
      const uint32_t b=sourceRow+((uint32_t)(sx>>4)<<7)+((sy&15)<<3)+((sx&15)>>1);
      const uint8_t roof=(sx&1) ? oldPixels[b]>>4:oldPixels[b]&15;
      if(roof<4 || roof>7)return;
      const uint8_t color=4|(roof&1)|(ground&2);
      target=(x&1) ? (target&15)|(color<<4):(target&240)|color;retained++;
    };
    int x=tileX;
    if(!(x&7) && !((uintptr_t)pixels&3)) {
      while(x+8<=endX) {
        const uint32_t a=row+((uint32_t)(x>>4)<<7)+((y&15)<<3)+((x&15)>>1);
        uint8_t *target=(uint8_t *)__builtin_assume_aligned(pixels+a,4);
        uint32_t ground=0;memcpy(&ground,target,4);
        const uint32_t bad=ground&0xddddddddu;
        const uint32_t allowed=~(bad|(bad>>1)|(bad>>2)|(bad>>3))&0x11111111u;
        if(allowed) {
          const uint32_t roofs=rasterRoofWord(oldPixels,old,x+(int)ox,sy);
          const uint32_t selected=allowed&(roofs>>2)&~(roofs>>3)&0x11111111u;
          if(selected) {
            const uint32_t mask=selected*15;
            const uint32_t colours=0x44444444u|(roofs&0x11111111u)|(ground&0x22222222u);
            const uint32_t merged=(ground&~mask)|(colours&mask);memcpy(target,&merged,4);
            uint32_t count=selected;count+=count>>16;count+=count>>8;count+=count>>4;
            retained+=count&15;
          }
        }
        x+=8;
      }
    }
    if(x&1){mergeOne(x);x++;}
    while(x+1<endX) {
      const int sx=x+(int)ox;
      // Never cross either source or destination tile boundary in this span.
      int span=endX-x;
      if(span>16-(x&15))span=16-(x&15);
      if(span>16-(sx&15))span=16-(sx&15);
      if(span<2){mergeOne(x);x++;if(x<endX){mergeOne(x);x++;}continue;}
      const int pairs=span>>1;
      uint8_t *target=pixels+row+((uint32_t)(x>>4)<<7)+((y&15)<<3)+((x&15)>>1);
      const uint8_t *source=oldPixels+sourceRow+((uint32_t)(sx>>4)<<7)+((sy&15)<<3)+((sx&15)>>1);
      for(int k=0;k<pairs;k++) {
        uint8_t value=target[k];const uint8_t lo=value&15,hi=value>>4;
        const bool low=(lo==0 || lo==2),high=(hi==0 || hi==2);
        if(!low && !high)continue;
        const uint8_t sample=source[k];
        const uint8_t roofLow=(sx&1) ? sample>>4:sample&15;
        const uint8_t roofHigh=(sx&1) ? source[k+1]&15:sample>>4;
        if(low && roofLow>=4 && roofLow<=7){value=(value&240)|4|(roofLow&1)|(lo&2);retained++;}
        if(high && roofHigh>=4 && roofHigh<=7){value=(value&15)|((4|(roofHigh&1)|(hi&2))<<4);retained++;}
        target[k]=value;
      }
      x+=pairs*2;
    }
    if(x<endX)mergeOne(x);
      }
      tileX=endX;
      tiles--;
    }
    if(tileX>=right){tileX=s.left;tileY=endY;}
  }
  s.tileX=tileX;s.tileY=tileY;s.retained+=retained;s.done=tileY>=bottom;
  next.buildings=next.buildings || retained>0;
  return s.done;
}
static inline uint32_t rasterCarryRoofs(const uint8_t *oldPixels,const RasterHeader &old,
                                       uint8_t *pixels,RasterHeader &next) {
  RasterCarryCursor cursor=rasterCarryBegin(oldPixels,old,pixels,next);
  while(!rasterCarryStep(oldPixels,old,pixels,next,cursor,1024)){}
  return cursor.retained;
}
static inline void rasterClearRoofs(uint8_t *pixels,RasterHeader &h) {
  if(!pixels || h.palette) return;
  for(size_t i=0;i<h.bytes;i++) {
    uint8_t lo=pixels[i]&15,hi=pixels[i]>>4;
    if(lo>=4 && lo<=7) lo&=2;
    if(hi>=4 && hi<=7) hi&=2;
    pixels[i]=lo|(hi<<4);
  }
  h.buildings=false;
}
