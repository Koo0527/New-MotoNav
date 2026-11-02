#pragma once
#include <math.h>

namespace MapPlayerMarker {
// Geometry is in canvas coordinates; display rotation is applied once by the panel pipeline.
inline int vertices(int theme, float heading, float scale, float x, float y, float *xs, float *ys) {
  static const float drop[][2] = {
    {0,-16},{4,-8},{7,-3},{8.5f,1},{8.5f,5},{7,8.5f},
    {4,11},{0,12},{-4,11},{-7,8.5f},{-8.5f,5},{-8.5f,1},{-7,-3},{-4,-8}
  };
  static const float arrow[][2] = {{0,-15},{-9,10},{0,5},{9,10}};
  const bool vice = theme == 1;
  const int count = vice ? 14 : 4;
  const float a = heading * 0.017453292519943295f;
  const float cs = cosf(a), sn = sinf(a);
  for (int i=0; i<count; ++i) {
    const float px = (vice ? drop[i][0] : arrow[i][0]) * scale;
    const float py = (vice ? drop[i][1] : arrow[i][1]) * scale;
    xs[i] = x + px*cs - py*sn;
    ys[i] = y + px*sn + py*cs;
  }
  return count;
}
}
