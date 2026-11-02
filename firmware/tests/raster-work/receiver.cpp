#include <algorithm>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <cstdio>
#include <string>
#include <vector>
#include "../../boards/175/MotoNav/RasterWork.h"

static int checks=0;
static void check(bool ok,const char *why){++checks;if(!ok){fprintf(stderr,"FAIL %s\n",why);exit(1);}}
static std::string String(int n){return std::to_string(n);}
static int32_t rd32(const uint8_t *p){return rasterI32(p);}
struct Bulk {int id=-1,parts=0,got=0;uint32_t total=0,cap=400000;bool done=false;uint8_t *buf=nullptr;uint8_t mask[512]={};};
Bulk bulks[5];
std::string pendingAck;
constexpr size_t RASTER_BUF_BYTES=720000;
constexpr uint32_t RASTER_MAX_PX=1440000;
bool rasterBackValid=true,rasterBuildingCarryOn=true,bleConnected=true,bleAuthed=true,navDirty=false;
int themeIdx=1,installed=0,routeCalls=0;
uint32_t mediaConnectionEpoch=1,ticks=0,interruptAt=0;
int diagnosticCount=0;unsigned long lastWallUs=0,lastProcessingUs=0,lastMaxUs=0;
uint8_t *rasterBuf=nullptr,*rasterBackBuf=nullptr,*mapShow=nullptr;
RasterHeader visible={};
struct {void printf(const char*,int,int,unsigned long wall,unsigned long processing,unsigned long slice) {++diagnosticCount;lastWallUs=wall;lastProcessingUs=processing;lastMaxUs=slice;}} Serial;
static uint32_t micros(){ticks+=1000;if(interruptAt && ticks>=interruptAt){interruptAt=0;++mediaConnectionEpoch;}return ticks;}
bool failAllocation=false;
static void *ps_malloc(size_t n){return failAllocation?nullptr:malloc(n);}
static RasterHeader currentRasterHeader(){return visible;}
static bool canKeepRaster(const RasterHeader &old,const RasterHeader &next){return old.frame==next.frame&&old.mm==next.mm&&!next.palette;}
static void installDecodedRaster(const uint8_t *,const RasterHeader &next,const RasterHeader &,bool){ticks+=700;std::swap(rasterBuf,rasterBackBuf);visible=next;rasterBackValid=true;++installed;}
bool geometryAccept=false;
static bool parseRaster(const uint8_t *,uint32_t){return geometryAccept;}
static void parseMap(const uint8_t *,uint32_t){}
static void parseRoute(const uint8_t *,uint32_t){++routeCalls;}
static void parseGhost(const uint8_t *,uint32_t){}
#include "../../boards/175/MotoNav/src/map/RasterWorkQueue.h"
#include "../../boards/175/MotoNav/src/protocol/BulkReceiver.h"
static void put(std::vector<uint8_t>&p,int at,uint32_t v,int bytes){for(int k=0;k<bytes;k++)p[at+k]=(v>>(k*8))&255;}
static std::vector<uint8_t> packet(int x=0){
 std::vector<uint8_t>p(16);put(p,0,73,2);put(p,2,x,4);put(p,6,0,4);put(p,10,1200,2);put(p,12,1200,2);put(p,14,2000,2);
 for(int remain=1440000;remain;){int n=std::min(remain,271);if(n<=15)p.push_back((n-1)<<4);else{p.push_back(240);p.push_back(n-16);}remain-=n;}return p;
}
static std::vector<uint8_t> send(const std::vector<uint8_t>&p,int id,int type=3,int payload=485){
 std::vector<uint8_t>last;int parts=(p.size()+payload-1)/payload;
 for(int seq=0;seq<parts;seq++){
  int off=seq*payload,len=std::min<int>(payload,p.size()-off);std::vector<uint8_t>d(15+len);
  d[0]='M';d[1]=type;d[2]=id;put(d,3,parts,2);put(d,5,seq,2);put(d,7,p.size(),4);put(d,11,off,4);memcpy(d.data()+15,p.data()+off,len);
  handleBulk(d.data(),d.size());last=d;
 }return last;
}
int main(){
 std::vector<uint8_t>a(720000,0x44),b(720000,0xa5),packets(400000),other(400000);
 rasterBuf=a.data();rasterBackBuf=b.data();for(int kind=1;kind<=4;kind++)bulks[kind].buf=kind==3?packets.data():other.data();
 visible.frame=73;visible.width=visible.height=1200;visible.blocksWide=75;visible.bytes=720000;visible.mm=2000;visible.buildings=true;
 auto p=packet();const auto original=a;
 auto last=send(p,1);check(pendingRasterWork.active&&!bulks[3].done&&pendingAck.empty(),"complete wire packet schedules work without early ACK");
 check(!rasterBackValid&&a==original,"unfinished back map is hidden, front untouched");
 pollRasterWork();check(pendingRasterWork.active&&installed==0,"one bounded poll yields before whole full-size map finishes");
 auto cursor=pendingRasterWork.decode.emitted;
 handleBulk(last.data(),last.size());check(pendingRasterWork.decode.emitted==cursor&&pendingAck.empty()&&!bulks[3].done,"receipt probes do not restart work or falsely ACK");
 for(int limit=0;pendingRasterWork.active&&limit<1000;limit++){check(a==original,"front pixels stable throughout incremental work");pollRasterWork();}
 check(installed==1&&bulks[3].done&&pendingAck=="K,3,1","exactly one atomic commit and ACK after completion");
 check(visible.buildings&&std::all_of(b.begin(),b.end(),[](uint8_t v){return v==0x44;}),"all roofs inherited before commit");
 pendingAck.clear();handleBulk(last.data(),last.size());check(pendingAck=="K,3,1"&&installed==1,"completed duplicate repeats receipt without re-installing");
 pendingAck.clear();send(p,2);pollRasterWork();send(packet(2),3);
 check(pendingRasterId==3&&pendingRasterWork.decode.emitted==0&&!bulks[3].done,"new packet replaces incomplete job before compressed-buffer reuse");
 themeIdx=2;pollRasterWork();check(!pendingRasterWork.active&&!bulks[3].done&&bulks[3].got==0&&pendingAck.empty()&&installed==1,"style change cancels without old-map commit or ACK");themeIdx=1;
 send(p,4);++mediaConnectionEpoch;pollRasterWork();check(!pendingRasterWork.active&&installed==1,"connection epoch change cancels work");
 send(p,5);bleConnected=false;pollRasterWork();check(!pendingRasterWork.active&&installed==1,"disconnect cancels work");bleConnected=true;
 send(p,6);rasterBuildingCarryOn=false;pollRasterWork();check(!pendingRasterWork.active&&installed==1,"building preference change cancels work");rasterBuildingCarryOn=true;
 send(p,7);cancelPendingRaster();pollRasterWork();check(!pendingRasterWork.active&&bulks[3].got==0&&installed==1,"navigation reset discards incomplete job");
 pendingAck.clear();p.pop_back();send(p,8);check(!pendingRasterWork.active&&!bulks[3].done&&bulks[3].got==0&&installed==1,"invalid map is retryable and never acknowledged");
 check(pendingAck=="N,3,8","invalid map requests resend");
 send(packet(),8);check(pendingRasterWork.active,"same id full resend recovers N");cancelPendingRaster();
 send(packet(),9,2);check(routeCalls==1&&pendingAck=="K,2,9","route packets retain original immediate ACK behavior");
 // Both current phone senders use this 15-byte header, capped at 500 bytes
 // per message. Exercise full payload and reduced-MTU fallback sizes.
 int id=10;
 for(int payload : {5,185,300,485}) {
  pendingAck.clear();int previous=installed;auto tail=send(packet(),id,3,payload);
  check(pendingRasterWork.active&&pendingAck.empty(),"phone MTU variant waits for actual decode completion");
  send(packet(),id,2,payload);pendingAck.clear();
  for(int limit=0;pendingRasterWork.active&&limit<1000;limit++)pollRasterWork();
  check(installed==previous+1&&pendingAck=="K,3,"+String(id),"phone MTU variant commits and acknowledges after interleaved route");
  pendingAck.clear();handleBulk(tail.data(),tail.size());check(pendingAck=="K,3,"+String(id),"phone MTU variant recovers a lost receipt");
  id++;
 }
 // A route receipt must survive cancellation of a different bulk type.
 send(packet(),30);send(packet(),31,2);cancelPendingRaster();
 check(pendingAck=="K,2,31","cancellation preserves unrelated route receipt");
 pendingAck.clear();
 for(int theme:{1,2,3}) {
  themeIdx=theme;visible.buildings=true;std::fill(rasterBuf,rasterBuf+720000,0x44);
  send(packet(),40+theme);while(pendingRasterWork.active)pollRasterWork();
  check(visible.buildings&&std::all_of(rasterBuf,rasterBuf+720000,[](uint8_t v){return v==0x44;}),"each game theme carries all roofs before K");
  check(rasterProcessingUs>=rasterMaxSliceUs && diagnosticCount==installed,"one bounded timing diagnostic per committed map");
  cancelPendingRaster();check(pendingAck.empty()&&!bulks[3].done,"cancellation removes a completed but unsent raster K");
 }
 for(int stage:{0,1,2}) {
  pendingAck.clear();send(packet(),50+stage);
  if(stage>=1)while(pendingRasterWork.decode.cleared<720000)pollRasterWork();
  if(stage>=2)while(!pendingRasterWork.carrying)pollRasterWork();
  int before=installed;const std::vector<uint8_t>front(rasterBuf,rasterBuf+720000);
  cancelPendingRaster();pollRasterWork();
  check(installed==before&&std::equal(front.begin(),front.end(),rasterBuf)&&pendingAck.empty(),"cancel during clear/decode/carry leaves front and receipt untouched");
 }
 for(int flags:{0x1000,0x2000,0x3000}) {
  auto bad=packet();put(bad,14,2000|flags,2);int before=installed;
  const std::vector<uint8_t>front(rasterBuf,rasterBuf+720000);
  pendingAck.clear();send(bad,60);
  check(pendingAck=="N,3,60"&&!pendingRasterWork.active&&installed==before&&std::equal(front.begin(),front.end(),rasterBuf),"experimental flags rejected without changing old map");
  send(packet(),60);check(pendingRasterWork.active,"same id recovers after rejected experimental flags");cancelPendingRaster();
 }
 pendingAck.clear();send(packet(),69);while(pendingRasterWork.active){ticks+=50000;pollRasterWork();}
 check(lastWallUs>lastProcessingUs&&lastProcessingUs>=lastMaxUs,"timing reports real wall gaps separately from processing and includes install slice");
 bleAuthed=false;pollRasterWork();check(pendingAck.empty()&&!bulks[3].done,"auth loss invalidates completed pending K");bleAuthed=true;
 // Simulate BLE epoch callback during a processing slice, including final decode.
 pendingAck.clear();send(packet(),70);interruptAt=ticks+2000;int before=installed;
 pollRasterWork();pollRasterWork();
 check(!pendingRasterWork.active&&installed==before&&pendingAck.empty(),"asynchronous epoch callback cancels before installation");
 pendingAck.clear();uint8_t *savedBack=rasterBackBuf;rasterBackBuf=nullptr;failAllocation=true;
 send(packet(),79);check(pendingAck=="N,3,79"&&!pendingRasterWork.active&&!bulks[3].done,"allocation failure requests retry without committing");
 rasterBackBuf=savedBack;failAllocation=false;send(packet(),79);check(pendingRasterWork.active,"same id resend recovers allocation failure");cancelPendingRaster();
 pendingAck.clear();auto geometry=packet();geometry.insert(geometry.end(),{'V','C','E',1,0,0,0,0});geometryAccept=true;
 send(geometry,80);check(bulks[3].done&&pendingAck=="K,3,80","geometry compatibility returns receipt after synchronous completion");
 pollRasterWork();check(bulks[3].done&&pendingAck=="K,3,80","idle work poll preserves successful geometry receipt");
 printf("PASS %d receiver checks: bounded work, atomic commit, delayed receipt, probes, packet replacement, session/style/preference cancellation and invalid-map retries\n",checks);
}
