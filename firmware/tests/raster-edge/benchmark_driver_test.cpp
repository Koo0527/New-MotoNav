// Driver plumbing only; this host test does not simulate ESP32 dual-core timing.
#include <cassert>
#include <cstdint>
#include <cstdlib>
#include <cmath>
#include <vector>
constexpr int LCD_WIDTH=480,LCD_HEIGHT=480;
constexpr float CX=240;
struct {uint16_t *fb;bool pix2;} RM;
bool rasHasPal=false,rasterViceValid=false,gate=false;int themeIdx=1;
struct {int left[LCD_HEIGHT],right[LCD_HEIGHT];} mapCircleRows;
unsigned dispatches=0,clockTicks=0;
void *ps_malloc(size_t n){return malloc(n);}
uint32_t micros(){return clockTicks+=100;}
void rasterRows(int y0,int y1,int step){
 for(int y=y0;y<y1;y+=step)for(int x=30;x<=449;x++)RM.fb[y*LCD_WIDTH+x]=gate?2:1;
}
void parallelRows(void(*fn)(int,int,int),int y0,int y1){
 assert(fn==rasterRows && y0==27 && y1==453);++dispatches;
 fn(y0,y1,2);fn(y0+1,y1,2);
}
#include "DeviceBenchmark.h"
int main(){
 std::vector<uint16_t> fb(LCD_WIDTH*LCD_HEIGHT);RM.fb=fb.data();RM.pix2=false;
 for(int y=0;y<LCD_HEIGHT;y++){mapCircleRows.left[y]=30;mapCircleRows.right[y]=449;}
 RasterEdgeBenchmarkResult result;
 assert(rasterEdgeDeviceBenchmark(gate,result));assert(!gate && dispatches==81);
 assert(result.baselineMedianUs==100 && result.edgeMedianUs==100 && result.withinBudget);
 assert(result.comparedPixels==424*420 && result.changedPixels==result.comparedPixels);
 assert(fb[240*LCD_WIDTH+240]==1);
 RM.pix2=true;assert(!rasterEdgeDeviceBenchmark(gate,result));assert(dispatches==81);
}
