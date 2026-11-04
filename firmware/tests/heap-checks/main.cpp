// 175c.12diag HeapChecks.h 宿主测试：正常轮转、空闲强制遍历、损坏即停（abort）、
// 阶段环形记录、10s 自证行。abort() 以异常代替，验证检测后立即停止执行。
#include <cassert>
#include <cstdio>
#include <stdexcept>
#include <string>
#define abort() throw std::runtime_error("abort")
#include "diagnostics/HeapChecks.h"

unsigned long gMs = 0, gUs = 0;
SerialCapture Serial;
bool stubIntegrityOk = true;
bool stubSawInternal = false;
bool heap_caps_check_integrity(uint32_t caps, bool print_errors) {
  stubSawInternal = (caps == MALLOC_CAP_INTERNAL) && print_errors;
  return stubIntegrityOk;
}

using HeapChecks::ring;
static void reset() {
  for (auto &r : ring) r = {0, 0, 0, 0, 0};
  HeapChecks::head = HeapChecks::total = HeapChecks::walks = HeapChecks::walksThisPass = 0;
  HeapChecks::nextWalk = HeapChecks::S_MSG;
  HeapChecks::maxWalkUs = 0;
  HeapChecks::minStack = 0xFFFF;
  HeapChecks::failTick = 0;
  HeapChecks::failStage = 0;
  HeapChecks::lastStatMs = 0;
  gMs = 1000; gUs = 5000;
  Serial.lines.clear();
  stubIntegrityOk = true;
}

static const HeapChecks::Rec &lastRec() { return ring[(HeapChecks::head - 1) % 64]; }

int main() {
  { // 1. 正常轮转：首轮每个阶段各遍历一次，遍历条目记录耗时/栈余量
    reset();
    const uint8_t stages[] = {1, 2, 3, 4, 5, 6};
    for (uint8_t s : stages) { gMs += 10; HeapChecks::stage(s); }
    assert(HeapChecks::walks == 6);
    assert(HeapChecks::nextWalk == 7);                      // 指向 G 密集阶段
    assert(lastRec().stage == 6 && lastRec().flags == 1 && lastRec().dur == 0);
    assert(lastRec().stack == 100);
    assert(HeapChecks::minStack == 100);
    assert(stubSawInternal);                                // 确实用了 MALLOC_CAP_INTERNAL+print
    assert(!Serial.lines.empty() && Serial.lines[0].rfind("HEAPCHK n=", 0) == 0);  // 首次 S_MSG 自证行
  }
  { // 2. 轮转停摆自愈：nextWalk 停在未触发阶段时，空闲 loop 在 S_MSG 强制遍历
    reset();
    HeapChecks::nextWalk = 7;                               // G 不活动，7 永不触发
    HeapChecks::stage(1);                                   // 首次（total==0）不强推
    assert(HeapChecks::walks == 0);
    HeapChecks::stage(1);                                   // 第二轮：上轮 0 次遍历 → 强制
    assert(HeapChecks::walks == 1);
    assert(lastRec().flags == 1);
    assert(HeapChecks::nextWalk == 2);                      // 强制后从 2 继续
    HeapChecks::stage(2);
    assert(HeapChecks::walks == 2);
  }
  { // 3. 损坏即停：遍历发现失败 → 打印 FAIL + 最近环形记录 → abort（异常）
    reset();
    HeapChecks::nextWalk = 8;                               // 让 GFIFO_POST 承担遍历
    HeapChecks::stage(1); HeapChecks::stage(2); HeapChecks::stage(3);
    stubIntegrityOk = false;
    bool threw = false;
    try { HeapChecks::stage(8); }
    catch (const std::runtime_error &) { threw = true; }
    assert(threw);                                          // 检测后必须停止执行
    assert(HeapChecks::failStage == 8);
    assert(lastRec().flags == 3);                           // 遍历过 + 失败
    bool sawFail = false, sawRing = false, sawBracket = false;
    for (auto &l : Serial.lines) {
      if (l.rfind("HEAPCHK FAIL stage=8", 0) == 0) sawFail = true;
      if (l == "HEAPCHK ring old->new:") sawRing = true;
      if (l.find("s=3 f=0") != std::string::npos) sawBracket = true;  // 失败前的中间阶段在环里
    }
    assert(sawFail && sawRing && sawBracket);
  }
  { // 4. 环形回绕：写入 >64 条后仍保留最近 64 条，无越界（ASan 兜底）
    reset();
    HeapChecks::nextWalk = 0;                               // 任何阶段都不匹配 → 只记录
    for (int i = 0; i < 100; i++) { gMs += 10; HeapChecks::stage(uint8_t(i % 11 + 2)); }  // 避开 S_MSG 触发强制
    assert(HeapChecks::total == 100);
    assert(lastRec().stage == (99 % 11) + 2);
    assert(HeapChecks::walks == 0);
    HeapChecks::stage(1);                                   // total>0 且上轮 0 遍历 → S_MSG 强制
    assert(HeapChecks::walks == 1);
  }
  { // 5. 10s 自证行节流：10s 内不重复
    reset();
    gMs = 20000;
    HeapChecks::stage(1); gMs = 29999; HeapChecks::stage(1);
    size_t n1 = Serial.lines.size();
    gMs = 30000; HeapChecks::stage(1);
    assert(Serial.lines.size() == n1 + 1);                  // 恰好跨过 10s 才补一条
    assert(Serial.lines.back().rfind("HEAPCHK n=", 0) == 0);
  }
  printf("heap-checks ok\n");
  return 0;
}
