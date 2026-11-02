#pragma once
#include <stdint.h>
#include <math.h>
namespace GameMapStyle {
inline int destinationHoleRadius(int theme) { return theme==2?3:0; }
// Caller supplies room for sixteen vertices; radius is the outer tip distance.
inline int destinationVertices(int theme,float cx,float cy,float radius,float *xs,float *ys) {
 static const int8_t cross[][2]={{0,-14},{3,-10},{4,-4},{10,-3},{14,0},{10,3},{4,4},{3,10},{0,14},{-3,10},{-4,4},{-10,3},{-14,0},{-10,-3},{-4,-4},{-3,-10}};
 int n=theme==2?16:theme==3?6:4;
 for(int i=0;i<n;i++) {
  if(theme==2) {xs[i]=cx+cross[i][0]*(radius/14);ys[i]=cy+cross[i][1]*(radius/14);}
  else {float a=i*6.28318530718f/n+(theme==1?0.78539816339f:0);xs[i]=cx+cosf(a)*radius;ys[i]=cy+sinf(a)*radius;}
 }
 return n;
}
// GTA layers: -1 preserves the map, 0 black outline, 1 purple; no white layer.
inline int destinationLayer(int theme,float x,float y) {
 if(theme!=2) return -1;
 const float d=x*x+y*y;
 if(d<=9) return -1;
 float xs[16],ys[16];
 for(int pass=1;pass>=0;--pass) {
  destinationVertices(2,0,0,pass?11.5f:14.0f,xs,ys);
  bool inside=false;
  for(int i=0,j=15;i<16;j=i++) {
   const float cross=(x-xs[i])*(ys[j]-ys[i])-(y-ys[i])*(xs[j]-xs[i]);
   if(fabsf(cross)<0.0001f && x>=fminf(xs[i],xs[j]) && x<=fmaxf(xs[i],xs[j]) && y>=fminf(ys[i],ys[j]) && y<=fmaxf(ys[i],ys[j])) {inside=true;break;}
   if((ys[i]>y)!=(ys[j]>y) && x<(xs[j]-xs[i])*(y-ys[i])/(ys[j]-ys[i])+xs[i]) inside=!inside;
  }
  if(inside) return d<=25?0:pass;
 }
 return -1;
}
inline bool baseTrack(int theme,bool requested) { return requested || theme==1 || theme==3; }
template<class Blocked> inline bool placeEdge(float bearing,float center,float radius,float heading,float &x,float &y,Blocked blocked) {
 const float nx=center-sinf(heading)*196,ny=center-cosf(heading)*196;
 for(int i=0;i<128;i++) {
  const int offset=i==0?0:(i%2?(i+1)/2:-i/2);
  const float a=bearing+offset*(6.28318530718f/128);
  const float px=center+cosf(a)*radius,py=center+sinf(a)*radius;
  if(py+15>=330 || hypotf(px-nx,py-ny)<43 || hypotf(px-center,py-262)<34 || blocked(px,py)) continue;
  x=px;y=py;return true;
 }
 return false;
}
inline void prioritize(bool alert,bool &track,float &turn,float &trip) {
 if (alert) {track=false;turn=0;trip=-1;}
 else if (turn>0.002f) trip=-1;
}

constexpr uint16_t rgb(uint32_t c) { return ((c>>8)&0xF800)|((c>>5)&0x07E0)|((c>>3)&31); }
constexpr uint32_t dim(uint32_t c,int k) { return (((c>>16)*k/100)<<16)|((((c>>8)&255)*k/100)<<8)|((c&255)*k/100); }
struct Palette { uint16_t base,road,roof,outline,water,park,route,routeOutline,visited,visitedOutline,player,destination,ring,ringDone,ringLeft; };
inline Palette palette(int theme,bool night) {
 const int k=night?(theme==1?45:75):100;
 const uint32_t base=theme==1?0xE6E5E2:theme==2?0x252628:0x0D101A;
 const uint32_t road=theme==1?0x101012:theme==2?0xA6A8A8:0x285F60;
 const uint32_t roof=theme==1?0xCECECA:theme==2?0x36383A:0x111522;
 const uint32_t outline=theme==1?0x929490:theme==2?0x505255:0x686574;
 const uint32_t route=theme==1?0xE65AB8:theme==2?0xA45CFF:0xF4F6B0;
 return {rgb(dim(base,k)),rgb(dim(road,k)),rgb(dim(roof,k)),rgb(dim(outline,k)),
 rgb(dim(theme==1?0x8DBAEA:theme==2?0x42535E:0x101D37,k)),
 rgb(dim(theme==1?0x3F826A:theme==2?0x3F5149:0x102D2E,k)),
 rgb(route),rgb(0x28202E),rgb(theme==1?0x817785:theme==2?0x51495D:0x204447),rgb(theme==3?0x10292C:0x36343E),
 rgb(theme==3?0x72F5AC:0xFFFFFF),rgb(theme==1?0xFF72C2:theme==2?0xA45CFF:0xF4F6B0),
 rgb(theme==1?0xC64D9E:theme==2?0x515257:0x42CBD0),rgb(theme==3?0x42CBD0:route),rgb(theme==3?0x163A3C:0x38283B)};
}
}
