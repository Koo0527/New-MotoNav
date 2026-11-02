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
#define MOTONAV_RASTER_SMOOTHING 1
#include "../../boards/175/MotoNav/RasterWork.h"
#include "../../boards/175/MotoNav/GameMapStyle.h"
#include <string>
struct tinfl_decompressor{};using tinfl_status=int;
constexpr int TINFL_FLAG_PARSE_ZLIB_HEADER=1,TINFL_FLAG_USING_NON_WRAPPING_OUTPUT_BUF=2,TINFL_STATUS_DONE=0;
void tinfl_init(tinfl_decompressor*){}
int tinfl_decompress(tinfl_decompressor*,const uint8_t*,size_t*,uint8_t*,uint8_t*,size_t*,int){return -1;}
bool failAllocation=false;
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
static inline uint16_t blendF(uint16_t a,uint16_t,uint32_t){return a;}
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
std::string pendingAck;
static std::string String(int n){return std::to_string(n);}
bool bleConnected=true,bleAuthed=true;
uint32_t ticks=0;
static uint32_t micros(){return ticks+=1000;}
struct {void printf(const char*,...){}} Serial;
#include "../../boards/175/MotoNav/src/map/RasterWorkQueue.h"
static void finish(){for(int i=0;pendingRasterWork.active && i<10000;i++)pollRasterWork();assert(!pendingRasterWork.active);}
static uint16_t sample(int32_t u,int32_t v,const uint16_t *pal,const uint8_t *back=nullptr,const RasterHeader &bh={}) {
 auto h=currentRasterHeader();uint8_t index=0;rasterSmoothRead(rasterBuf,h,back,bh,u>>16,v>>16,index);
 return rasterSmoothColor(rasterBuf,h,rasterTiles,back,bh,pal,u,v,pal[index]);
}
int main(){
 std::vector<uint8_t> pixels(32*32,0);
 for(int y=0;y<32;y++)for(int x=16;x<32;x++)pixels[y*32+x]=1;
 deliver(packet(pixels,32));assert(rasterTilesValid && rasterTiles[0]==0 && rasterTiles[1]==1);
 uint16_t pal[16]={0xf800,0x001f,0x07e0};
 assert(sample(8*65536,8*65536,pal)==pal[0]);
 assert(sample(16*65536,8*65536,pal)==0x8010); // Color, never material-index interpolation.
 assert(sample(16*65536+32768,8*65536,pal)==pal[1]);
 // The shortcut must not hide the transition between two individually pure tiles.
 for(int theme=1;theme<=3;theme++)for(bool night:{false,true}) {
   auto p=GameMapStyle::palette(theme,night);pal[0]=p.base;pal[1]=p.road;
   uint16_t c[4]={p.base,p.road,p.base,p.road};
   assert(sample(16*65536,8*65536,pal)==rasterColorMix(c,128,128));
 }
 // A partially unavailable neighborhood retains the existing nearest edge color.
 assert(sample(0,8*65536,pal)==pal[0]);
 auto front=currentRasterHeader();auto bh=front;bh.x0=-64;
 std::vector<uint8_t> back(front.bytes,0x11);
 assert(sample(0,8*65536,pal,back.data(),bh)!=pal[0]);
 bh.mm=4000;assert(sample(0,8*65536,pal,back.data(),bh)==pal[0]);
 bh=front;bh.x0=-64;bh.frame++;assert(sample(0,8*65536,pal,back.data(),bh)==pal[0]);
 bh=front;bh.x0=-64;bh.palette=true;assert(sample(0,8*65536,pal,back.data(),bh)==pal[0]);
 bh=front;bh.x0=-63;assert(sample(0,8*65536,pal,back.data(),bh)==pal[0]);
 // Padding in partial tiles must not turn a uniform tile into a mixed tile.
 {std::vector<uint8_t> edge(17*17,2);auto q=packet(edge,17);RasterHeader eh={};
  assert(rasterCheck(q.data(),q.size(),eh,1440000,720000));
  std::vector<uint8_t> data(eh.bytes),table(eh.bytes/128,255);rasterDecode(q.data(),eh,data.data());
  size_t scanned=0;while(!rasterTileScan(data.data(),eh,table.data(),scanned,1)){}
  assert(std::all_of(table.begin(),table.end(),[](uint8_t v){return v==2;}));}
 // Independent scalar color reference exercises direct packed addresses across
 // both tile axes, rotations, source edges and all day/night game palettes.
 for(int y=0;y<32;y++)for(int x=0;x<32;x++)pixels[y*32+x]=(x*7+y*3)%8;
 deliver(packet(pixels,32,0,0,true));
 for(int theme=1;theme<=3;theme++)for(bool night:{false,true})for(int angle:{0,45,90}) {
   auto p=GameMapStyle::palette(theme,night);
   uint16_t colors[16]={p.base,p.road,p.park,p.water,p.roof,p.outline,p.roof,p.outline};
   const auto h=currentRasterHeader();const double a=angle*PI/180;
   for(int row=-20;row<=20;row++)for(int col=-20;col<=20;col++) {
     int32_t u=(int32_t)((16+cos(a)*col-sin(a)*row)*65536);
     int32_t v=(int32_t)((16+sin(a)*col+cos(a)*row)*65536);
     int x=(int)floor((double)u/65536-0.5),y=(int)floor((double)v/65536-0.5);
     uint8_t nearest=0;rasterRead(rasterBuf,h,u>>16,v>>16,nearest);
     uint16_t expected=colors[nearest];uint8_t ids[4];bool valid=true;
     for(int i=0;i<4;i++)valid=rasterRead(rasterBuf,h,x+(i%2),y+(i/2),ids[i]) && valid;
     if(valid) {
       unsigned fx=(unsigned)floor(((double)u/65536-0.5-x)*256);
       unsigned fy=(unsigned)floor(((double)v/65536-0.5-y)*256);
       uint32_t r=0,g=0,b=0;
       for(int i=0;i<4;i++) {
         uint32_t w=(i%2?fx:256-fx)*(i/2?fy:256-fy);uint16_t c=colors[ids[i]];
         r+=(c>>11)*w;g+=((c>>5)&63)*w;b+=(c&31)*w;
       }
       expected=(((r+32768)/65536)<<11)|(((g+32768)/65536)<<5)|((b+32768)/65536);
     }
     assert(sample(u,v,colors)==expected);
   }
 }
 // Real sliced work: metadata describes the final carried roof pixels, not base RLE.
 std::fill(pixels.begin(),pixels.end(),4);deliver(packet(pixels,32,0,0,true));
 std::fill(pixels.begin(),pixels.end(),0);auto base=packet(pixels,32);
 std::vector<uint8_t> out(512),tiles(4,0xaa);RasterWork work;
 auto h=currentRasterHeader();RasterHeader next={};assert(rasterCheck(base.data(),base.size(),next,1440000,720000));
 rasterWorkBegin(work,base.data(),next,out.data(),rasterBuf,h,true,tiles.data());
 while(!work.carried)rasterWorkStep(work,1,1);
 while(!rasterWorkStep(work,1,1)){}
 assert(std::all_of(tiles.begin(),tiles.end(),[](uint8_t t){return t==4;}));
 rasterWorkBegin(work,base.data(),next,out.data(),rasterBuf,h,true,tiles.data());
 rasterWorkStep(work,1,1);rasterWorkCancel(work);auto stopped=out;
 assert(!rasterWorkStep(work) && out==stopped && !work.tiles);
 // Actual queue + actual install: no table or visible buffer changes before commit.
 std::vector<uint8_t> full(1200*1200,1);auto large=packet(full,1200);
 bulks[3].buf=large.data();bulks[3].id=1;
 auto *oldPixels=rasterBuf,*oldTiles=rasterTiles;auto oldHeader=currentRasterHeader();
 assert(queueRasterWork(large.data(),large.size(),1));pollRasterWork();
 assert(pendingRasterWork.active && rasterBuf==oldPixels && rasterTiles==oldTiles);
 ++mediaConnectionEpoch;pollRasterWork();
 assert(!pendingRasterWork.active && rasterBuf==oldPixels && rasterTiles==oldTiles && rasterTilesValid);
 assert(queueRasterWork(large.data(),large.size(),1));
 while(!pendingRasterWork.carried || !pendingRasterWork.scanned)pollRasterWork();
 assert(pendingRasterWork.active && rasterBuf==oldPixels && rasterTiles==oldTiles);
 ++mediaConnectionEpoch;pollRasterWork();
 assert(!pendingRasterWork.active && rasterBuf==oldPixels && rasterTiles==oldTiles);
 assert(queueRasterWork(large.data(),large.size(),1));finish();
 assert(rasterTilesValid && rasterBuf!=oldPixels && rasterTiles!=oldTiles && rasW==1200);
 assert(std::all_of(rasterTiles,rasterTiles+5625,[](uint8_t t){return t==1;}));
 // A missing optional allocation never rejects a map or publishes a partial table.
 free(rasterBackTiles);rasterBackTiles=nullptr;failAllocation=true;
 assert(queueRasterWork(large.data(),large.size(),1));finish();
 assert(rasterValid && !rasterTilesValid && !rasterTiles);failAllocation=false;
 assert(queueRasterWork(large.data(),large.size(),1));finish();assert(rasterTilesValid);
 themeIdx=0;assert(queueRasterWork(large.data(),large.size(),1));
 assert(!pendingRasterWork.tiles);finish();assert(!rasterTilesValid);themeIdx=1;
 auto satellite=packet(pixels,32,0,0,false,1,2000,true);deliver(satellite);assert(!rasterTilesValid);
 setRasterBuildingCarry(false);assert(!rasterTilesValid);
 // VCE compatibility invalidates plain-map metadata even when its decoder falls back.
 auto vce=base;vce.insert(vce.end(),{'V','C','E',1,0,0,0,0});deliver(vce);assert(!rasterTilesValid);
 // Host-only decode/metadata cost; this cannot approve the device frame budget.
 std::vector<uint8_t> scratch(720000),table(5625);
 RasterHeader benchHeader={};assert(rasterCheck(large.data(),large.size(),benchHeader,1440000,720000));
 auto bench=[&](bool metadata){auto start=std::chrono::steady_clock::now();
  for(int i=0;i<20;i++){RasterWork job;rasterWorkBegin(job,large.data(),benchHeader,scratch.data(),nullptr,{},false,metadata?table.data():nullptr);
   while(!rasterWorkStep(job)){} }
  return std::chrono::duration<double,std::milli>(std::chrono::steady_clock::now()-start).count()/20;};
 double without=bench(false),with=bench(true);
 printf("HOST uniform 1200-square sliced decode %.3f ms -> decode + tile scan %.3f ms; NOT ESP32 frame timing\n",without,with);
 free(rasterTiles);free(rasterBackTiles);free(rasterBuf);free(rasterBackBuf);
 printf("PASS production RGB565/tile boundary/seam, all 3 day/night palettes, sliced carry, atomic queue cancellation/commit, allocation failure and VCE fallback\n");
}
