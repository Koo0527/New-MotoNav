#include <algorithm>
#include <cassert>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>
#include <chrono>
#undef assert
#define assert(condition) do {if(!(condition)){fprintf(stderr,"CHECK FAILED line %d: %s\n",__LINE__,#condition);abort();}} while(false)
using std::min;using std::max;
#define PI 3.14159265358979323846
#define RASTER_BUF_BYTES 720000
#define RASTER_MAX_PX 1440000
#define RASTER_MAX_BYTES (500 * 1024)
#define MOTONAV_RASTER_SMOOTHING 0
#include "../../boards/175/MotoNav/RasterWork.h"
#include "../../boards/175/MotoNav/GameMapStyle.h"
#include <string>
struct tinfl_decompressor{};using tinfl_status=int;
constexpr int TINFL_FLAG_PARSE_ZLIB_HEADER=1,TINFL_FLAG_USING_NON_WRAPPING_OUTPUT_BUF=2,TINFL_STATUS_DONE=0;
void tinfl_init(tinfl_decompressor*){}
int tinfl_decompress(tinfl_decompressor*,const uint8_t*,size_t*,uint8_t*,uint8_t*,size_t*,int){return -1;}
bool failAllocation=false;
struct {void printf(const char*,...){}} Serial;
constexpr int MALLOC_CAP_SPIRAM=1;
size_t heap_caps_get_largest_free_block(int){return 720000;}
void *ps_malloc(size_t n){return failAllocation?nullptr:malloc(n);}
unsigned long millis(){return 1;}
int32_t rd32(const uint8_t*p){return rasterI32(p);}uint16_t rdu16(const uint8_t*p){return rasterU16(p);}
bool rasterValid=false,rasterBackValid=false,navDirty=false;int themeIdx=1;
uint32_t mediaConnectionEpoch=1;
uint8_t *rasterBuf=nullptr,*rasterBackBuf=nullptr;
RasterHeader rasterBackHeader={};
int rasBW=0,rasX0=0,rasY0=0,rasW=0,rasH=0,rasterFrame=0;
float rasMpp=2;unsigned long rasterAt=0;
int rasterCancellationCount=0;
void cancelPendingRaster();
// Includes the production decoder unchanged. Only hardware/miniz services are stubbed.
#include "../../boards/175/MotoNav/src/map/RasterDecoder.h"
static inline uint16_t blendF(uint16_t a,uint16_t b,uint32_t t){
 unsigned r=((a>>11)*(256-t)+(b>>11)*t)>>8;
 unsigned g=(((a>>5)&63)*(256-t)+((b>>5)&63)*t)>>8;
 unsigned blue=((a&31)*(256-t)+(b&31)*t)>>8;return (r<<11)|(g<<5)|blue;
}
void u16(std::vector<uint8_t>&b,int n){b.push_back(n&255);b.push_back(n>>8&255);}
void i32(std::vector<uint8_t>&b,int n){for(int k=0;k<4;k++)b.push_back(uint32_t(n)>>(k*8)&255);}
std::vector<uint8_t> packet(const std::vector<uint8_t>&p,int n,int x=0,int y=0,bool roofs=false,int frame=1,int mm=2000,bool pal=false){
 std::vector<uint8_t>b;u16(b,frame);i32(b,x);i32(b,y);u16(b,n);u16(b,n);u16(b,mm|(roofs?0x4000:0)|(pal?0x8000:0));
 if(pal)for(int i=0;i<16;i++)u16(b,i*4096);
 for(size_t i=0;i<p.size();){size_t count=1;while(i+count<p.size()&&p[i+count]==p[i]&&count<271)count++;
  if(count<=15)b.push_back(((count-1)<<4)|p[i]);else{b.push_back(240|p[i]);b.push_back(count-16);}i+=count;}
 return b;
}
void deliver(const std::vector<uint8_t>&p){assert(parseRaster(p.data(),p.size()));}
uint8_t at(int x,int y){RasterHeader h={};h.width=rasW;h.height=rasH;h.blocksWide=rasBW;uint8_t c=255;assert(rasterRead(rasterBuf,h,x,y,c));return c;}
size_t roofCount(){size_t n=0;for(int y=0;y<rasH;y++)for(int x=0;x<rasW;x++)n+=at(x,y)>=4;return n;}

struct Bulk {int id=1,got=0;bool done=false;uint8_t *buf=nullptr;uint8_t mask[8]={};};
Bulk bulks[5];
#include "../../boards/175/MotoNav/src/protocol/AckFifo.h"
AckFifo pendingAck;
static std::string String(int n){return std::to_string(n);}
bool bleConnected=true,bleAuthed=true;
uint32_t ticks=0;
static uint32_t micros(){return ticks+=1000;}

#include "../../boards/175/MotoNav/src/map/RasterWorkQueue.h"
static void finish(){for(int i=0;pendingRasterWork.active && i<10000;i++)pollRasterWork();assert(!pendingRasterWork.active);}

constexpr int LCD_WIDTH=466,LCD_HEIGHT=466,CX=233,MAP_PY=262,ST_MINIMAL=5,ST_PIXEL=7;
bool nightOn=false;
int styleIdx(){return nightOn && themeIdx==4?3:themeIdx;}
uint16_t framePixels[LCD_WIDTH*LCD_HEIGHT];
struct {uint16_t *getFramebuffer(){return framePixels;}} display;
auto *gfx=&display;
struct {int left[LCD_HEIGHT],right[LCD_HEIGHT];} mapCircleRows;
#define C_BLOCK (themeIdx>=1 && themeIdx<=3?GameMapStyle::palette(themeIdx,nightOn).base:123)
#define C_ROADM (themeIdx>=1 && themeIdx<=3?GameMapStyle::palette(themeIdx,nightOn).road:456)
#define C_PARK (GameMapStyle::palette(themeIdx,nightOn).park)
#define C_WATER (GameMapStyle::palette(themeIdx,nightOn).water)
#define C_BLACK 0
void parallelRows(void (*fn)(int,int,int),int a,int b){fn(a,b,1);}
#include "../../boards/175/MotoNav/src/map/RasterRenderer.h"
void render(){drawRasterMap(1200,-1200,1,1,0);}
std::vector<uint8_t> semantic(const std::vector<uint8_t>&pixels,bool roofs=false,int x=0,int y=0) {
 auto b=packet(pixels,1200,x,y,false,1,2000,true);
 b[44]=0x4e;b[45]=0x4d;b[46]=roofs?0x11:1;b[47]=0x52;return b;
}
int main(){
 std::vector<uint8_t> pixels(1200*1200,0);pixels[0]=8;pixels[1]=9;pixels[2]=10;
 auto base=semantic(pixels);RasterHeader h={};
 assert(rasterCheck(base.data(),base.size(),h,1440000,720000));assert(h.semantic && !h.buildings && h.palette);
 for(int y=0;y<LCD_HEIGHT;y++){mapCircleRows.left[y]=233;mapCircleRows.right[y]=233;}
 setRasterBuildingCarry(true);deliver(base);assert(rasSemantic && at(0,0)==8 && at(1,0)==9 && at(2,0)==10);
 // All six theme combinations use their actual theme, with no fixed wire colors.
 for(int theme=1;theme<=3;theme++)for(bool night:{false,true}) {
   auto p=GameMapStyle::palette(theme,night);uint16_t c[16]={p.base,p.road};GameMapStyle::roadPalette(theme,night,c);
   int k=night?(theme==1?45:75):100;
   assert(c[8]==GameMapStyle::rgb(GameMapStyle::dim(theme==1?0x101012:theme==2?0xC6CACA:0x388281,k)));
   assert(c[9]==GameMapStyle::rgb(GameMapStyle::dim(theme==1?0x444448:theme==2?0x707A7A:0x214648,k)));
   assert(c[10]==p.base);
 }
 for(int theme:{0,4,5,6,7,8,9,10,11}) {uint16_t c[16]={123,456};GameMapStyle::roadPalette(theme,true,c);assert(c[8]==456 && c[9]==456 && c[10]==123);}
 pixels[0]=11;auto v2=semantic(pixels);v2[46]=2;
 assert(rasterCheck(v2.data(),v2.size(),h,1440000,720000) && h.semanticVersion==2);
 deliver(v2);assert(currentRasterHeader().semanticVersion==2 && at(0,0)==11);
 for(int theme=1;theme<=3;theme++)for(bool night:{false,true}) {
  themeIdx=theme;nightOn=night;render();int k=night?(theme==1?45:75):100;
  assert(RM.pal[8]==GameMapStyle::rgb(GameMapStyle::dim(theme==1?0x202023:theme==2?0x707A7A:0x214648,k)));
  assert(RM.pal[9]==GameMapStyle::rgb(GameMapStyle::dim(theme==1?0x404044:theme==2?0x9AA4A4:0x388281,k)));
  assert(RM.pal[11]==GameMapStyle::rgb(GameMapStyle::dim(theme==1?0x606065:theme==2?0xC6CACA:0x50AAA8,k)));
 }
 themeIdx=2;nightOn=false;deliver(base);assert(rasterBackValid && rasterBackHeader.semanticVersion==2);render();
 assert(RM.pal[8]==GameMapStyle::rgb(0xC6CACA) && RM.backPal[8]==GameMapStyle::rgb(0x707A7A));
 deliver(v2);assert(rasterBackHeader.semanticVersion==1);render();
 assert(RM.pal[8]==GameMapStyle::rgb(0x707A7A) && RM.backPal[8]==GameMapStyle::rgb(0xC6CACA));
 setRasterBuildingCarry(false);assert(at(0,0)==11 && currentRasterHeader().semanticVersion==2);setRasterBuildingCarry(true);
 for(int idx=12;idx<16;idx++){pixels[0]=idx;auto invalid=semantic(pixels);invalid[46]=2;assert(!parseRaster(invalid.data(),invalid.size()));}
 pixels[0]=8;deliver(base);themeIdx=1;nightOn=false;
 for(int version:{1,2})for(int length:{480000,480001}) {
  auto boundary=base;boundary.resize(48);boundary[46]=version;
  int runs=length-48, extra=1440000-runs*3;
  for(int i=0;i<runs;i++)boundary.push_back(i<extra?0x30:0x20);
  assert(boundary.size()==(size_t)length);
  assert(rasterCheck(boundary.data(),boundary.size(),h,1440000,720000)==(length==480000));
  if(length==480001){boundary[47]=0x53;assert(rasterCheck(boundary.data(),boundary.size(),h,1440000,720000));}
 }
 auto bad=base;bad[46]=3;assert(!parseRaster(bad.data(),bad.size()));bad[46]=0x13;assert(!parseRaster(bad.data(),bad.size()));assert(rasSemantic && at(2,0)==10);
 bad=base;bad.pop_back();assert(!parseRaster(bad.data(),bad.size()) && rasSemantic && at(2,0)==10);
 bad=base;bad[10]=1;assert(!parseRaster(bad.data(),bad.size()));
 bad=base;bad[14]=0xd1;assert(!parseRaster(bad.data(),bad.size()));
 bad=base;bad.push_back(0);assert(!rasterCheck(bad.data(),bad.size(),h,1440000,720000));
 bad=base;bad[46]=0x11;assert(!parseRaster(bad.data(),bad.size()));
 for(int idx=11;idx<16;idx++){pixels[0]=idx;bad=semantic(pixels);assert(!parseRaster(bad.data(),bad.size()));}pixels[0]=8;
 pixels[1200+5]=4;bad=semantic(pixels);assert(!parseRaster(bad.data(),bad.size()));
 auto roofs=semantic(pixels,true);deliver(roofs);assert(currentRasterHeader().buildings);
 // Actual production renderer selects dynamic semantic colors and original photo behavior.
 for(int theme=1;theme<=3;theme++)for(bool night:{false,true}) {
   themeIdx=theme;nightOn=night;render();assert(RM.pal[10]==GameMapStyle::palette(theme,night).base);
   uint16_t c[16]={RM.pal[0],RM.pal[1]};GameMapStyle::roadPalette(theme,night,c);assert(RM.pal[8]==c[8] && RM.pal[9]==c[9]);
   const int x=(int)((1200+0.5f)/2),y=(int)((1200-0.5f)/2);assert(framePixels[262*466+233]==RM.pal[at(x,y)]);
 }
 themeIdx=4;nightOn=true;render();assert(RM.pal[8]==456 && RM.pal[10]==123);themeIdx=1;nightOn=false;
 // Generic photo colors, including unknown markers outside the reserved family, retain their old meaning.
 auto photo=roofs;photo[47]=0x53;deliver(photo);themeIdx=0;nightOn=true;render();assert(RM.pal[8]==rasPal[8]);themeIdx=2;render();assert(RM.pal[8]==blendF(rasPal[8],0,110));themeIdx=1;nightOn=false;assert(!rasSemantic && !currentRasterHeader().buildings && !rasterBackValid);
 deliver(roofs);assert(!rasterBackValid);
 // Old semantic source 8/9/10 must never become roofs; destination protected pixels remain unchanged.
 std::fill(pixels.begin(),pixels.end(),4);pixels[0]=8;pixels[1]=9;pixels[2]=10;roofs=semantic(pixels,true);deliver(roofs);
 deliver(base);assert(rasterBackValid && currentRasterHeader().buildings && at(3,0)==4);
 assert(at(0,0)==8 && at(1,0)==9 && at(2,0)==10);
 setRasterBuildingCarry(false);assert(!currentRasterHeader().buildings && currentRasterHeader().semantic && at(3,0)==0 && at(2,0)==10);
 uint8_t c=255;assert(rasterRead(rasterBackBuf,rasterBackHeader,3,0,c)&&c==0);assert(rasterBackHeader.semantic && !rasterBackHeader.buildings);
 deliver(roofs);assert(!currentRasterHeader().buildings && at(3,0)==0 && at(0,0)==8 && at(2,0)==10);
 // Sliced production queue is atomic, toggles cancel work, and late packets are stripped at publication.
 setRasterBuildingCarry(true);bulks[3].id=5;bulks[3].buf=roofs.data();auto *front=rasterBuf;
 assert(queueRasterWork(roofs.data(),roofs.size(),5));pollRasterWork();assert(pendingRasterWork.active && rasterBuf==front);
 setRasterBuildingCarry(false);assert(!pendingRasterWork.active && rasterBuf==front);
 assert(queueRasterWork(roofs.data(),roofs.size(),5));finish();assert(at(3,0)==0 && at(2,0)==10 && !currentRasterHeader().buildings);
 setRasterBuildingCarry(true);deliver(roofs);
 auto old=packet(std::vector<uint8_t>(1200*1200,0),1200);deliver(old);assert(!rasSemantic && currentRasterHeader().buildings && at(3,0)==4 && at(0,0)==0 && at(1,0)==0 && at(2,0)==0);
 // When the new ordinary map ends before the prior semantic map, its edge still uses semantic road colors.
 deliver(base);auto shifted=packet(std::vector<uint8_t>(1200*1200,0),1200,2,0);deliver(shifted);assert(rasterBackValid && rasterBackHeader.semantic && !rasSemantic);
 themeIdx=2;render();assert(RM.pal[8]==GameMapStyle::rgb(0xC6CACA) && RM.pal[9]==GameMapStyle::rgb(0x707A7A));themeIdx=1;
 deliver(roofs);deliver(old);
 // Regular -> semantic carries the same old 4...7 values and world-coordinate shift.
 deliver(semantic(std::vector<uint8_t>(1200*1200,0),false,2,0));assert(rasSemantic && currentRasterHeader().buildings && at(2,0)==4);
 setRasterBuildingCarry(false);deliver(packet(std::vector<uint8_t>(1200*1200,4),1200,0,0,true));assert(!currentRasterHeader().buildings && at(3,0)==0);
 // Actual front and back samples use the palette belonging to each frame.
 auto solid1=semantic(std::vector<uint8_t>(1200*1200,8),false,0,0);
 auto solid2=semantic(std::vector<uint8_t>(1200*1200,8),false,2,0);solid2[46]=2;
 themeIdx=2;nightOn=false;deliver(solid1);deliver(solid2);
 drawRasterMap(0,0,1,1,0);assert(framePixels[262*466+233]==GameMapStyle::rgb(0xC6CACA));
 drawRasterMap(2,0,1,1,0);assert(framePixels[262*466+233]==GameMapStyle::rgb(0x707A7A));
 solid1=semantic(std::vector<uint8_t>(1200*1200,8),false,2,0);
 solid2=semantic(std::vector<uint8_t>(1200*1200,8),false,0,0);solid2[46]=2;
 deliver(solid2);deliver(solid1);
 drawRasterMap(0,0,1,1,0);assert(framePixels[262*466+233]==GameMapStyle::rgb(0x707A7A));
 drawRasterMap(2,0,1,1,0);assert(framePixels[262*466+233]==GameMapStyle::rgb(0xC6CACA));
 auto eleven=semantic(std::vector<uint8_t>(1200*1200,11));eleven[46]=2;deliver(eleven);
 themeIdx=5;drawRasterMap(1200,-1200,1,1,0);assert(framePixels[262*466+233]==0x8410);
 themeIdx=4;nightOn=true;drawRasterMap(1200,-1200,1,1,0);assert(framePixels[262*466+233]==C_ROADM);
 std::vector<uint8_t> withRoof(1200*1200,11);withRoof[3]=4;
 auto v2roof=semantic(withRoof,true);v2roof[46]=0x12;themeIdx=1;nightOn=false;setRasterBuildingCarry(true);deliver(v2roof);
 assert(currentRasterHeader().semanticVersion==2 && at(0,0)==11 && at(3,0)==4);
 setRasterBuildingCarry(false);assert(currentRasterHeader().semanticVersion==2 && at(0,0)==11 && at(3,0)==0);
 bulks[3].id=8;bulks[3].buf=v2roof.data();assert(queueRasterWork(v2roof.data(),v2roof.size(),8));finish();
 assert(currentRasterHeader().semanticVersion==2 && at(0,0)==11 && at(3,0)==0);
 assert(queueRasterWork(v2roof.data(),v2roof.size(),8));pollRasterWork();setRasterBuildingCarry(true);
 assert(!pendingRasterWork.active && currentRasterHeader().semanticVersion==2 && at(0,0)==11);
 free(rasterBuf);free(rasterBackBuf);
 puts("PASS production road palette validation, decoding, colors, carry, clearing, atomic queue, late packets and regular/photo transitions");
}
