#pragma once
// Diagnostic only: two resident decoded production maps; no renderer edits.
#include "RoadPaletteBenchAssets.h"
#if MPAL_BENCH_BASELINE_ROWS
#include "RoadPaletteBaselineRows.h"
#endif
static RasterHeader paletteBenchHeaders[2];
static uint8_t *paletteBenchSources[2];
static uint16_t paletteBenchPalettes[2][16];
static void paletteBenchSelect(int mode){
  const auto &h=paletteBenchHeaders[mode];rasterBuf=paletteBenchSources[mode];
  rasBW=h.blocksWide;rasX0=h.x0;rasY0=h.y0;rasW=h.width;rasH=h.height;rasMpp=h.mm/1000.f;
  rasterFrame=h.frame;rasHasPal=h.palette;rasSemantic=h.semantic;rasSemanticVersion=h.semanticVersion;rasterCarriesBuildings=h.buildings;
  memcpy(rasPal,paletteBenchPalettes[mode],sizeof(rasPal));rasterViceValid=false;rasterBackValid=false;rasterValid=true;
}
static void paletteBenchMemory(const char *stage){Serial.printf("MPAL BENCH heap stage=%s internal=%u psram=%u\n",stage,unsigned(heap_caps_get_free_size(MALLOC_CAP_INTERNAL|MALLOC_CAP_8BIT)),unsigned(heap_caps_get_free_size(MALLOC_CAP_SPIRAM|MALLOC_CAP_8BIT)));}
static uint32_t paletteBenchMedian(uint32_t *v){for(int i=1;i<31;i++)for(int j=i;j && v[j]<v[j-1];j--){auto t=v[j];v[j]=v[j-1];v[j-1]=t;}return v[15];}
static inline void paletteBenchDraw(int mode,int y0,int y1){
#if MPAL_BENCH_BASELINE_ROWS
  parallelRows(mode==0?rasterRowsBefore:rasterRows,y0,y1);
#else
  parallelRows(rasterRows,y0,y1);
#endif
}
static void runRoadPaletteBenchmark(){
  paletteBenchMemory("before");
  if(!helperTask){Serial.println("MPAL BENCH FAIL no-helper");return;}
  auto *raw=static_cast<uint8_t *>(ps_malloc(paletteBenchRawBytes));
  auto *inflater=static_cast<tinfl_decompressor *>(ps_malloc(sizeof(tinfl_decompressor)));
  if(!raw || !inflater){Serial.println("MPAL BENCH FAIL allocation");return;}
  tinfl_init(inflater);size_t input=sizeof(paletteBenchCompressed),output=paletteBenchRawBytes;
  auto status=tinfl_decompress(inflater,paletteBenchCompressed,&input,raw,raw,&output,TINFL_FLAG_PARSE_ZLIB_HEADER|TINFL_FLAG_USING_NON_WRAPPING_OUTPUT_BUF);free(inflater);
  if(status!=TINFL_STATUS_DONE || input!=sizeof(paletteBenchCompressed) || output!=paletteBenchRawBytes){Serial.println("MPAL BENCH FAIL inflate");return;}
  uint32_t hash=2166136261u;for(size_t i=0;i<output;i++)hash=(hash^raw[i])*16777619u;
  if(hash!=paletteBenchFNV){Serial.println("MPAL BENCH FAIL integrity");return;}
  size_t offset=0;
  for(int mode=0;mode<2;mode++){
    auto &h=paletteBenchHeaders[mode];
    if(!rasterCheck(raw+offset,paletteBenchWireBytes[mode],h,RASTER_MAX_PX,RASTER_BUF_BYTES) || h.dataEnd!=paletteBenchWireBytes[mode] || h.semanticVersion!=paletteBenchVersions[mode] || h.palette!=bool(paletteBenchVersions[mode]) || h.bytes!=720000){Serial.println("MPAL BENCH FAIL header");return;}
    paletteBenchSources[mode]=static_cast<uint8_t *>(ps_malloc(h.bytes));if(!paletteBenchSources[mode]){Serial.println("MPAL BENCH FAIL source-allocation");return;}
    rasterDecode(raw+offset,h,paletteBenchSources[mode]);
    if(h.palette)for(int i=0;i<16;i++)paletteBenchPalettes[mode][i]=rasterU16(raw+offset+16+2*i);
    offset+=paletteBenchWireBytes[mode];
  }
  free(raw);
  const auto &a=paletteBenchHeaders[0],&b=paletteBenchHeaders[1];
  if(a.x0!=b.x0 || a.y0!=b.y0 || a.frame!=b.frame || a.width!=b.width || a.height!=b.height || a.mm!=b.mm){Serial.println("MPAL BENCH FAIL world-pose");return;}
  auto *baseline=static_cast<uint16_t *>(ps_malloc(LCD_WIDTH*LCD_HEIGHT*2));if(!baseline){Serial.println("MPAL BENCH FAIL frame-allocation");return;}
  paletteBenchMemory("resident");unsigned failures=0,unchanged=0,cases=0;
  for(int theme=1;theme<=3;theme++)for(int night=0;night<2;night++)for(int angle:{0,45,90})for(float scale:{.38f,.6f}){
    themeIdx=theme;nightOn=night;float r=angle*PI/180.f;float cx=a.x0+1200,cy=a.y0-1200;
    // Selection and palette preparation stay outside the paired row-render/barrier timing.
    uint16_t colors[2][16];for(int mode=0;mode<2;mode++){paletteBenchSelect(mode);drawRasterMap(cx,cy,scale,cosf(r),sinf(r));memcpy(colors[mode],RM.pal,sizeof(RM.pal));}
    auto select=[&](int mode){paletteBenchSelect(mode);memcpy(RM.pal,colors[mode],sizeof(RM.pal));};
    int y0=CX-213,y1=CX+213;
    for(int i=0;i<8;i++)for(int mode=0;mode<2;mode++){select(mode);paletteBenchDraw(mode,y0,y1);}
    uint32_t times[2][31];for(int i=0;i<31;i++)for(int turn=0;turn<2;turn++){
      int mode=(i+turn)&1;select(mode);uint32_t start=micros();paletteBenchDraw(mode,y0,y1);times[mode][i]=micros()-start;
    }
    select(0);paletteBenchDraw(0,y0,y1);memcpy(baseline,RM.fb,LCD_WIDTH*LCD_HEIGHT*2);select(1);paletteBenchDraw(1,y0,y1);
    unsigned changed=0,pixels=0;for(int y=y0;y<y1;y++)if(fabsf(y+.5f-CX)<212)for(int x=mapCircleRows.left[y];x<=mapCircleRows.right[y];x++){pixels++;changed+=baseline[y*LCD_WIDTH+x]!=RM.fb[y*LCD_WIDTH+x];}
    uint32_t oldUs=paletteBenchMedian(times[0]),newUs=paletteBenchMedian(times[1]);bool pass=oldUs && uint64_t(newUs)*10<=uint64_t(oldUs)*11;
    failures+=!pass;unchanged+=!changed;cases++;
    Serial.printf("MPAL BENCH theme=%d night=%d angle=%d scale=%.2f old_us=%u new_us=%u changed=%u pixels=%u budget=%s\n",theme,night,angle,scale,oldUs,newUs,changed,pixels,pass?"PASS":"FAIL");delay(1);
  }
  free(baseline);paletteBenchMemory("after-cases");
  Serial.printf("MPAL BENCH summary cases=%u failures=%u unchanged=%u oldwire=%u newwire=%u status=%s G=NOT_RUN scope=stable-render-only\n",cases,failures,unchanged,unsigned(paletteBenchWireBytes[0]),unsigned(paletteBenchWireBytes[1]),failures||unchanged?"FAIL":"PASS");
}
