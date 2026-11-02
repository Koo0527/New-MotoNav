from pathlib import Path
import subprocess,tempfile
root=Path(__file__).resolve().parents[3]
source=(root/'firmware/boards/175/MotoNav/src/map/NavigationMarkers.h').read_text()
function=source[source.index('void drawDestBlip('):source.index('// v5.0 路程')]
stub=r'''
#include <cmath>
#include <cassert>
#include <vector>
#include "GameMapStyle.h"
constexpr float PI=3.14159265358979323846f,CX=233,MAP_PY=262;
constexpr int LCD_WIDTH=466,LCD_HEIGHT=466,ST_DRAGON=8,ST_COMPASS=9;
constexpr unsigned C_BLACK=0,C_WHITE=65535;
int themeIdx=1,routeN=2,routeFrame=1,posFrame=1;bool nightOn=false;float viewHdg=0;
float routeX[2]={0,100},routeY[2]={0,0};
struct {unsigned blip=55;} TH;
int styleIdx(){return themeIdx;}
int obsOverlap(int,int,int,int){return 0;}
void obsAdd(float,float,float,float){}
void aaDisc(float,float,float,unsigned){}
void drawCompassBlip(float,float,bool){}
namespace DragonRadar { template<class F> void placeEdgeBall(float&,float&,float,float,F){} template<class T> void drawBall(T*,int,int){} }
std::vector<int> polygons;std::vector<unsigned> colors;int pixels=0;
struct Gfx {void drawPixel(int,int,unsigned color){pixels++;colors.push_back(color);}} device,*gfx=&device;
void mapFillPoly(float*,float*,int n,unsigned color){polygons.push_back(n);colors.push_back(color);}
'''
cases=r'''
int main(){
 for(int theme=1;theme<=3;theme++){
  themeIdx=theme;
  std::vector<int> inside;int insidePixels;
  for(bool outside:{false,true}){
   routeX[1]=outside?2000:100;polygons.clear();colors.clear();pixels=0;
   drawDestBlip(0,0,1,1,0);
   if(!outside){inside=polygons;insidePixels=pixels;}
   else {assert(polygons==inside);assert(pixels==insidePixels);}
   if(theme==2){assert(pixels>0);assert(polygons.empty());for(auto c:colors)assert(c!=C_WHITE);}
   else {assert(polygons.size()==3);for(auto n:polygons)assert(n==(theme==1?4:6));}
  }
 }
}
'''
with tempfile.TemporaryDirectory() as d:
 p=Path(d);(p/'main.cpp').write_text(stub+function+cases)
 subprocess.run(['clang++','-std=c++17','-fsanitize=address,undefined','-I',str(root/'firmware/boards/175/MotoNav'),str(p/'main.cpp'),'-o',str(p/'test')],check=True)
 subprocess.run([str(p/'test')],check=True)
print('PASS production destination draw: matching on/off-screen shapes, GTA hollow-only raster and black outline')
