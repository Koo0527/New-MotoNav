#include <cassert>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cmath>
#include <vector>
#include <algorithm>
#include <zlib.h>
#include <string>
#include "../../boards/175/MotoNav/RasterContinuity.h"
static bool failEdgeAllocation=false;
static unsigned liveAllocations=0;
static void *edgeAllocate(size_t n){if(failEdgeAllocation)return nullptr;++liveAllocations;return malloc(n);}
#define RASTER_EDGE_ALLOC edgeAllocate
static int failCacheAfter=-1;
static void *cacheAllocate(size_t n){if(failCacheAfter==0)return nullptr;if(failCacheAfter>0)--failCacheAfter;return malloc(n);}
#define RASTER_EDGE_CACHE_ALLOC cacheAllocate
#include "../../boards/175/MotoNav/RasterEdge.h"
#include "../../boards/175/MotoNav/GameMapStyle.h"
static void put16(std::vector<uint8_t>& p,unsigned n){p.push_back(n&255);p.push_back((n>>8)&255);}
static void put32(std::vector<uint8_t>& p,unsigned n){put16(p,n);put16(p,n>>16);}
static void seal(std::vector<uint8_t> &p){
 uint32_t hash=2166136261u;for(size_t i=24;i<p.size();i++)hash=(hash^p[i])*16777619u;
 for(int i=0;i<4;i++)p[20+i]=uint8_t(hash>>(8*i));
}
static std::vector<uint8_t> wire(int w,int h,const std::vector<uint16_t>& cells){
 std::vector<uint8_t> p={'E','D','G','E',1,0};put16(p,w);put16(p,h);put16(p,0);
 const int bw=(w+15)/16,bh=(h+15)/16;put32(p,bw*bh);
 unsigned count=0;for(auto c:cells)count+=c!=0;put32(p,count);put32(p,0);
 std::vector<uint16_t> words;
 for(int ty=0;ty<bh;ty++)for(int tx=0;tx<bw;tx++)for(int y=0;y<16;y++){
  unsigned mask=0;for(int x=0;x<16;x++){int xx=tx*16+x,yy=ty*16+y;
   if(xx<w && yy<h && cells[yy*w+xx]){mask|=1u<<x;words.push_back(cells[yy*w+xx]);}}
  put16(p,mask);
 }
 for(auto c:words)put16(p,c);
 seal(p);return p;
}
static std::vector<uint8_t> compressed(const std::vector<uint8_t>& raw){
 uLongf bytes=compressBound(raw.size());std::vector<uint8_t> out(bytes);
 assert(compress2(out.data(),&bytes,raw.data(),raw.size(),9)==Z_OK);out.resize(bytes);return out;
}
static bool inflateEdge(const uint8_t *p,size_t n,uint8_t *out,size_t expected){
 z_stream stream={};stream.next_in=const_cast<Bytef *>(p);stream.avail_in=uInt(n);
 stream.next_out=out;stream.avail_out=uInt(expected);assert(inflateInit(&stream)==Z_OK);
 int status=inflate(&stream,Z_FINISH);bool ok=status==Z_STREAM_END && stream.total_in==n && stream.total_out==expected;
 inflateEnd(&stream);return ok;
}
static std::vector<uint8_t> codec1(const std::vector<uint8_t>& plain){
 size_t tiles=rasterEdgeU32(plain.data()+12),count=rasterEdgeU32(plain.data()+16);
 std::vector<uint8_t> payload(plain.begin()+24,plain.begin()+24+tiles*32),indices;
 std::vector<uint16_t> dict;
 for(size_t i=0;i<count;i++){
  uint16_t w=rasterEdgeU16(plain.data()+24+tiles*32+i*2);auto at=std::find(dict.begin(),dict.end(),w);
  if(at==dict.end()){dict.push_back(w);at=dict.end()-1;}
  assert(dict.size()<=256);indices.push_back(uint8_t(at-dict.begin()));
 }
 if(dict.empty())dict.push_back(2064);
 for(auto w:dict)put16(payload,w);payload.insert(payload.end(),indices.begin(),indices.end());
 auto zipped=compressed(payload);std::vector<uint8_t> result(plain.begin(),plain.begin()+24);
 result[5]=1;result[10]=uint8_t(dict.size());result[11]=uint8_t(dict.size()>>8);
 result.insert(result.end(),zipped.begin(),zipped.end());seal(result);return result;
}
static uint16_t word(int pair,int normal=0,int offset=16){return uint16_t(pair<<11|normal<<5|offset);}
int main(int argc,char **argv){
 assert(rasterEdgeChecksum(reinterpret_cast<const uint8_t *>("hello"),5)==0x4f9f2cabu);
 assert(rasterEdgeChecksum(nullptr,0)==2166136261u);
 RasterEdgeView view;std::vector<uint16_t> cells(17*19,0);
 cells[0]=word(1);cells[16]=word(28);cells[18*17+16]=word(7,8,21);
 auto p=wire(17,19,cells);assert(rasterEdgeDecode(p.data(),p.size(),17,19,view));
 for(int y=-1;y<=19;y++)for(int x=-1;x<=17;x++)assert(rasterEdgeWord(view,x,y)==(x>=0&&x<17&&y>=0&&y<19?cells[y*17+x]:0));
 // Invalid replacement leaves the previously published, owned map intact.
 const auto old=rasterEdgeWord(view,16,18);
 for(size_t i=0;i<p.size();i++)assert(!rasterEdgeDecode(p.data(),i,17,19,view));
 assert(rasterEdgeWord(view,16,18)==old);
 failEdgeAllocation=true;assert(!rasterEdgeDecode(p.data(),p.size(),17,19,view));failEdgeAllocation=false;
 assert(rasterEdgeWord(view,16,18)==old);assert(liveAllocations==1);
 // Independent owned copy survives changes to the source packet.
 auto saved=p;p.assign(p.size(),0);assert(rasterEdgeWord(view,16,18)==old);p=saved;
 auto bad=p;bad[4]=2;assert(!rasterEdgeDecode(bad.data(),bad.size(),17,19,view));
 bad=p;bad[24+2]=0x80;seal(bad);assert(!rasterEdgeDecode(bad.data(),bad.size(),17,19,view));
 bad=p;bad[20]^=1;assert(!rasterEdgeDecode(bad.data(),bad.size(),17,19,view));
 // Still structurally valid word: changing normal must fail checksum.
 bad=p;bad.back()^=1;assert(!rasterEdgeDecode(bad.data(),bad.size(),17,19,view));
 bad=p;bad.back()=0xff;seal(bad);assert(!rasterEdgeDecode(bad.data(),bad.size(),17,19,view));
 assert(!rasterEdgeDecode(p.data(),p.size(),18,19,view));
 assert(!rasterEdgeDecode(p.data(),p.size(),17,19,view,1));
 bad=p;bad.push_back(0);assert(!rasterEdgeDecode(bad.data(),bad.size(),17,19,view));
 // Full-size masks alone exceed the default 512 KiB decode budget.
 auto oversized=wire(1648,1648,std::vector<uint16_t>(1648*1648));
 assert(!rasterEdgeDecode(oversized.data(),oversized.size(),1648,1648,view));
 // Owner exchange allocates nothing and retains both maps across commit/release.
 {RasterEdgeView pending;auto secondCells=cells;secondCells[0]=word(28,8,20);
  auto second=wire(17,19,secondCells);assert(rasterEdgeDecode(second.data(),second.size(),17,19,pending));
  const unsigned allocations=liveAllocations;auto *currentData=view.tiles,*pendingData=pending.tiles;
  rasterEdgeSwap(view,pending);assert(liveAllocations==allocations);
  assert(view.tiles==pendingData && pending.tiles==currentData);
  assert(rasterEdgeWord(view,0,0)==secondCells[0] && rasterEdgeWord(pending,0,0)==cells[0]);
  rasterEdgeSwap(view,view);assert(view.tiles==pendingData);
  rasterEdgeSwap(view,pending);assert(view.tiles==currentData);
  rasterEdgeRelease(pending);assert(rasterEdgeWord(view,16,18)==old);
  rasterEdgeSwap(view,pending);assert(!view.tiles && pending.tiles==currentData);
  rasterEdgeSwap(view,pending);assert(view.tiles==currentData && !pending.tiles);
 }
 // Codec1 matches flags0 lookup while owning a single bounded allocation.
 assert(sizeof(RasterEdgeTile)==52);
 {auto zipped=codec1(p);RasterEdgeView packed;
  assert(rasterEdgeDecode(zipped.data(),zipped.size(),17,19,packed,RASTER_EDGE_MAX_BYTES,inflateEdge));
  assert(packed.bytes==4*36+3+3*2 && packed.codec==1);
  for(int y=0;y<19;y++)for(int x=0;x<17;x++)assert(rasterEdgeWord(packed,x,y)==cells[y*17+x]);
  rasterEdgeSwap(view,packed);assert(view.codec==1 && packed.codec==0);
  assert(rasterEdgeWord(view,16,18)==old);rasterEdgeSwap(view,packed);
  assert(!rasterEdgeDecode(zipped.data(),zipped.size(),17,19,packed));
  auto corrupt=zipped;corrupt.back()^=1;
  assert(!rasterEdgeDecode(corrupt.data(),corrupt.size(),17,19,packed,RASTER_EDGE_MAX_BYTES,inflateEdge));
  corrupt=zipped;corrupt.push_back(0);seal(corrupt);
  assert(!rasterEdgeDecode(corrupt.data(),corrupt.size(),17,19,packed,RASTER_EDGE_MAX_BYTES,inflateEdge));
  assert(rasterEdgeWord(packed,16,18)==old);
  // Valid compressed/checksummed malformed dictionary indices and words fail.
  std::vector<uint8_t> decoded(4*32+3*2+3);
  assert(inflateEdge(zipped.data()+24,zipped.size()-24,decoded.data(),decoded.size()));
  for(int mutation=0;mutation<4;mutation++){
   auto evil=decoded;
   if(mutation==0)evil.back()=3;
   if(mutation==1)evil[4*32+1]=0xff;
   if(mutation==2)evil[2*32+15*2]=0x80; // padding row outside height
   if(mutation==3)evil.push_back(0);
   auto payload=compressed(evil);corrupt.assign(zipped.begin(),zipped.begin()+24);
   corrupt.insert(corrupt.end(),payload.begin(),payload.end());seal(corrupt);
   assert(!rasterEdgeDecode(corrupt.data(),corrupt.size(),17,19,packed,RASTER_EDGE_MAX_BYTES,inflateEdge));
  }
  for(unsigned dictCount:{0u,257u}){
   corrupt=zipped;corrupt[10]=uint8_t(dictCount);corrupt[11]=uint8_t(dictCount>>8);
   assert(!rasterEdgeDecode(corrupt.data(),corrupt.size(),17,19,packed,RASTER_EDGE_MAX_BYTES,inflateEdge));
  }
  // Full tiles exercise row-prefix 240 and overlapping in-place mask expansion.
  std::vector<uint16_t> dense(32*32,word(1));auto full=codec1(wire(32,32,dense));
  assert(rasterEdgeDecode(full.data(),full.size(),32,32,packed,RASTER_EDGE_MAX_BYTES,inflateEdge));
  assert(packed.tileBases[3]==768);
  assert(packed.bytes==4*36+1024+2);
  for(int y=0;y<32;y++)for(int x=0;x<32;x++)assert(rasterEdgeWord(packed,x,y)==word(1));
  for(size_t i=0;i<dense.size();i++)dense[i]=uint16_t((1<<11)|(i%256));
  full=codec1(wire(32,32,dense));assert(full[10]==0 && full[11]==1);
  assert(rasterEdgeDecode(full.data(),full.size(),32,32,packed,RASTER_EDGE_MAX_BYTES,inflateEdge));
  for(int y=0;y<32;y++)for(int x=0;x<32;x++)assert(rasterEdgeWord(packed,x,y)==dense[y*32+x]);
 }
 // Two independent bounded caches reproduce base material or unchanged edge words.
 {const int w=144,h=144,bw=9;std::vector<uint16_t> shape(w*h,0);std::vector<uint8_t> source(bw*bw*128);
  for(int y=0;y<h;y++)for(int x=0;x<w;x++){
   unsigned k=((y>>4)*bw+(x>>4))*256+(y&15)*16+(x&15);unsigned mat=(x*3+y*5)%8;
   source[k>>1]|=uint8_t(mat<<((k&1)*4));if((x+y)%7==0)shape[y*w+x]=word(1+(x+y)%7,(x%4)*8,16);
  }
  auto packet=codec1(wire(w,h,shape));RasterEdgeView cached;
  assert(rasterEdgeDecode(packet.data(),packet.size(),w,h,cached,RASTER_EDGE_MAX_BYTES,inflateEdge));
  RasterEdgeCache caches[2];RasterEdgeBaseLUT expansion;
  assert(rasterEdgeCachePairPrepare(caches,cached,source.data(),source.size(),17,expansion));
  assert(rasterEdgeCacheBudget(cached)<=RASTER_EDGE_MAX_BYTES);
  for(unsigned t=0;t<81;t++){
   auto *dense=caches[0].get(cached,17,t,expansion);assert(dense);
   assert(caches[0].get(cached,17,t,expansion)==dense);
   for(unsigned p=0;p<256;p++){
    unsigned x=(t%bw)*16+(p%16),y=(t/bw)*16+(p/16);uint16_t expected=shape[y*w+x];
    if(!expected)expected=uint16_t(((x*3+y*5)%8)<<5);assert(dense[p]==expected);
   }
  }
  assert(caches[0].misses==81 && caches[0].hits==81 && caches[1].misses==0);
  assert(caches[0].get(cached,17,0,expansion));assert(caches[0].misses==82);
  assert(caches[1].get(cached,17,0,expansion));assert(caches[1].misses==1);
  assert(caches[0].dense!=caches[1].dense && caches[0].slots!=caches[1].slots);
  assert(!caches[0].get(cached,18,0,expansion));assert(!caches[0].get(cached,17,81,expansion));
  assert(rasterEdgeDecode(packet.data(),packet.size(),w,h,cached,RASTER_EDGE_MAX_BYTES,inflateEdge));
  assert(!caches[0].get(cached,17,0,expansion)); // same address, newer view epoch
  assert(rasterEdgeCachePairPrepare(caches,cached,source.data(),source.size(),18,expansion));
  assert(caches[0].get(cached,18,0,expansion));
  failCacheAfter=1;assert(!rasterEdgeCachePairPrepare(caches,cached,source.data(),source.size(),18,expansion));
  assert(!caches[0].dense && !caches[1].dense);failCacheAfter=-1;
  assert(!rasterEdgeCachePairPrepare(caches,cached,source.data(),source.size()-1,18,expansion));
  auto plain=wire(w,h,shape);assert(rasterEdgeDecode(plain.data(),plain.size(),w,h,cached));
  assert(rasterEdgeCachePairPrepare(caches,cached,source.data(),source.size(),19,expansion));
  for(unsigned t:{0u,80u}){const uint16_t *dense=caches[0].get(cached,19,t,expansion);assert(dense);
   for(unsigned p=0;p<256;p++){unsigned x=(t%bw)*16+(p%16),y=(t/bw)*16+(p/16);
    uint16_t expected=shape[y*w+x];if(!expected)expected=uint16_t(((x*3+y*5)%8)<<5);assert(dense[p]==expected);}
  }
  RasterEdgeView tooLarge;tooLarge.width=1200;tooLarge.height=1200;tooLarge.blocksWide=75;tooLarge.bytes=RASTER_EDGE_MAX_BYTES;
  assert(rasterEdgeCacheBudget(tooLarge)>RASTER_EDGE_MAX_BYTES);
  assert(!rasterEdgeCachePairPrepare(caches,tooLarge,source.data(),source.size(),18,expansion));
 }
 RasterEdgeLUT lut;uint16_t pal[8]={0xf800,0x001f,0x07e0,0xffff,0,0xffe0,0x07ff,0xf81f};
 assert(lut.prepare(pal,1.0f,0));
 assert(lut.color(0,32768,32768,123)==123);
 assert(lut.color(word(31),32768,32768,123)==123);
 assert(lut.color(word(1),32768,32768,123)==0x8010);
 assert(lut.color(word(1),0,32768,123)==pal[0]);
 assert(lut.color(word(1),65535,32768,123)==pal[1]);
 assert(lut.color(word(1,0,24),32768,32768,123)==pal[0]);
 // Ordered pair enumeration reaches every one of the eight materials.
 assert(lut.prepare(pal,1.0f/64,3.0f));
 for(int n=0;n<64;n++)for(int off=0;off<32;off++)(void)lut.color(word(1,n,off),0,0,0);
 assert(lut.prepare(pal,1,0));
 int pair=0;for(int a=0;a<7;a++)for(int b=a+1;b<8;b++){
  ++pair;assert(lut.color(word(pair),0,32768,999)==pal[a]);
  assert(lut.color(word(pair),65535,32768,999)==pal[b]);
 }
 // Independent dense square integration checks slants, footprint and rotation.
 for(float footprint:{0.25f,1.0f,2.0f})for(float angle:{0.0f,0.37f,0.78539816f}){
  assert(lut.prepare(pal,footprint,angle));
  for(int n:{0,3,8,19,31,55})for(int off:{12,16,21})for(int q:{16384,32768,49152}){
   const double na=n*6.283185307179586/64,px=q/65536.0-.5,py=.125;
   unsigned hits=0;const int samples=160;
   for(int y=0;y<samples;y++)for(int x=0;x<samples;x++){
    double xx=((x+.5)/samples-.5)*footprint,yy=((y+.5)/samples-.5)*footprint;
    double sx=px+cos(angle)*xx-sin(angle)*yy,sy=py+sin(angle)*xx+cos(angle)*yy;
    hits+=cos(na)*sx+sin(na)*sy>=(off-16)/16.;
   }
   auto c=lut.color(word(1,n,off),q,40960,999);
   double coverage=hits/double(samples*samples);
   assert(std::abs(int(c&31)-int(std::lround(coverage*31)))<=2);
  }
 }
 for(int theme=1;theme<=3;theme++)for(bool night:{false,true}){
  auto colors=GameMapStyle::palette(theme,night);
  uint16_t real[8]={colors.base,colors.road,colors.park,colors.water,colors.roof,colors.outline,colors.roof,colors.outline};
  assert(lut.prepare(real,1,0));assert(lut.color(word(28),0,32768,0)==real[6]);assert(lut.color(word(28),65535,32768,0)==real[7]);
 }
 assert(!lut.prepare(pal,0,0));assert(!lut.prepare(pal,NAN,0));assert(!lut.prepare(pal,1,NAN));
 rasterEdgeRelease(view);assert(!rasterEdgeWord(view,0,0));
 for(int arg=1;arg<argc;arg++){
  FILE *file=fopen(argv[arg],"rb");assert(file);assert(fseek(file,0,SEEK_END)==0);long size=ftell(file);
  assert(size>=24 && size<=long(RASTER_EDGE_MAX_PACKET));rewind(file);std::vector<uint8_t> packet(size);
  assert(fread(packet.data(),1,packet.size(),file)==packet.size());fclose(file);
  RasterEdgeView actual;const uint16_t w=rasterEdgeU16(packet.data()+6),h=rasterEdgeU16(packet.data()+8);
  assert(rasterEdgeDecode(packet.data(),packet.size(),w,h,actual,RASTER_EDGE_MAX_BYTES,inflateEdge));
  uint32_t found=0,hash=2166136261u;
  for(int y=0;y<h;y++)for(int x=0;x<w;x++){
   uint16_t cell=rasterEdgeWord(actual,x,y);found+=cell!=0;
   hash=(hash^uint8_t(cell))*16777619u;hash=(hash^uint8_t(cell>>8))*16777619u;
  }
  assert(found==rasterEdgeU32(packet.data()+16));
  std::string path=argv[arg];size_t slash=path.find_last_of('/');path=(slash==std::string::npos?"":path.substr(0,slash+1))+"base.bin";
  FILE *baseFile=fopen(path.c_str(),"rb");
  if(baseFile){
   assert(fseek(baseFile,0,SEEK_END)==0);long baseSize=ftell(baseFile);assert(baseSize>0 && baseSize<=480000);
   rewind(baseFile);std::vector<uint8_t> base(baseSize);assert(fread(base.data(),1,base.size(),baseFile)==base.size());fclose(baseFile);
   RasterHeader header={};assert(rasterCheck(base.data(),base.size(),header,1440000,720000));assert(header.dataEnd==base.size());
   std::vector<uint8_t> pixels(header.bytes);rasterDecode(base.data(),header,pixels.data());
   RasterEdgeCache cache[2];RasterEdgeBaseLUT lut;assert(rasterEdgeCachePairPrepare(cache,actual,pixels.data(),pixels.size(),1,lut));
   uint32_t tiles=uint32_t(actual.blocksWide)*((actual.height+15)/16);
   for(uint32_t t=0;t<tiles;t++){
    const uint16_t *dense=cache[t&1].get(actual,1,t,lut);assert(dense);
    for(unsigned pos=0;pos<256;pos++){
     int x=(t%actual.blocksWide)*16+(pos&15),y=(t/actual.blocksWide)*16+(pos>>4);if(x>=w || y>=h)continue;
     uint8_t material=255;assert(rasterRead(pixels.data(),header,x,y,material));
     uint16_t expected=rasterEdgeWord(actual,x,y);if(!expected)expected=uint16_t(material<<5);assert(dense[pos]==expected);
    }
   }
   printf("EDGE CACHE metadata=%zu all-pixels=identical\n",rasterEdgeCacheBudget(actual));
  }
  printf("EDGE HOST codec=%u metadata=%zu values=%u wordsFNV=%08x\n",unsigned(actual.codec),actual.bytes,found,hash);
 }
 puts("PASS raster-edge sparse addressing, malformed/limit isolation, eight materials, diagonal/rotation/footprint, real day/night palettes");
}
