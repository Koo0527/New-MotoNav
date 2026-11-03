#pragma once
// 位置预测、地图缓冲初始化及矢量地图解析。由 MotoNav.ino 按依赖顺序包含，仅编译一次。
// v6.7 推算 t 时刻（再加 lead 秒）的位置和朝向：按当前车速和转弯速度沿弧线往前推（最多推 1.5 秒）
void predictPose(unsigned long t, float lead, float &x, float &y, float &h) {
  float tau = fminf((t - posAt) / 1000.0f + lead, 1.5f);
  if (tau < 0) tau = 0;
  float v = posKmh / 3.6f;
  float rate = (t - posAt) > 2500 ? 0 : hdgRate;        // 很久没新定位（停车等）：不再按转弯推
  float hEnd = posHdg + rate * tau;
  float hMid = (posHdg + hEnd) * 0.5f * PI / 180;      // 弧线用中间的朝向近似
  x = posX + sinf(hMid) * v * tau;
  y = posY + cosf(hMid) * v * tau;
  h = hEnd;
}
bool viewInit = false;
unsigned long lastMapDraw = 0;

// 画图用的临时数组（内部内存，速度快）
float *tmpX = nullptr, *tmpY = nullptr;

void mapInit() {
  mapCircleRows.init(CX,212.0f);
  routeSegmentCache.clear();
  // v7.x 每个分配都做 NULL 检查：失败时打印内存现场并重启（替代 NULL+offset 野写）
  bulks[1].cap = MAP_MAX;   bulks[1].buf = (uint8_t *)psMallocHalt("bulks1", MAP_MAX);
  bulks[2].cap = ROUTE_MAX; bulks[2].buf = (uint8_t *)psMallocHalt("bulks2", ROUTE_MAX);
  bulks[3].cap = RASTER_MAX_BYTES; bulks[3].buf = (uint8_t *)psMallocHalt("bulks3", RASTER_MAX_BYTES);
  bulks[4].cap = GHOST_MAX; bulks[4].buf = (uint8_t *)psMallocHalt("bulks4", GHOST_MAX);          // v4.4
  ghostX = (int32_t *)psMallocHalt("ghostX", sizeof(int32_t) * GHOST_PTS);
  ghostY = (int32_t *)psMallocHalt("ghostY", sizeof(int32_t) * GHOST_PTS);
  gbBox  = (int32_t *)psMallocHalt("gbBox", sizeof(int32_t) * 4 * (GHOST_PTS / RB_STEP + 2));
  rasterBuf = (uint8_t *)psMallocHalt("rasterBuf", RASTER_BUF_BYTES);
  for (int t = 1; t <= 4; t++) { bulks[t].id = -1; bulks[t].done = false; }
  mapShow = (uint8_t *)psMallocHalt("mapShow", MAP_MAX);
  featOff = (uint32_t *)psMallocHalt("featOff", sizeof(uint32_t) * FEAT_MAX);
  featNp  = (uint16_t *)psMallocHalt("featNp", sizeof(uint16_t) * FEAT_MAX);
  featCls = (uint8_t *)psMallocHalt("featCls", FEAT_MAX);
  featBox = (int16_t *)psMallocHalt("featBox", sizeof(int16_t) * 4 * FEAT_MAX);
  routeX = (int32_t *)psMallocHalt("routeX", sizeof(int32_t) * ROUTE_PTS);
  routeY = (int32_t *)psMallocHalt("routeY", sizeof(int32_t) * ROUTE_PTS);
  rbBox  = (int32_t *)psMallocHalt("rbBox", sizeof(int32_t) * 4 * (ROUTE_PTS / RB_STEP + 2));
  routeCum = (float *)psMallocHalt("routeCum", sizeof(float) * ROUTE_PTS);                         // v5.0
  routeCurv = (uint8_t *)psMallocHalt("routeCurv", ROUTE_PTS);                                        // v6.1
  lightX = (int32_t *)psMallocHalt("lightX", sizeof(int32_t) * LIGHT_MAX);
  lightY = (int32_t *)psMallocHalt("lightY", sizeof(int32_t) * LIGHT_MAX);
  lightU = (float *)psMallocHalt("lightU", sizeof(float) * LIGHT_MAX);
  tmpX = (float *)mallocHalt("tmpX", sizeof(float) * POLY_PTS);
  tmpY = (float *)mallocHalt("tmpY", sizeof(float) * POLY_PTS);
}

// 解析刚收齐的地图块，建立索引
void parseMap(const uint8_t *p, uint32_t len) {
  mapValid = false;
  if (len < 12) return;
  int frame = rdu16(p);
  int32_t ox = rd32(p + 2), oy = rd32(p + 6);
  int n = rdu16(p + 10);
  uint32_t pos = 12;
  int cnt = 0;
  for (int i = 0; i < n && cnt < FEAT_MAX; i++) {
    if (pos + 3 > len) break;
    uint8_t cls = p[pos];
    uint16_t np = rdu16(p + pos + 1);
    pos += 3;
    if (pos + (uint32_t)np * 4 > len) break;
    int16_t x0 = 32767, y0 = 32767, x1 = -32768, y1 = -32768;
    for (int k = 0; k < np; k++) {
      int16_t x = rd16(p + pos + 4 * k), y = rd16(p + pos + 4 * k + 2);
      if (x < x0) x0 = x;
      if (x > x1) x1 = x;
      if (y < y0) y0 = y;
      if (y > y1) y1 = y;
    }
    featCls[cnt] = cls; featNp[cnt] = np; featOff[cnt] = pos;
    featBox[4 * cnt] = x0; featBox[4 * cnt + 1] = y0; featBox[4 * cnt + 2] = x1; featBox[4 * cnt + 3] = y1;
    cnt++;
    pos += (uint32_t)np * 4;
  }
  mapFeatN = cnt; mapOx = ox; mapOy = oy; mapFrame = frame;
  mapValid = cnt > 0;
  vectorAt = millis();
}
