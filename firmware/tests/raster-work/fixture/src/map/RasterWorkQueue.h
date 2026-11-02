#pragma once
#include "../../RasterWork.h"

RasterWork pendingRasterWork;
int pendingRasterId=-1,pendingRasterTheme=-1;
uint32_t pendingRasterEpoch=0;
bool pendingRasterKeep=false,pendingRasterCarry=false;
uint32_t rasterProcessingUs=0,rasterMaxSliceUs=0,rasterQueuedAt=0;

static void rasterCommitTiming(uint32_t started) {
  const uint32_t now=micros(),elapsed=now-started;
  rasterProcessingUs+=elapsed;if(elapsed>rasterMaxSliceUs)rasterMaxSliceUs=elapsed;
  Serial.printf("RASTER commit type=3 id=%d theme=%d elapsed_us=%lu processing_us=%lu max_slice_us=%lu\n",
      pendingRasterId,pendingRasterTheme,(unsigned long)(now-rasterQueuedAt),
      (unsigned long)rasterProcessingUs,(unsigned long)rasterMaxSliceUs);
}

void cancelPendingRaster() {
  Bulk &b=bulks[3];
  if(pendingAck=="K,3,"+String(b.id))pendingAck="";
  b.done=false;b.got=0;memset(b.mask,0,sizeof(b.mask));
  rasterWorkCancel(pendingRasterWork);
}
bool queueRasterWork(const uint8_t *p,uint32_t len,int id) {
  RasterHeader next;
  if(!rasterCheck(p,len,next,RASTER_MAX_PX,RASTER_BUF_BYTES))return false;
  rasterQueuedAt=micros();rasterProcessingUs=0;rasterMaxSliceUs=0;
  pendingRasterId=id;pendingRasterTheme=themeIdx;
  pendingRasterEpoch=mediaConnectionEpoch;pendingRasterCarry=rasterBuildingCarryOn;
  if(next.dataEnd!=len) {
    if(!parseRaster(p,len))return false; // Existing synchronous geometry compatibility path.
    rasterCommitTiming(rasterQueuedAt);return true;
  }
  if(!rasterBackBuf)rasterBackBuf=(uint8_t *)ps_malloc(RASTER_BUF_BYTES);
  if(!rasterBackBuf)return false;
  RasterHeader old=currentRasterHeader();
  pendingRasterKeep=canKeepRaster(old,next);
  // The back map is now work-in-progress. Keep drawing the untouched front.
  rasterBackValid=false;
#if MOTONAV_RASTER_SMOOTHING
  const bool buildRasterTiles=!next.palette && themeIdx>=1 && themeIdx<=3;
  if(buildRasterTiles)prepareRasterTiles();
#endif
  rasterWorkBegin(pendingRasterWork,p,next,rasterBackBuf,rasterBuf,old,
                  pendingRasterKeep && rasterBuildingCarryOn && (themeIdx>=1 && themeIdx<=3)
#if MOTONAV_RASTER_SMOOTHING
                  ,buildRasterTiles?rasterBackTiles:nullptr
#endif
                  );
  return true;
}
void pollRasterWork() {
  Bulk &b=bulks[3];
  if(!pendingRasterWork.active && !b.done)return;
  if(!bleConnected || !bleAuthed || pendingRasterEpoch!=mediaConnectionEpoch ||
     b.id!=pendingRasterId || (pendingRasterWork.active && b.buf!=pendingRasterWork.packet) ||
     pendingRasterTheme!=themeIdx || pendingRasterCarry!=rasterBuildingCarryOn) {
    cancelPendingRaster();return;
  }
  if(!pendingRasterWork.active)return;
  const uint32_t started=micros();
  do {
    if(rasterWorkStep(pendingRasterWork)) {
      if(!bleConnected || !bleAuthed || pendingRasterEpoch!=mediaConnectionEpoch) {cancelPendingRaster();return;}
      installDecodedRaster(pendingRasterWork.packet,pendingRasterWork.next,pendingRasterWork.old,pendingRasterKeep
#if MOTONAV_RASTER_SMOOTHING
          ,pendingRasterWork.tiles!=nullptr
#endif
          );
      b.done=true;pendingAck="K,3,"+String(pendingRasterId);navDirty=true;
      rasterCommitTiming(started);
      rasterWorkCancel(pendingRasterWork);
      return;
    }
  } while((uint32_t)(micros()-started)<16000);
  const uint32_t elapsed=micros()-started;
  rasterProcessingUs+=elapsed;if(elapsed>rasterMaxSliceUs)rasterMaxSliceUs=elapsed;
}
