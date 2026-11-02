#include <cassert>
#include "../boards/175/MotoNav/src/map/GameRouteDots.h"
int main() {
  assert(gameDotColor(false,1,2,true,3,3)==0xE8E4);
  assert(gameDotColor(true,1,2,true,3,4)==1);
  assert(gameDotColor(false,1,2,true,3,0)==3);
  assert(gameDotColor(false,1,2,false,3,0)==2);
  assert(gameDotFirst(15)==28 && gameDotFirst(14)==14);
  float distances[3]; int count=0;
  gameSegmentDots(0,19,true,[&](float t,float d) {
    assert(t==d/19); distances[count++]=d;
  });
  gameSegmentDots(19,40,true,[&](float t,float d) {
    assert(t==(d-19)/21); distances[count++]=d;
  });
  assert(count==3 && distances[0]==0 && distances[1]==14 && distances[2]==28);
  // A progress split between samples changes colors without restarting the phase.
  assert(gameDotColor(distances[1]<20,1,2,false,3,0)==1);
  assert(gameDotColor(distances[2]<20,1,2,false,3,0)==2);
  gameSegmentDots(28,28,true,[&](float,float){assert(false);});
  gameSegmentDots(0,336000,false,[&](float,float){assert(false);});
  // Large route distance does not cause an origin-to-view sample walk.
  count=0;
  gameSegmentDots(336000,336028,true,[&](float,float){++count;});
  assert(count==2);
  count=0;
  gameVisibleDots(0,1000000000,-500000000,0,1000000000,0,100,[&](double t,double d){
    assert(++count<=15); assert(fabs(-500000000+1000000000*t)<=100.001);
  });
  assert(count>0);
  double previous=-1; count=0;
  gameSegmentDots(268435456.0f,268435520.0f,true,[&](double,double d){
    assert(++count<10 && d>previous); previous=d;
  });
}
