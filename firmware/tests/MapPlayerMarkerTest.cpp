#include <cassert>
#include <cmath>
#include <initializer_list>
#include "../boards/175/MotoNav/MapPlayerMarker.h"
int main() {
  for (int theme : {1,2}) {
    float x[14],y[14];
    int n=MapPlayerMarker::vertices(theme,0,1,233,262,x,y);
    assert(n==(theme==1?14:4));
    assert(x[0]==233 && y[0]<262);
    MapPlayerMarker::vertices(theme,90,1,233,262,x,y);
    assert(x[0]>233 && fabsf(y[0]-262)<0.001f);
    for(int angle=0;angle<360;++angle) {
      MapPlayerMarker::vertices(theme,angle,1.22f,233,262,x,y);
      for(int i=0;i<n;++i) assert(hypotf(x[i]-233,y[i]-262)<=20);
    }
  }
}
