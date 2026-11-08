#include <cassert>
#include <cstdint>
#include <fstream>
#include <iterator>
#include <vector>
#include <cstdlib>
#include <cstdio>
#include "../../../firmware/boards/175/MotoNav/RasterEdge.h"
#include "zlib_inflate.h"
static std::vector<uint8_t> read(const char *path) {
 std::ifstream stream(path,std::ios::binary);assert(stream);
 return std::vector<uint8_t>((std::istreambuf_iterator<char>(stream)),std::istreambuf_iterator<char>());
}
int main(int argc,char **argv) {
 assert(argc==5);const int width=atoi(argv[3]),height=atoi(argv[4]);
 auto before=read(argv[1]),after=read(argv[2]);RasterEdgeView a,b;
 assert(rasterEdgeDecode(before.data(),before.size(),width,height,a,RASTER_EDGE_MAX_BYTES,edgeInflate));
 assert(rasterEdgeDecode(after.data(),after.size(),width,height,b,RASTER_EDGE_MAX_BYTES,edgeInflate));
 for(int y=0;y<height;y++)for(int x=0;x<width;x++)assert(rasterEdgeWord(a,x,y)==rasterEdgeWord(b,x,y));
 std::printf("%d source cells: every decoded word unchanged\n",width*height);
}
