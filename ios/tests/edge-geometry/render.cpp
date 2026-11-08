#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <iterator>
#include <string>
#include <vector>
#include "../../../firmware/boards/175/MotoNav/RasterEdge.h"
#include "zlib_inflate.h"
#include "../../../firmware/boards/175/MotoNav/GameMapStyle.h"
static std::vector<uint8_t> read(const char *path) {
 std::ifstream f(path,std::ios::binary);if(!f)return {};
 return std::vector<uint8_t>((std::istreambuf_iterator<char>(f)),std::istreambuf_iterator<char>());
}
int main(int argc,char **argv) {
 if(argc!=11)return 2;
 auto raw=read(argv[1]),packet=read(argv[2]);
 const int w=atoi(argv[3]),h=atoi(argv[4]),theme=atoi(argv[5]);
 const bool night=atoi(argv[6]);const double scale=atof(argv[7]),angle=atof(argv[8])*3.141592653589793/180;
 if(w<=0 || h<=0 || size_t(w)*h!=raw.size() || theme<1 || theme>3 || !std::isfinite(scale) || scale<1 || scale>16 || !std::isfinite(angle))return 2;
 for(auto p:raw)if(p>7)return 2;
 RasterEdgeView view;if(!rasterEdgeDecode(packet.data(),packet.size(),w,h,view,RASTER_EDGE_MAX_BYTES,edgeInflate))return 3;
 const auto p=GameMapStyle::palette(theme,night);
 const uint16_t palette[8]={p.base,p.road,p.park,p.water,p.roof,p.outline,p.roof,p.outline};
 RasterEdgeLUT lut;if(!lut.prepare(palette,float(1/scale),float(angle)))return 4;
 const int ow=int(w*scale),oh=int(h*scale);if(ow>8192 || oh>8192)return 2;
 for(int mode=0;mode<2;mode++) {
  FILE *f=fopen(argv[9+mode],"wb");if(!f)return 5;
  fprintf(f,"P6\n%d %d\n255\n",ow,oh);
  for(int y=0;y<oh;y++)for(int x=0;x<ow;x++) {
   const double dx=(x+.5-ow*.5)/scale,dy=(y+.5-oh*.5)/scale;
   const double u=w*.5+cos(angle)*dx-sin(angle)*dy,v=h*.5+sin(angle)*dx+cos(angle)*dy;
   uint16_t c=p.base;
   if(u>=0 && v>=0 && u<w && v<h) {
    int sx=int(u),sy=int(v);c=palette[raw[sy*w+sx]];
    if(mode)c=lut.color(rasterEdgeWord(view,sx,sy),int32_t(u*65536),int32_t(v*65536),c);
   }
   const uint8_t rgb[3]={uint8_t(((c>>11)&31)*255/31),uint8_t(((c>>5)&63)*255/63),uint8_t((c&31)*255/31)};
   fwrite(rgb,1,3,f);
  }
  if(fclose(f))return 5;
 }
 printf("%u values, %zu encoded bytes, %zu decoded metadata bytes\n",rasterEdgeU32(packet.data()+16),packet.size(),view.bytes);
}
