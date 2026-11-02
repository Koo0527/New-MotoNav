// Synthetic scene; colors, player geometry, dot phase and ring pixels use production helpers.
#include "../boards/175/MotoNav/GameMapStyle.h"
#include "../boards/175/MotoNav/MapPlayerMarker.h"
#include "../boards/175/MotoNav/RingFastColors.h"
#include "../boards/175/MotoNav/src/map/GameRouteDots.h"
#include <algorithm>
#include <fstream>
#include <vector>
#include <cstdlib>
constexpr int W=466,C=233;
constexpr float PI=3.14159265359f;
std::vector<uint16_t> pixels(W*W);
void dot(float x,float y,float r,uint16_t color) {
  for(int j=std::max(0,int(y-r-1));j<=std::min(W-1,int(y+r+1));++j)
    for(int i=std::max(0,int(x-r-1));i<=std::min(W-1,int(x+r+1));++i)
      if(hypotf(i-x,j-y)<=r)pixels[j*W+i]=color;
}
void line(float x,float y,float ex,float ey,float width,uint16_t color) {
  int count=std::max(1,int(ceilf(hypotf(ex-x,ey-y)*2)));
  for(int i=0;i<=count;i++)dot(x+(ex-x)*i/count,y+(ey-y)*i/count,width/2,color);
}
void poly(const float *x,const float *y,int n,uint16_t color) {
  for(int j=0;j<W;j++)for(int i=0;i<W;i++) {
    bool inside=false;
    for(int a=0,b=n-1;a<n;b=a++)if((y[a]>j)!=(y[b]>j) && i<(x[b]-x[a])*(j-y[a])/(y[b]-y[a])+x[a])inside=!inside;
    if(inside)pixels[j*W+i]=color;
  }
}
int main(int argc,char **argv) {
  if(argc!=4&&argc!=5)return 2;
  int theme=atoi(argv[1]);bool night=atoi(argv[2]);auto p=GameMapStyle::palette(theme,night);
  for(int y=0;y<W;y++)for(int x=0;x<W;x++) {
    uint16_t color=p.base;
    bool water=x<94+10*sinf(y/50.0f),park=x>330&&y>285;
    if(water)color=p.water;else if(park)color=p.park;
    bool road=abs(x-233)<12||abs(y-160)<10||abs(x+y-470)<9||(abs(x-140)<8&&y>60&&y<160);
    if(!water&&!park&&road)color=p.road;
    else if(!water&&!road) {
      int a=(x+10)%60,b=(y+5)%65;
      if(a>=8&&a<=45&&b>=8&&b<=46)color=(a==8||a==45||b==8||b==46)?p.outline:p.roof;
    }
    pixels[y*W+x]=hypotf(x-C,y-C)<=212?color:0;
  }
  float rx[]={233,233,140,140},ry[]={420,160,160,78};double distance=0;
  for(int i=0;i<3;i++) {
    double length=hypot(rx[i+1]-rx[i],ry[i+1]-ry[i])/.6;
    if(theme==3)gameSegmentDots(distance,distance+length,true,[&](double t,double d){dot(rx[i]+(rx[i+1]-rx[i])*t,ry[i]+(ry[i+1]-ry[i])*t,2,d<263.333?p.visited:p.route);});
    else {
      line(rx[i],ry[i],rx[i+1],ry[i+1],10,p.routeOutline);
      line(rx[i],ry[i],rx[i+1],ry[i+1],6,p.route);
      if(i==0)line(233,420,233,262,6,p.visited);
    }
    distance+=length;
  }
  float x[16],y[16];int n=MapPlayerMarker::vertices(theme,0,1,C,262,x,y);
  if(theme==3){for(int i=0;i<n;i++)line(x[i],y[i],x[(i+1)%n],y[(i+1)%n],4,0);for(int i=0;i<n;i++)line(x[i],y[i],x[(i+1)%n],y[(i+1)%n],2,p.player);}
  else {MapPlayerMarker::vertices(theme,0,1.22f,C,262,x,y);poly(x,y,n,0);MapPlayerMarker::vertices(theme,0,1,C,262,x,y);poly(x,y,n,p.player);}
  if(theme==2) {
    for(int j=-14;j<=14;j++)for(int i=-14;i<=14;i++) {
      int layer=GameMapStyle::destinationLayer(theme,i,j);
      if(layer>=0)pixels[(78+j)*W+140+i]=layer==0?0:p.destination;
    }
  } else for(int pass=0;pass<3;pass++) {
    float r=pass==0?14:pass==1?11.5f:9;
    n=GameMapStyle::destinationVertices(theme,140,78,r,x,y);
    poly(x,y,n,pass==0?0:pass==1?0xffff:p.destination);
  }
  RingFastColors::Key key={};key.theme=theme;key.night=night;key.track=GameMapStyle::baseTrack(theme,false);key.trip=true;
  for(int j=0;j<W;j++)for(int i=0;i<W;i++) {
    float r=hypotf(i-C+.5f,j-C+.5f);
    if(r<211)continue;
    float a=atan2f(i-C+.5f,C-j-.5f);if(a<0)a+=2*PI;
    pixels[j*W+i]=RingFastColors::color(lroundf(r*64),a<.35f*2*PI?2:0,key,222,2,p.ring,p.ringDone,p.ringLeft,0xf800);
  }
  dot(C+222*sinf(.35f*2*PI),C-222*cosf(.35f*2*PI),5,0);
  dot(C+222*sinf(.35f*2*PI),C-222*cosf(.35f*2*PI),3.5f,0xffff);
  dot(C,37,13,0);
  if(argc==5) {
    for(int j=0;j<W;j++)for(int i=0;i<W;i++)pixels[j*W+i]=GameMapStyle::rgb(((i/5+j/5)%2)?0xB2A99B:0x8A8174);
    for(int j=-14;j<=14;j++)for(int i=-14;i<=14;i++) {
      int layer=GameMapStyle::destinationLayer(2,i,j);
      if(layer>=0)pixels[(C+j)*W+C+i]=layer==0?0:p.destination;
    }
  }
  std::ofstream out(argv[3],std::ios::binary);out<<"P6\n466 466\n255\n";
  for(auto c:pixels){unsigned char b[]={static_cast<unsigned char>(((c>>11)&31)*255/31),static_cast<unsigned char>(((c>>5)&63)*255/63),static_cast<unsigned char>((c&31)*255/31)};out.write(reinterpret_cast<char*>(b),3);}
  return out?0:1;
}
