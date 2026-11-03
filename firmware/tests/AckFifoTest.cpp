#include <cassert>
#include <cstdio>
#include <cstring>
#include "../boards/175/MotoNav/src/protocol/AckFifo.h"

// v7.x W4 回归：同一轮主循环里多个批次完成时 ack 不再互相覆盖；取消语义保留。
int main() {
  { // 基本顺序 + drain-all
    AckFifo f;
    char out[AckFifo::SLOT_LEN];
    assert(!f.pop(out));                    // 空取
    f.pushf("K,%d,%d", 2, 7);
    f.pushf("K,%d,%d", 4, 9);
    f.pushf("N,%d,%d", 3, 5);
    assert(f.count == 3 && f.dropped == 0);
    assert(f.pop(out) && !strcmp(out, "K,2,7"));
    assert(f.pop(out) && !strcmp(out, "K,4,9"));
    assert(f.pop(out) && !strcmp(out, "N,3,5"));
    assert(!f.pop(out));                    // 排空
  }
  { // 原来的 bug 场景：单槽覆盖会丢 K,2,7；FIFO 必须两个都保住
    AckFifo f;
    char out[AckFifo::SLOT_LEN];
    f.push("K,2,7");
    f.push("K,4,9");
    assert(f.pop(out) && !strcmp(out, "K,2,7"));
    assert(f.pop(out) && !strcmp(out, "K,4,9"));
  }
  { // 溢出丢最旧 + 计数
    AckFifo f;
    char out[AckFifo::SLOT_LEN];
    for (int i = 0; i < AckFifo::SLOTS + 2; i++) f.pushf("K,1,%d", i);
    assert(f.dropped == 2 && f.count == AckFifo::SLOTS);
    assert(f.pop(out) && !strcmp(out, "K,1,2"));   // 0、1 被挤掉，最旧剩 2
  }
  { // cancelPendingRaster 语义：只撤指定的 "K,3,<id>"，其他保留且顺序不变
    AckFifo f;
    char out[AckFifo::SLOT_LEN];
    f.push("K,2,7");
    f.push("K,3,42");
    f.push("K,4,9");
    f.removeAck(3, 42);
    assert(f.count == 2);
    assert(f.pop(out) && !strcmp(out, "K,2,7"));
    assert(f.pop(out) && !strcmp(out, "K,4,9"));
  }
  { // 撤不存在的 id：不动队列
    AckFifo f;
    char out[AckFifo::SLOT_LEN];
    f.push("K,3,42");
    f.removeAck(3, 43);
    f.removeAck(2, 42);
    assert(f.count == 1);
    assert(f.pop(out) && !strcmp(out, "K,3,42"));
  }
  { // 空串 / null 不入队
    AckFifo f;
    assert(!f.push(""));
    assert(!f.push(nullptr));
    assert(f.count == 0);
  }
  printf("AckFifoTest ok\n");
  return 0;
}
