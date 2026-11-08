#include <cassert>
#include <cstdio>
#include <string>
#include <vector>
#include <zlib.h>
#include "DenseCell.h"
static std::vector<uint8_t> read(const std::string&p){FILE*f=fopen(p.c_str(),"rb");assert(f);fseek(f,0,SEEK_END);long n=ftell(f);assert(n>0&&n<2000000);rewind(f);std::vector<uint8_t>b(n);assert(fread(b.data(),1,n,f)==size_t(n));fclose(f);return b;}
int main(int argc,char **argv){
 DenseCellLUT lut;uint16_t pal[8]={0xf800,0x001f,0x07e0,0xffff,0,0xffe0,0x07ff,0xf81f};assert(lut.prepare(pal,1,0));
 for(unsigned w=0;w<4096;w++)for(unsigned sub=0;sub<4;sub++)assert(lut.material(uint16_t(0x8000|w),(sub&1)?49152:16384,(sub&2)?49152:16384)==((w>>(sub*3))&7));
 uint16_t scratch[4]={};uint8_t badCount[4]={0,0,0,0},badWord[4]={1,0,0,0x7c},tooMany[4]={5,0,0,0};
 {DenseRunDecoder d(scratch,4);assert(!d.feed(badCount,4));assert(!d.finish());}
 {DenseRunDecoder d(scratch,4);assert(!d.feed(badWord,4));}
 {DenseRunDecoder d(scratch,4);assert(!d.feed(tooMany,4));}
 {DenseRunDecoder d(scratch,4);assert(d.feed(tooMany,3));assert(!d.finish());}
 {DenseRunDecoder d(nullptr,360000,true);assert(!d.feed(badCount,4)&&!d.finish());}
 {DenseRunDecoder d(scratch,4,true);assert(!d.feed(badCount,4)&&!d.finish());}
 // Independent square integration checks ordinary and two-boundary RGB565 colors.
 for(float footprint:{.4f,1.f})for(float rotation:{0.f,.37f}){
  assert(lut.prepare(pal,footprint,rotation));
  for(unsigned pair:{1u,29u,30u})for(unsigned n:{0u,3u,8u,19u,31u})for(unsigned q:{10u,16u,24u}){
   uint16_t word=uint16_t(pair<<10|n<<5|q);const int samples=100;double nx=cos(n*3.141592653589793/16),ny=sin(n*3.141592653589793/16),width=.5*fmax(fabs(nx),fabs(ny));
   unsigned r=0,g=0,b=0;
   for(int y=0;y<samples;y++)for(int x=0;x<samples;x++){
    double xx=((x+.5)/samples-.5)*footprint,yy=((y+.5)/samples-.5)*footprint;
    double sx=cos(rotation)*xx-sin(rotation)*yy+.125,sy=sin(rotation)*xx+cos(rotation)*yy-.125;
    double d=nx*sx+ny*sy-(int(q)-16)/32.;unsigned material;
    if(pair==1)material=d<0?0:1;else{unsigned fill=pair==29?4:6;material=d<0?(pair==29?0:2):d>=width?fill:fill+1;}
    uint16_t c=pal[material];r+=c>>11;g+=(c>>5)&63;b+=c&31;
   }
   uint16_t actual=lut.color(word,40960,24576);unsigned count=samples*samples;
   assert(abs(int(actual>>11)-int((r+count/2)/count))<=2);
   assert(abs(int((actual>>5)&63)-int((g+count/2)/count))<=3);
   assert(abs(int(actual&31)-int((b+count/2)/count))<=2);
  }
 }
 assert(lut.prepare(pal,1,0));
 assert(!denseCellValid(0xf000));assert(!denseCellValid(31<<10));assert(!denseCellValid(8));
 for(int arg=1;arg<argc;arg+=2){
  assert(arg+1<argc);auto bytes=read(argv[arg]),raw=read(argv[arg+1]);assert(bytes.size()==720000 &&raw.size()==1440000);
  std::vector<uint16_t> dense(360000);for(size_t i=0;i<dense.size();i++){dense[i]=rasterEdgeU16(bytes.data()+i*2);assert(denseCellValid(dense[i]));}
  for(unsigned y=0;y<1200;y++)for(unsigned x=0;x<1200;x++){
   uint16_t word=dense[(y/2)*600+x/2];assert(lut.material(word,(x&1)?49152:16384,(y&1)?49152:16384)==raw[y*1200+x]);
  }
  auto zipped=read(std::string(argv[arg]).substr(0,std::string(argv[arg]).size()-4)+".rle.zlib");
  z_stream z={};assert(inflateInit(&z)==Z_OK);z.next_in=zipped.data();z.avail_in=zipped.size();std::vector<uint16_t> out(360000);DenseRunDecoder decoder(out.data(),out.size());
  std::vector<uint16_t> tiled(DENSE_TILED_WORDS+2,0xcafe);DenseRunDecoder tiledDecoder(tiled.data()+1,360000,true);
  int status;do{uint8_t chunk[17];z.next_out=chunk;z.avail_out=sizeof(chunk);status=inflate(&z,Z_NO_FLUSH);assert(status==Z_OK||status==Z_STREAM_END);assert(decoder.feed(chunk,sizeof(chunk)-z.avail_out));assert(tiledDecoder.feed(chunk,sizeof(chunk)-z.avail_out));}while(status!=Z_STREAM_END);
  assert(z.total_in==zipped.size()&&decoder.finish()&&out==dense);inflateEnd(&z);
  assert(tiledDecoder.finish()&&tiled.front()==0xcafe&&tiled.back()==0xcafe);
  for(unsigned y=0;y<608;y++)for(unsigned x=0;x<608;x++)assert(tiled[1+denseCellTiledIndex(x,y)]==(x<600&&y<600?dense[y*600+x]:0));
  for(float scale:{.38f,.6f})for(float angle:{0.f,0.78539816339f,1.57079632679f}){
   assert(lut.prepare(pal,1/(scale*4),angle));
   for(unsigned y=0;y<600;y++)for(unsigned x=0;x<600;x++){
    uint16_t a=dense[y*600+x],b=tiled[1+denseCellTiledIndex(x,y)];
    assert(lut.color(a,32768,16384)==lut.color(b,32768,16384));
   }
  }
  {DenseRunDecoder d(tiled.data()+1,360000,true);assert(!d.feed(badCount,4)&&!d.finish());}
  {DenseRunDecoder d(tiled.data()+1,360000,true);assert(!d.feed(badWord,4)&&!d.finish());}
  {DenseRunDecoder d(tiled.data()+1,360000,true);assert(d.feed(tooMany,3)&&!d.finish());}
  assert(lut.prepare(pal,1,0));
  printf("DENSE TILED words=369664 padding=zero guards=exact color=6geometries-exact\n");
  printf("DENSE HOST exact-centers=1440000 rle=exact metadata=%zu\n",sizeof(lut)+sizeof(DenseRunDecoder)+32768);
 }
 assert(argc==15);
}
