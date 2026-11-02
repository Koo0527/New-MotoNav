#include "../boards/175/MotoNav/GameMapStyle.h"
#include <cassert>
#include <cmath>
#include <initializer_list>
int main(){using namespace GameMapStyle; assert(baseTrack(1,false));assert(baseTrack(3,false));assert(!baseTrack(2,false));float x=0,y=0;assert(!placeEdge(1.57f,233,192,0,x,y,[](float,float){return true;}));for(float a: {0.f,1.57f,3.14f,4.71f}) { assert(placeEdge(a,233,192,0,x,y,[](float,float){return false;}));assert(y+15<330);assert(std::fabs(std::hypot(x-233,y-233)-192)<.01f);}assert(palette(1,false).water==rgb(0x8DBAEA));assert(palette(3,false).visited==rgb(0x204447));}
