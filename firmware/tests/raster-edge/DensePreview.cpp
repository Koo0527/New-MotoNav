// Offline source view: actual dense shader and production palette, no HUD.
#include <cassert>
#include <cstdio>
#include <string>
#include <vector>
#include "DenseCell.h"
#include "../../boards/175/MotoNav/GameMapStyle.h"
static std::vector<uint8_t> read(const char *path,size_t size){
 FILE *f=fopen(path,"rb");assert(f);std::vector<uint8_t> data(size);
 assert(fread(data.data(),1,size,f)==size && fgetc(f)==EOF);fclose(f);return data;
}
int main(int argc,char **argv){
 assert(argc==5);auto old=read(argv[1],1440000),raw=read(argv[2],1440000),words=read(argv[3],720000);
 auto p=GameMapStyle::palette(1,false);uint16_t pal[8]={p.base,p.road,p.park,p.water,p.roof,p.outline,p.roof,p.outline};
 DenseCellLUT lut;const float scale=.6f;
 for(int angle:{0,45,90}){
  const float theta=angle*3.14159265358979323846f/180,cs=cosf(theta),sn=sinf(theta);
  assert(lut.prepare(pal,1/(scale*4),theta));
  for(int mode=0;mode<3;mode++){
   const char *name=mode==0?"current4m":mode==1?"candidate2m":"denseC";
   std::string path=std::string(argv[4])+"/"+name+"-"+std::to_string(angle)+".ppm";
   FILE *f=fopen(path.c_str(),"wb");assert(f);fprintf(f,"P6\n424 424\n255\n");
   for(int y=0;y<424;y++)for(int x=0;x<424;x++){
    // Same world transform in every panel; 1200x1200 source has 2m pixels.
    float rx=(x+.5f-212)/scale,ry=(212-y-.5f)/scale;
    float u=600+(rx*cs+ry*sn)/2,v=600-(-rx*sn+ry*cs)/2;
    uint16_t color=pal[0];
    if(u>=0 && v>=0 && u<1200 && v<1200){
     if(mode<2){uint8_t material=(mode==0?old:raw)[size_t(v)*1200+size_t(u)];assert(material<8);color=pal[material];}
     else {int32_t U=int32_t(u*.5f*65536),V=int32_t(v*.5f*65536);uint16_t w=rasterEdgeU16(words.data()+2*((V>>16)*600+(U>>16)));assert(denseCellValid(w));color=lut.color(w,U,V);}
    }
    uint8_t rgb[3]={uint8_t((color>>11)*255/31),uint8_t(((color>>5)&63)*255/63),uint8_t((color&31)*255/31)};
    assert(fwrite(rgb,1,3,f)==3);
   }
   assert(fclose(f)==0);
  }
 }
}
