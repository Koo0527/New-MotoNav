#include "../boards/175/MotoNav/GameMapStyle.h"
#include "../boards/175/MotoNav/RingFastColors.h"
#include <cassert>
int main() {
 using namespace GameMapStyle;
 auto p=palette(3,false);
 assert(p.ringDone==rgb(0x42CBD0)); assert(p.ringLeft==rgb(0x163A3C));
 RingFastColors::Key k={true,false,false,false,3,0xFFFF};
 k.theme=3;k.trackColor=p.ring;k.doneColor=p.ringDone;k.leftColor=p.ringLeft;
 auto pixel=[&](int r,int phase){return RingFastColors::color(r*64,phase,k,222,2,p.ring,p.ringDone,p.ringLeft,rgb(0xFF0000));};
 assert(pixel(222,0)==p.ring);
 k.trip=true;
 assert(pixel(222,0)==p.ringLeft); // zero progress: no completed phase
 assert(pixel(222,2)==p.ringDone);
 k.prog=true;assert(pixel(222,1)==k.color);
 k.over=true;assert(pixel(230,3)==rgb(0xFF0000));
 const auto original=k;
 k.theme++;assert(!RingFastColors::same(original,k));k=original;
 k.night=!k.night;assert(!RingFastColors::same(original,k));k=original;
 k.trackColor^=1;assert(!RingFastColors::same(original,k));k=original;
 k.doneColor^=1;assert(!RingFastColors::same(original,k));k=original;
 k.leftColor^=1;assert(!RingFastColors::same(original,k));k=original;
 k.color^=1;assert(!RingFastColors::same(original,k));
}
