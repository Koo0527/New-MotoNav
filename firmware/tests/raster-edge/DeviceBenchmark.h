#pragma once
// Diagnostic-only include AFTER RasterRenderer.h, with row worker already running.
// Freeze map, RM transform/palette and theme; call outside the display worker.
// enabled must be the actual runtime edge gate read by rasterRows on both cores.
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
struct RasterEdgeBenchmarkResult {
  uint32_t baselineMedianUs=0,edgeMedianUs=0,changedPixels=0,comparedPixels=0;
  bool withinBudget=false;
};
static inline uint32_t rasterEdgeMedian(uint32_t (&v)[31]){
  for(int i=1;i<31;i++)for(int j=i;j>0 && v[j]<v[j-1];j--){uint32_t t=v[j];v[j]=v[j-1];v[j-1]=t;}
  return v[15];
}
static inline bool rasterEdgeDeviceBenchmark(bool &enabled,RasterEdgeBenchmarkResult &out){
  out=RasterEdgeBenchmarkResult{};
  if(!RM.fb || RM.pix2 || rasHasPal || rasterViceValid || themeIdx<1 || themeIdx>3)return false;
  const size_t bytes=size_t(LCD_WIDTH)*LCD_HEIGHT*sizeof(uint16_t);
  auto *baseline=static_cast<uint16_t *>(ps_malloc(bytes));
  if(!baseline)return false;
  const bool previous=enabled;
  const int y0=int(CX-213),y1=int(CX+213);
  // Run the production renderer and existing two-core barrier, never a surrogate loop.
  for(int i=0;i<8;i++)for(int mode=0;mode<2;mode++){
    enabled=mode;parallelRows(rasterRows,y0,y1);
  }
  uint32_t times[2][31];
  for(int i=0;i<31;i++)for(int turn=0;turn<2;turn++){
    const int mode=(i+turn)&1;enabled=mode;
    const uint32_t start=micros();parallelRows(rasterRows,y0,y1);
    times[mode][i]=uint32_t(micros()-start);
  }
  enabled=false;parallelRows(rasterRows,y0,y1);memcpy(baseline,RM.fb,bytes);
  enabled=true;parallelRows(rasterRows,y0,y1);
  // Same frozen source coordinates and exact screen pixels in both runs.
  for(int y=y0;y<y1;y++){
    if(y<0 || y>=LCD_HEIGHT || fabsf(y+.5f-CX)>=212)continue;
    for(int x=mapCircleRows.left[y];x<=mapCircleRows.right[y];x++){
      if(x<0 || x>=LCD_WIDTH)continue;
      const size_t at=size_t(y)*LCD_WIDTH+x;
      ++out.comparedPixels;out.changedPixels+=baseline[at]!=RM.fb[at];
    }
  }
  out.baselineMedianUs=rasterEdgeMedian(times[0]);out.edgeMedianUs=rasterEdgeMedian(times[1]);
  out.withinBudget=out.baselineMedianUs && uint64_t(out.edgeMedianUs)*10<=uint64_t(out.baselineMedianUs)*11;
  enabled=previous;parallelRows(rasterRows,y0,y1);free(baseline);return true;
}
