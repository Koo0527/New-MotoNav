#pragma once
#include <math.h>
static inline double gameDotFirst(double distance) { return ceil(distance / 14.0) * 14.0; }
template<class Emit> static inline void gameSegmentDots(float a, float b, bool visible, Emit emit) {
  if (!visible || b <= a) return;
  for (double d = gameDotFirst(a); d < b; d += 14.0) emit((d-a)/(b-a), d);
}

#include <stdint.h>
static inline uint16_t gameDotColor(bool done, uint16_t muted, uint16_t base, bool curve, uint16_t curveColor, int traffic) {
  if (done) return muted;
  if (traffic) return traffic >= 4 ? 0x9000 : traffic == 3 ? 0xE8E4 : 0xFDA0;
  return curve ? curveColor : base;
}

// Clip only the sample range: dot phase still starts at route distance zero.
template<class Emit> static inline void gameVisibleDots(float a,float b,double x,double y,double vx,double vy,double r,Emit emit) {
  if (b<=a || r<0) return;
  double lo=0,hi=1;
  const double pos[2]={x,y}, delta[2]={vx,vy};
  for (int axis=0; axis<2; ++axis) {
    if (delta[axis]==0) { if (fabs(pos[axis])>r) return; }
    else {
      double u=(-r-pos[axis])/delta[axis],v=(r-pos[axis])/delta[axis];
      if (u>v) { double tmp=u; u=v; v=tmp; }
      lo=fmax(lo,u); hi=fmin(hi,v);
      if (hi<lo) return;
    }
  }
  double length=(double)b-a;
  for (double d=gameDotFirst(a+lo*length); d<b && d<=a+hi*length; d+=14.0)
    emit((d-a)/length,d);
}
