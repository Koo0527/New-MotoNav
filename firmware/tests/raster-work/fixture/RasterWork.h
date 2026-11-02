#pragma once
#include "RasterBuildingCarry.h"
#include "RasterSmoothing.h"

// Main-loop-owned work only: input and the visible front map stay immutable
// until completion. Cancellation discards the unfinished back map.
struct RasterWork {
  const uint8_t *packet=nullptr,*previous=nullptr;
  uint8_t *output=nullptr;
  RasterHeader next={},old={};
  RasterDecodeCursor decode;
  RasterCarryCursor carry;
  uint8_t *tiles=nullptr;
  size_t scanned=0;
  bool carried=false;
  bool inherit=false,carrying=false,complete=false,active=false;
};
static inline void rasterWorkBegin(RasterWork &s,const uint8_t *packet,const RasterHeader &next,
                                    uint8_t *output,const uint8_t *previous,
                                    const RasterHeader &old,bool inherit,uint8_t *tiles=nullptr) {
  s=RasterWork{};
  s.packet=packet;s.next=next;s.output=output;s.previous=previous;s.old=old;
  s.inherit=inherit;s.active=true;s.tiles=tiles;
}
static inline void rasterWorkCancel(RasterWork &s) {s=RasterWork{};}
static inline bool rasterWorkStep(RasterWork &s,uint32_t pixels=4096,uint32_t tiles=8) {
  if(!s.active || s.complete)return s.complete;
  if(!s.carrying) {
    if(!rasterDecodeStep(s.packet,s.next,s.output,s.decode,pixels))return false;
    s.carrying=true;
    if(s.inherit)s.carry=rasterCarryBegin(s.previous,s.old,s.output,s.next);
  }
  if(!s.carried) {
    if(s.inherit && !rasterCarryStep(s.previous,s.old,s.output,s.next,s.carry,tiles))return false;
    s.carried=true;
  }
  s.complete=!s.tiles || rasterTileScan(s.output,s.next,s.tiles,s.scanned,tiles);
  return s.complete;
}
