#include <cassert>
#include <cstdio>
#include "../boards/175/MotoNav/src/protocol/ReceivePolicy.h"

// v7.x C1 回归：超长写必须整包丢弃（0），不得截断入队。
// RXQ_MAX 必须覆盖 setMTU(517)-3=514 的合法上限，否则 Android 按 MTU-3 分片会被截断出洞。
int main() {
  static_assert(RXQ_MAX >= 514, "RXQ_MAX must cover setMTU(517)-3 = 514");
  assert(rxqAcceptLen(0) == 0);          // 空包（onWrite 更早已经挡掉）
  assert(rxqAcceptLen(1) == 1);
  assert(rxqAcceptLen(20) == 20);        // #f/#q 快速路径长度
  assert(rxqAcceptLen(511) == 511);      // iOS 上限 509 附近
  assert(rxqAcceptLen(513) == 513);
  assert(rxqAcceptLen(514) == 514);      // MTU 517 的最大合法 ATT 写
  assert(rxqAcceptLen(515) == 0);        // 超长：丢弃而非截断
  assert(rxqAcceptLen(600) == 0);
  assert(rxqAcceptLen((size_t)-1) == 0);
  printf("RxQueuePolicyTest ok (RXQ_MAX=%d)\n", RXQ_MAX);
  return 0;
}
