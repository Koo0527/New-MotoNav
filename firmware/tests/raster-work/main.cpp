#include <algorithm>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstdint>
#include <cstring>
#include <random>
#include <vector>
namespace ref {
#include "reference/RasterContinuity.h"
#include "reference/RasterBuildingCarry.h"
}
namespace fast {
#include "../../boards/175/MotoNav/RasterContinuity.h"
#include "../../boards/175/MotoNav/RasterBuildingCarry.h"
#include "../../boards/175/MotoNav/RasterWork.h"
}
static int checks=0;
static void check(bool ok,const char*what){checks++;if(!ok){fprintf(stderr,"FAIL %s after %d checks\n",what,checks);exit(1);}}
static void u16(std::vector<uint8_t>&p,int n){p.push_back(n&255);p.push_back((n>>8)&255);}
static void i32(std::vector<uint8_t>&p,int n){for(int i=0;i<4;i++)p.push_back((uint32_t)n>>(i*8)&255);}
static std::vector<uint8_t> packet(const std::vector<uint8_t>&pixels,int w,int h,bool roofs=false,bool pal=false,int x=0,int y=0){
 std::vector<uint8_t>p;u16(p,73);i32(p,x);i32(p,y);u16(p,w);u16(p,h);u16(p,2000|(roofs?0x4000:0)|(pal?0x8000:0));
 if(pal)for(int i=0;i<16;i++)u16(p,i*137);
 for(size_t i=0;i<pixels.size();){size_t n=1;while(i+n<pixels.size()&&pixels[i+n]==pixels[i]&&n<271)n++;
  if(n<=15)p.push_back(((n-1)<<4)|pixels[i]);else{p.push_back(0xf0|pixels[i]);p.push_back(n-16);}i+=n;}
 return p;
}
static void decodeCase(int w,int h,int mode,std::mt19937&rng){
 bool pal=mode==7,roofs=mode>=4&&!pal;std::vector<uint8_t>pixels((size_t)w*h);
 for(int y=0;y<h;y++)for(int x=0;x<w;x++){
  uint8_t c=0;switch(mode){case 0:c=0;break;case 1:c=1;break;case 2:c=((x/3+y/7)%3);break;case 3:c=(x%23==0||y%19==0)?1:0;break;case 4:c=4;break;case 5:c=(x/11+y/13)%8;break;case 6:c=rng()%8;break;case 7:c=rng()%16;break;}pixels[(size_t)y*w+x]=c;
 }
 auto p=packet(pixels,w,h,roofs,pal);ref::RasterHeader a={};fast::RasterHeader b={};
 check(ref::rasterCheck(p.data(),p.size(),a,1440000,720000),"reference accepts generated packet");
 check(fast::rasterCheck(p.data(),p.size(),b,1440000,720000),"fast accepts same packet");
 std::vector<uint8_t>x(a.bytes+32,0xa5),y(b.bytes+32,0xa5);
 ref::rasterDecode(p.data(),a,x.data()+16);fast::rasterDecode(p.data(),b,y.data()+16);
 check(x==y,"complete decoded byte buffer including padding/canaries matches");
 std::fill(y.begin(),y.end(),0xa5);fast::RasterDecodeCursor cursor;
 const uint32_t budgets[]={1,3,17,127,4096};const uint32_t budget=budgets[mode%5];
 int steps=0;while(!fast::rasterDecodeStep(p.data(),b,y.data()+16,cursor,budget)){
   check(++steps<((int)b.bytes+w*h+2)/(int)budget+4,"incremental decoder makes bounded progress");
 }
 check(x==y,"incremental decode exactly matches synchronous baseline at small/odd budgets");
 for(int k=0;k<16;k++)check(x[k]==0xa5&&x[x.size()-1-k]==0xa5,"decoder bounds preserved");
}
static void carryCase(int w,int h,int nw,int nh,int ox,int oy,int flags,std::mt19937&rng){
 std::vector<uint8_t>old((size_t)w*h),next((size_t)nw*nh);
 for(auto&v:old)v=rng()%8;
 for(size_t i=0;i<next.size();i++)next[i]=i%5?((rng()%2)*2):(rng()%((flags&1)?8:4));
 auto p=packet(old,w,h,true),q=packet(next,nw,nh,flags&1,false,ox*2,-oy*2);
 ref::RasterHeader a={},b={};fast::RasterHeader c={},d={};
 check(ref::rasterCheck(p.data(),p.size(),a,1440000,720000)&&ref::rasterCheck(q.data(),q.size(),b,1440000,720000),"carry headers valid");
 check(fast::rasterCheck(p.data(),p.size(),c,1440000,720000)&&fast::rasterCheck(q.data(),q.size(),d,1440000,720000),"fast carry headers valid");
 std::vector<uint8_t>src(a.bytes+32,0xa5),x(b.bytes+32,0xa5),y(d.bytes+32,0xa5);
 ref::rasterDecode(p.data(),a,src.data()+16);ref::rasterDecode(q.data(),b,x.data()+16);fast::rasterDecode(q.data(),d,y.data()+16);
 if(flags&2){a.palette=true;c.palette=true;}if(flags&4){b.frame++;d.frame++;}if(flags&8){b.x0++;d.x0++;}if(flags&16){a.buildings=false;c.buildings=false;}
 auto n=ref::rasterCarryRoofs(src.data()+16,a,x.data()+16,b);auto m=fast::rasterCarryRoofs(src.data()+16,c,y.data()+16,d);
 check(n==m&&b.buildings==d.buildings,"same retained roof count and flags");check(x==y,"same carried pixels including partial tiles and canaries");
 std::fill(y.begin(),y.end(),0xa5);fast::RasterHeader fresh={};check(fast::rasterCheck(q.data(),q.size(),fresh,1440000,720000),"job header valid");
 fresh.frame=d.frame;fresh.x0=d.x0; // Mirror the deliberate guard mutations.
 const auto immutable=src;fast::RasterWork work;fast::rasterWorkBegin(work,q.data(),fresh,y.data()+16,src.data()+16,c,true);
 while(!fast::rasterWorkStep(work,127,1)){}
 check(x==y && n==work.carry.retained && b.buildings==work.next.buildings,"bounded decode/carry job preserves exact output and flags");
 check(src==immutable,"incremental work never mutates visible source map");
 const auto complete=y;check(fast::rasterWorkStep(work,1,1)&&complete==y,"completed work is idempotent");
 fast::rasterWorkBegin(work,q.data(),fresh,y.data()+16,src.data()+16,c,true);
 fast::rasterWorkStep(work,3,1);fast::rasterWorkCancel(work);
 const auto cancelled=y;check(!fast::rasterWorkStep(work,4096,8)&&cancelled==y&&!work.active,"cancelled work cannot continue or complete");
 fast::rasterWorkBegin(work,q.data(),fresh,y.data()+16,src.data()+16,c,true);
 while(!fast::rasterWorkStep(work,4096,7)){}
 check(x==y,"restart after partial cancellation starts with a clean output buffer");
}
template<class F>static double bench(F f,int count){auto t=std::chrono::steady_clock::now();for(int i=0;i<count;i++)f();return std::chrono::duration<double,std::milli>(std::chrono::steady_clock::now()-t).count()/count;}
int main(){std::mt19937 rng(0x12ab34cd);
 int ws[]={1,2,3,15,16,17,31,32,33,63,127,1199,1200};int hs[]={1,3,16,17,65};
 for(int w:ws)for(int h:hs)for(int mode=0;mode<8;mode++)decodeCase(w,h,mode,rng);
 for(int mode=0;mode<8;mode++)decodeCase(1200,1200,mode,rng);
 for(int i=0;i<400;i++){int w=1+rng()%150,h=1+rng()%90,nw=1+rng()%150,nh=1+rng()%90;
  carryCase(w,h,nw,nh,(int)(rng()%(w+nw))-nw,(int)(rng()%(h+nh))-nh,i%32,rng);}
 int offsets[]={-1199,-600,-300,-17,-16,-15,-1,0,1,15,16,17,300,600,1199,1200};
 for(int ox:offsets)carryCase(1200,1200,1200,1200,ox,ox/2,0,rng);
 std::vector<uint8_t>pixels(1200*1200,1);for(int y=0;y<1200;y++)for(int x=0;x<1200;x++)if((x%100)>15&&(y%100)>15)pixels[y*1200+x]=4;
 auto p=packet(pixels,1200,1200,true);ref::RasterHeader a={};fast::RasterHeader b={};ref::rasterCheck(p.data(),p.size(),a,1440000,720000);fast::rasterCheck(p.data(),p.size(),b,1440000,720000);
 std::vector<uint8_t>x(a.bytes),y(b.bytes);
 double oldMs=bench([&]{ref::rasterDecode(p.data(),a,x.data());},20),newMs=bench([&]{fast::rasterDecode(p.data(),b,y.data());},20);
 check(x==y,"benchmark output identical");
 printf("PASS %d checks: production decoded/carried buffers match reference byte-for-byte, including partial tiles, odd shifts, palettes, frame guards and buffer canaries\n",checks);
 printf("HOST decode benchmark %.3f -> %.3f ms (%.2fx); host timing is NOT ESP32 frame timing\n",oldMs,newMs,oldMs/newMs);
 return 0;
}
