#include <cassert>
#include <cstdio>
#include "../boards/175/MotoNav/src/protocol/ReceivePolicy.h"

// v7.x W3 回归：'B' 分片的 part 必须落在 [0, parts)，越界 part 不得污染 recvMask。
int main() {
  assert(bitmapPartInRange(0, 1));
  assert(bitmapPartInRange(0, 32));
  assert(bitmapPartInRange(31, 32));     // parts=32 的最后一个合法分片
  assert(bitmapPartInRange(4, 5));
  assert(!bitmapPartInRange(5, 5));      // part == parts：越界
  assert(!bitmapPartInRange(32, 5));     // 1UL<<32 是 UB，必须整包拒绝
  assert(!bitmapPartInRange(36, 5));     // Xtensa 移位按 32 取模会错设 bit4 —— 必须拒绝
  assert(!bitmapPartInRange(255, 5));
  assert(!bitmapPartInRange(-1, 5));     // 负数同样拒绝
  assert(!bitmapPartInRange(0, 0));     // parts=0（空图走的是另一条清空分支）
  printf("BitmapPartTest ok\n");
  return 0;
}
