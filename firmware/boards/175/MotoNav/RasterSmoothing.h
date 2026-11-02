#pragma once
#include "RasterContinuity.h"
#ifndef MOTONAV_RASTER_SMOOTHING
// shortcut: host timing cannot establish the ESP32 <=10% frame budget; enable after device profiling.
#define MOTONAV_RASTER_SMOOTHING 0
#endif

// One byte per 16x16 tile: pure material, or 255 for mixed. Scan only final
// pixels (including carried roofs); a partially built table is never published.
static inline bool rasterTileScan(const uint8_t *pixels,const RasterHeader &h,
                                  uint8_t *tiles,size_t &cursor,uint32_t budget=8) {
  const size_t count=h.bytes/128;
  while(cursor<count && budget--) {
    const int tx=(cursor%h.blocksWide)*16,ty=(cursor/h.blocksWide)*16;
    uint8_t first=0,color=0;rasterRead(pixels,h,tx,ty,first);
    bool pure=true;
    for(int y=ty;y<ty+16 && y<h.height && pure;y++)
      for(int x=tx;x<tx+16 && x<h.width;x++) {
        rasterRead(pixels,h,x,y,color);
        if(color!=first){pure=false;break;}
      }
    tiles[cursor++]=pure?first:255;
  }
  return cursor==count;
}
static inline bool rasterSmoothCompatible(const RasterHeader &a,const RasterHeader &b) {
  return !a.palette && !b.palette && a.frame==b.frame && a.mm && a.mm==b.mm &&
    ((int64_t)a.x0-b.x0)*1000%a.mm==0 && ((int64_t)a.y0-b.y0)*1000%a.mm==0;
}
static inline bool rasterSmoothRead(const uint8_t *pixels,const RasterHeader &h,
    const uint8_t *back,const RasterHeader &bh,int x,int y,uint8_t &color) {
  if(rasterRead(pixels,h,x,y,color))return true;
  if(!back || !rasterSmoothCompatible(h,bh))return false;
  const int64_t bx=(int64_t)x+((int64_t)h.x0-bh.x0)*1000/h.mm;
  const int64_t by=(int64_t)y+((int64_t)bh.y0-h.y0)*1000/h.mm;
  if(bx<0 || by<0 || bx>=bh.width || by>=bh.height)return false;
  return rasterRead(back,bh,(int)bx,(int)by,color);
}
static inline uint16_t rasterColorMix(const uint16_t *c,unsigned fx,unsigned fy) {
  const uint32_t w[4]={(256-fx)*(256-fy),fx*(256-fy),(256-fx)*fy,fx*fy};
  uint32_t r=0,g=0,b=0;
  for(int i=0;i<4;i++){r+=(c[i]>>11)*w[i];g+=((c[i]>>5)&63)*w[i];b+=(c[i]&31)*w[i];}
  return (uint16_t)((((r+32768)>>16)<<11)|(((g+32768)>>16)<<5)|((b+32768)>>16));
}
static inline uint16_t rasterSmoothColor(const uint8_t *pixels,const RasterHeader &h,const uint8_t *tiles,
    const uint8_t *back,const RasterHeader &bh,const uint16_t *palette,int32_t u,int32_t v,uint16_t nearest) {
  // Source samples live at pixel centers; the existing nearest path uses floor(U).
  const int x=(u>>16)-((uint16_t)u<32768),y=(v>>16)-((uint16_t)v<32768);
  uint8_t index[4];
  if(x>=0 && y>=0 && x+1<h.width && y+1<h.height) {
    if(tiles && (x&15)!=15 && (y&15)!=15 &&
       tiles[(y>>4)*h.blocksWide+(x>>4)]!=255)return nearest;
    const uint32_t k=((uint32_t)((y>>4)*h.blocksWide+(x>>4))<<8)|((y&15)<<4)|(x&15);
    const uint32_t dx=(x&15)==15?241:1;
    const uint32_t dy=(y&15)==15?(uint32_t)h.blocksWide*256-240:16;
    const uint32_t positions[4]={k,k+dx,k+dy,k+dx+dy};
    for(int i=0;i<4;i++) {
      const uint32_t at=positions[i];const uint8_t packed=pixels[at>>1];
      index[i]=(at&1)?packed>>4:packed&15;
    }
  } else if(!rasterSmoothRead(pixels,h,back,bh,x,y,index[0]) ||
     !rasterSmoothRead(pixels,h,back,bh,x+1,y,index[1]) ||
     !rasterSmoothRead(pixels,h,back,bh,x,y+1,index[2]) ||
     !rasterSmoothRead(pixels,h,back,bh,x+1,y+1,index[3]))return nearest;
  if(index[0]==index[1] && index[0]==index[2] && index[0]==index[3])return palette[index[0]];
  uint16_t colors[4]={palette[index[0]],palette[index[1]],palette[index[2]],palette[index[3]]};
  if(colors[0]==colors[1] && colors[0]==colors[2] && colors[0]==colors[3])return colors[0];
  return rasterColorMix(colors,(((uint32_t)u-32768)>>8)&255,(((uint32_t)v-32768)>>8)&255);
}
