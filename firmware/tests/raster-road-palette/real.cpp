// Hardware services come from the regression harness; decoder and renderer are production includes.
#define main roadPaletteRegressionMain
#include "main.cpp"
#undef main
#include <fstream>
#include <iterator>
#include "../../boards/175/MotoNav/CircleRowBounds.h"
static std::vector<uint8_t> load(const std::string &path){std::ifstream f(path,std::ios::binary);assert(f.good());return {std::istreambuf_iterator<char>(f),{}};}
static void writePPM(const std::string &path){std::ofstream f(path,std::ios::binary);f<<"P6\n424 424\n255\n";for(int y=21;y<445;y++)for(int x=21;x<445;x++){auto c=framePixels[y*466+x];char rgb[]={char(((c>>11)&31)*255/31),char(((c>>5)&63)*255/63),char((c&31)*255/31)};f.write(rgb,3);}}
int main(int argc,char**argv){assert(argc==2);std::string root=argv[1];setRasterBuildingCarry(true);
 CircleRowBounds<LCD_WIDTH,LCD_HEIGHT> bounds;bounds.init(CX,212.f);
 for(int y=0;y<LCD_HEIGHT;y++){mapCircleRows.left[y]=bounds.left[y];mapCircleRows.right[y]=bounds.right[y];}
 for(auto name:{"06-mingbo","01-dense","02-low-density","03-diagonal","04-interchange","05-waterfront"}){
  std::string dir=root+"/"+name;
  for(auto type:{"roads","building"}){auto bytes=load(dir+"/"+type+".bin"),expected=load(dir+"/"+type+".idx");RasterHeader h={};assert(rasterCheck(bytes.data(),bytes.size(),h,RASTER_MAX_PX,RASTER_BUF_BYTES));assert(h.semantic && h.bytes==720000);assert(expected.size()==1440000);rasterBackValid=false;rasterValid=false;deliver(bytes);for(int y=0;y<1200;y++)for(int x=0;x<1200;x++)assert(at(x,y)==expected[y*1200+x]);printf("decoded %s/%s exact=1440000 packedBytes=%d flags=%d semantic=%d roofs=%d\n",name,type,int(h.bytes),h.mm,rasSemantic,rasterCarriesBuildings);}
  if(std::string(name)!="06-mingbo" && std::string(name)!="01-dense")continue;
  for(int theme=1;theme<=3;theme++)for(int night=0;night<2;night++)for(int angle:{0,45,90}){
   themeIdx=theme;nightOn=night;for(auto type:{"old-building","building"}){
    auto bytes=load(dir+"/"+type+".bin");rasterBackValid=false;rasterValid=false;deliver(bytes);std::fill(std::begin(framePixels),std::end(framePixels),0);
    float radians=angle*PI/180;drawRasterMap(rasX0+1200,rasY0-1200,.38f,cosf(radians),sinf(radians));
    writePPM(dir+"/t"+std::to_string(theme)+"-n"+std::to_string(night)+"-a"+std::to_string(angle)+"-"+type+".ppm");
   }
  }
 }
}
