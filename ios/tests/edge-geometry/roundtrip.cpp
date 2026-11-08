#include <cassert>
#include <cstdio>
#include <cmath>
#include <fstream>
#include <iterator>
#include <string>
#include <vector>
#include "../../../firmware/boards/175/MotoNav/RasterEdge.h"
#include "zlib_inflate.h"
#include "../../../firmware/boards/175/MotoNav/GameMapStyle.h"
static std::vector<uint8_t> read(const std::string &path) {
 std::ifstream f(path,std::ios::binary);assert(f);
 return std::vector<uint8_t>((std::istreambuf_iterator<char>(f)),std::istreambuf_iterator<char>());
}
int main(int argc,char **argv) {
 assert(argc==2);std::string dir=argv[1];
 auto patterns=read(dir+"/patterns.packets");
 std::ofstream patternWords(dir+"/pattern-words.u16",std::ios::binary);
 assert(patternWords);size_t offset=0;
 for(int record=0;record<28*512;record++) {
  assert(offset+2<=patterns.size());const unsigned size=rasterEdgeU16(patterns.data()+offset);offset+=2;
  assert(offset+size<=patterns.size());RasterEdgeView stencil;
  assert(rasterEdgeDecode(patterns.data()+offset,size,3,3,stencil,RASTER_EDGE_MAX_BYTES,edgeInflate));
  offset+=size;
  for(int y=0;y<3;y++)for(int x=0;x<3;x++)if(x!=1 || y!=1)assert(!rasterEdgeWord(stencil,x,y));
  const uint16_t word=rasterEdgeWord(stencil,1,1);
  const char bytes[2]={char(word&255),char(word>>8)};patternWords.write(bytes,2);
 }
 assert(offset==patterns.size());patternWords.close();assert(patternWords);
 for(const std::string name:{"solid","vertical","horizontal","diagonal","slanted","corner","courtyard","neck","junction","building","parkbuilding","building-road","building-water","parkbuilding-road","parkbuilding-water","padding","compressed","dictionary-pruned"}) {
  int w=name=="dictionary-pruned"?1000:name=="compressed"?512:name=="padding"?17:35,h=name=="dictionary-pruned"?1000:name=="compressed"?512:name=="padding"?19:35;
  auto packet=read(dir+"/"+name+".edge"),raw=read(dir+"/"+name+".raw");
  RasterEdgeView edge;assert(rasterEdgeDecode(packet.data(),packet.size(),w,h,edge,RASTER_EDGE_MAX_BYTES,edgeInflate));
  const bool protectedContact=name.find("-road")!=std::string::npos || name.find("-water")!=std::string::npos;
  if(protectedContact)for(int theme=1;theme<=3;theme++)for(bool night:{false,true}) {
   const auto p=GameMapStyle::palette(theme,night);
   const uint16_t palette[8]={p.base,p.road,p.park,p.water,p.roof,p.outline,p.roof,p.outline};
   RasterEdgeLUT lut;
   for(float footprint:{.5f,1.f,2.f})for(float rotation:{0.f,.37f}) {
    assert(lut.prepare(palette,footprint,rotation));
    for(int y=0;y<h;y++)for(int x=0;x<w;x++)if(raw[y*w+x]==1 || raw[y*w+x]==3) {
     const uint16_t nearest=palette[raw[y*w+x]];
     for(int fraction:{8192,32768,57344}) {
      // Real firmware LUT must preserve road/water, including subpixel samples near buildings.
      assert(lut.color(rasterEdgeWord(edge,x,y),x*65536+fraction,y*65536+32768,nearest)==nearest);
     }
    }
   }
  }
  unsigned edges=0;
  for(int y=0;y<h;y++)for(int x=0;x<w;x++) {
   const uint16_t word=rasterEdgeWord(edge,x,y);if(!word)continue;++edges;
   int pair=0,a=-1,b=-1;for(int aa=0;aa<7;aa++)for(int bb=aa+1;bb<8;bb++)if(++pair==(word>>11)){a=aa;b=bb;}
   assert(a>=0 && b>a);
   if(raw[y*w+x]==1 || raw[y*w+x]==3)assert(b<4);

   const double angle=((word>>5)&63)*6.283185307179586/64,nx=cos(angle),ny=sin(angle),d=(int(word&31)-16)/16.;
   assert(raw[y*w+x]==(d>0?a:b) || fabs(d)<.001);
   if(name=="vertical" || name=="padding")assert(fabs(nx*(16-x-.5)-d)<=.03126);
   if(name=="horizontal")assert(fabs(ny*(16-y-.5)-d)<=.03126);
   if(name=="diagonal")assert(fabs(nx+ny)<.0001 && fabs(nx*(y-x)-d)<=.5);
   if(name=="slanted") {
    // Reference line before center sampling; bound signed-distance shift to 1 m (half a 2 m cell).
    const double expected=20-cos(3.141592653589793/6)*x-sin(3.141592653589793/6)*y;
    assert(fabs(d-expected)<=.5);
   }
   if(name=="building" || name=="parkbuilding") {
    // Outer ground/outline and inner outline/fill remain separate, never rewrite roofs.
    assert(!(raw[y*w+x]>=4 && (raw[y*w+x]&1)==0 && a<4));
   }
  }
  if(name=="solid")assert(edges==0);else assert(edges>0);
  if(name=="vertical") {
   for(int y=1;y<h-1;y++){assert(rasterEdgeWord(edge,15,y));assert(rasterEdgeWord(edge,16,y));}
  }
  if(protectedContact) {
   assert(!rasterEdgeWord(edge,14,17));assert(!rasterEdgeWord(edge,15,17));
   assert(rasterEdgeWord(edge,16,17));assert(edges==33);
  }
  if(name=="corner")assert(!rasterEdgeWord(edge,16,16));
  if(name=="courtyard") {assert(!rasterEdgeWord(edge,12,12));assert(rasterEdgeWord(edge,11,17));}
  if(name=="neck")assert(!rasterEdgeWord(edge,17,17));
  if(name=="junction")assert(!rasterEdgeWord(edge,16,16));
  if(name=="building" || name=="parkbuilding") {
   assert(rasterEdgeWord(edge,14,17));assert(rasterEdgeWord(edge,15,17));
   assert(rasterEdgeWord(edge,16,17));assert(!rasterEdgeWord(edge,17,17));
  }
  std::printf("%s: %u edges, %zu packet, %zu metadata bytes\n",name.c_str(),edges,packet.size(),edge.bytes);
 }
}
