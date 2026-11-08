#pragma once
// Benchmark-only pre-multitone rasterRows; source SHA256 0bd6b50697d89a2e268b3083428978b098d37f88cd4d6d46deba6e05bf231e1b.
void __attribute__((optimize("O3"))) rasterRowsBefore(int y0, int y1, int step) {
  uint16_t *fb = RM.fb;
  const uint16_t *pal = RM.pal;
  float cx = RM.cx, cy = RM.cy, sc = RM.sc, cs = RM.cs, sn = RM.sn;
  float inv = 1.0f / sc, kpx = inv / rasMpp;
  int32_t DU = (int32_t)(cs * kpx * 65536.0f), DV = (int32_t)(sn * kpx * 65536.0f);
  const bool useBack=rasterBackValid && rasterBackHeader.frame==rasterFrame && rasterBackHeader.mm==(uint16_t)lroundf(rasMpp*1000) && rasterSemanticMaterials(rasterBackHeader) && (!rasHasPal || rasSemantic) && !rasterViceValid;
  const int backU=useBack ? (int)lroundf((rasX0-rasterBackHeader.x0)/rasMpp) : 0;
  const int backV=useBack ? (int)lroundf((rasterBackHeader.y0-rasY0)/rasMpp) : 0;
#if MOTONAV_RASTER_SMOOTHING
  const bool smooth=rasterTilesValid && themeIdx>=1 && themeIdx<=3 && !RM.pix2 && !rasHasPal && !rasterViceValid;
  const RasterHeader header=currentRasterHeader();
  const uint8_t *smoothBack=useBack?rasterBackBuf:nullptr;
#endif
  const float R = 212;
  for (int y = y0; y < y1; y += step) {
    float dyc = y + 0.5f - CX;
    if (RM.pix2 && (y % PIXB) && y > y0 && fabsf(dyc) < R - 2) {  // v6.1 掌机像素：每 3 行只算第一行，其余照抄
      int xa = mapCircleRows.left[y], xb = mapCircleRows.right[y];
      memcpy(fb + y * LCD_WIDTH + xa, fb + (y - 1) * LCD_WIDTH + xa, (xb - xa + 1) * 2);
      continue;
    }
    if (fabsf(dyc) >= R) continue;
    int xa = mapCircleRows.left[y], xb = mapCircleRows.right[y];
    if (RM.pix2) xa -= xa % PIXB;                       // 掌机像素：列也按 3 个一组对齐
    float rx = (xa + 0.5f - CX) * inv, ry = (MAP_PY - (y + 0.5f)) * inv;
    float dx = rx * cs + ry * sn, dy = -rx * sn + ry * cs;
    float u = (cx + dx - rasX0) / rasMpp, v = (rasY0 - (cy + dy)) / rasMpp;
    int32_t U = (int32_t)(u * 65536.0f), V = (int32_t)(v * 65536.0f);
    uint16_t *row = fb+y*LCD_WIDTH;
    int xstep = RM.pix2 ? PIXB : 1;
    if (RM.pix2) { DU *= PIXB; DV *= PIXB; }
    for (int x = xa; x <= xb; x += xstep) {
      int32_t ui = U >> 16, vi = V >> 16;
      uint8_t idx = 0;
      if ((uint32_t)ui < (uint32_t)rasW && (uint32_t)vi < (uint32_t)rasH) {
        uint32_t k = ((uint32_t)((vi >> 4) * rasBW + (ui >> 4)) << 8) | ((vi & 15) << 4) | (ui & 15);
        if (rasterViceValid) {
          idx = (rasterVice[k] >> viceBaseShift) & 3;
        } else {
          uint8_t b = rasterBuf[k >> 1];
          idx = (k & 1) ? (b >> 4) : (b & 15);
        }
      } else if (useBack) {
        rasterRead(rasterBackBuf,rasterBackHeader,ui+backU,vi+backV,idx);
      }
      uint16_t color=pal[idx];
#if MOTONAV_RASTER_SMOOTHING
      if(smooth)color=rasterSmoothColor(rasterBuf,header,rasterTilesValid?rasterTiles:nullptr,
          smoothBack,rasterBackHeader,pal,U,V,color);
#endif
      row[x] = color;
      for (int k = 1; k < xstep && x + k <= xb; k++) row[x + k] = color;
      U += DU; V += DV;
    }
    if (RM.pix2) { DU /= PIXB; DV /= PIXB; }
  }
}
