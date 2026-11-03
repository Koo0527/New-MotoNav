#include <cassert>
#include <cstdio>
#include <cstring>
#include "../boards/175/MotoNav/src/graphics/HudText.h"

// v7.x W6 回归：hudDistText 必须与 VectorDrawing.h 的 distText(int) 逐字节一致
// （>=1000m → "%.1fkm"，否则 "%dm"；String(double,1) 底层就是 sprintf("%.1f")）。
int main() {
  char b[16];
  { // 米分支
    hudDistText(b, sizeof(b), 0);    assert(!strcmp(b, "0m"));
    hudDistText(b, sizeof(b), 5);    assert(!strcmp(b, "5m"));
    hudDistText(b, sizeof(b), 999);  assert(!strcmp(b, "999m"));
  }
  { // 公里分支（舍入选无歧义值：不落在 x.x5 上）
    hudDistText(b, sizeof(b), 1000);  assert(!strcmp(b, "1.0km"));
    hudDistText(b, sizeof(b), 1001);  assert(!strcmp(b, "1.0km"));
    hudDistText(b, sizeof(b), 1500);  assert(!strcmp(b, "1.5km"));
    hudDistText(b, sizeof(b), 9999);  assert(!strcmp(b, "10.0km"));
    hudDistText(b, sizeof(b), 12345); assert(!strcmp(b, "12.3km"));
  }
  { // 小缓冲不越界：截断后一定 NUL 结尾
    char s[4];
    hudDistText(s, sizeof(s), 9999);
    assert(strlen(s) < sizeof(s));
  }
  { // hudFmtInt ≡ String(long)
    char t[16];
    assert(hudFmtInt(t, sizeof(t), 0) == 1 && !strcmp(t, "0"));
    assert(hudFmtInt(t, sizeof(t), 42) == 2 && !strcmp(t, "42"));
    assert(hudFmtInt(t, sizeof(t), -7) == 2 && !strcmp(t, "-7"));
    assert(hudFmtInt(t, sizeof(t), 123456) == 6 && !strcmp(t, "123456"));
  }
  printf("HudTextTest ok\n");
  return 0;
}
