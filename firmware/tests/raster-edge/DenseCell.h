#pragma once
#include "../../boards/175/MotoNav/RasterEdge.h"
constexpr size_t DENSE_TILED_WORDS=38u*38u*256u;
static inline size_t denseCellTiledIndex(unsigned x,unsigned y){return (((y>>4)*38+(x>>4))<<8)|((y&15)<<4)|(x&15);}
static inline bool denseCellValid(uint16_t w){
 if(w&0x8000)return !(w&0x7000);
 const unsigned pair=w>>10;return pair?pair<=30:w<=7;
}
struct DenseRunDecoder {
 uint16_t *output;size_t capacity,emitted=0;uint8_t pending[4]={};unsigned used=0;bool valid=true,tiled=false;
 DenseRunDecoder(uint16_t *p,size_t count,bool tiles=false):output(p),capacity(count),tiled(tiles){
  valid=output && (!tiled || capacity==360000);if(valid && tiled)memset(output,0,DENSE_TILED_WORDS*sizeof(uint16_t));
 }
 bool feed(const uint8_t *p,size_t n){
  if(!valid || !output)return false;
  for(size_t i=0;i<n;i++){
   pending[used++]=p[i];if(used!=4)continue;used=0;
   unsigned count=rasterEdgeU16(pending),word=rasterEdgeU16(pending+2);
   if(!count || !denseCellValid(uint16_t(word)) || count>capacity-emitted){valid=false;return false;}
   for(unsigned j=0;j<count;j++){size_t at=tiled?denseCellTiledIndex(emitted%600,emitted/600):emitted;output[at]=uint16_t(word);++emitted;}
  }
  return true;
 }
 bool finish()const{return valid && !used && emitted==capacity;}
};
struct DenseCellLUT {
 RasterEdgeLUT lut;uint8_t a[31]={},b[31]={};
 DenseCellLUT(){unsigned pair=0;for(unsigned x=0;x<7;x++)for(unsigned y=x+1;y<8;y++){a[++pair]=x;b[pair]=y;}}
 bool prepare(const uint16_t *pal,float footprint,float rotation){return lut.prepare(pal,footprint,rotation);}
 int distance(uint16_t w,int32_t u,int32_t v)const{
  unsigned n=((w>>5)&31)*2;int fx=int((uint32_t(u)>>8)&255)-128,fy=int((uint32_t(v)>>8)&255)-128;
  return lut.nx[n]*fx+lut.ny[n]*fy-(int(w&31)-16)*2048;
 }
 int band(uint16_t w)const{unsigned n=((w>>5)&31)*2;int x=abs(int(lut.nx[n])),y=abs(int(lut.ny[n]));return 128*(x>y?x:y);}
 uint8_t material(uint16_t w,int32_t u,int32_t v)const{
  if(w&0x8000){unsigned child=((uint32_t(v)>>15)&1)*2+((uint32_t(u)>>15)&1);return uint8_t((w>>(child*3))&7);}
  unsigned pair=w>>10;if(!pair)return uint8_t(w&7);int d=distance(w,u,v);
  if(pair<=28)return d<0?a[pair]:b[pair];
  unsigned ground=pair==29?0:2,fill=pair==29?4:6;return uint8_t(d<0?ground:d>=band(w)?fill:fill+1);
 }
 unsigned coverage(int distance,unsigned n)const{
  int index=128+(((distance>>8)*lut.gain)>>16);if(index<0)index=0;else if(index>256)index=256;
  return lut.coverage[lut.angles[n]][index];
 }
 uint16_t color(uint16_t w,int32_t u,int32_t v)const{
  if(w&0x8000)return lut.palette[material(w,u,v)];
  unsigned pair=w>>10;if(!pair)return lut.palette[w&7];
  unsigned n=((w>>5)&31)*2;int d=distance(w,u,v);unsigned outer=coverage(d,n);
  if(pair<=28)return lut.colors[pair][outer];
  unsigned inner=coverage(d-band(w),n);if(inner>outer)inner=outer;
  const uint16_t colors[3]={lut.palette[pair==29?0:2],lut.palette[pair==29?5:7],lut.palette[pair==29?4:6]};
  const unsigned weights[3]={256-outer,outer-inner,inner};unsigned r=0,g=0,b=0;
  for(unsigned i=0;i<3;i++){r+=(colors[i]>>11)*weights[i];g+=((colors[i]>>5)&63)*weights[i];b+=(colors[i]&31)*weights[i];}
  return uint16_t((((r+128)>>8)<<11)|(((g+128)>>8)<<5)|((b+128)>>8));
 }
};
