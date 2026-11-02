#include "../boards/175/MotoNav/GameMapStyle.h"
#include <cassert>
int main(){using namespace GameMapStyle;for(int y=-15;y<=15;y++)for(int x=-15;x<=15;x++){const unsigned under=0x1234+x+31*y;const int layer=destinationLayer(2,x,y);unsigned pixel=layer<0?under:layer==0?0:layer==1?0xA45C:0xFFFF;if(x*x+y*y<=9)assert(pixel==under);assert(layer!=2);}assert(destinationLayer(2,0,14)==0);assert(destinationLayer(2,0,10)==1);assert(destinationLayer(2,4,0)==0);}
