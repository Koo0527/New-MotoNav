#pragma once
// 175c.12diag 诊断版专用（missions/2026-11-04-175c11-reboot-investigation.md）。
// 背景：175c.11 在 G 仪表/校准/转动窗口内出现内部堆 TLSF 元数据损坏
// （LoadProhibited @ tlsf_walk_pool，首次非法写入落在 ~10.4s 窗口内）。
// 本 helper 在主循环各阶段边界记录阶段号，并对内部堆做轮转完整性遍历，
// 阶段环形记录放入 COREDUMP_DRAM_ATTR 段（.dram2.coredump，随 flash core dump 保存）。
// 发现损坏：串口打印最近阶段序列后 abort()（留 core dump，复位原因与真实崩溃一致）。
// 仅诊断版使用；正式版不含对本文件任何符号的调用。无动态分配。
#include <Arduino.h>
#include <stdlib.h>
#include "esp_attr.h"        // COREDUMP_DRAM_ATTR
#include "esp_heap_caps.h"   // heap_caps_check_integrity
#include "freertos/task.h"   // uxTaskGetStackHighWaterMark

namespace HeapChecks {

enum Stage : uint8_t {
  S_MSG = 1,        // loop：BLE 消息/rx 队列排空后
  S_RASTER = 2,     // loop：pollRasterWork 后
  S_STATS = 3,      // loop：updateStats + sendPendingAck 后
  S_G = 4,          // loop：gInstrumentTick 后
  S_PAGE = 5,       // loop：整页绘制块（含 drawGInstrument）后
  S_FLUSH = 6,      // loop：flushAsync/flushSync 后
  S_GFIFO_PRE = 7,  // gInstrumentTick：readFromFifo 前（括住驱动内部 free/malloc 与 I2C）
  S_GFIFO_POST = 8, // gInstrumentTick：样本估计循环后（括住 a[32]/w[32] 消费）
  S_GNOTIFY = 9,    // gInstrumentNotify：txChar setValue+notify 后
  S_GCAL_PRE = 10,  // gInstrumentSample：校准结论写 NVS 前（Preferences putBytes "gmount2"）
  S_GCAL_POST = 11, // gInstrumentSample：校准结论块结束后
  S_GDRAW = 12,     // gInstrumentPageTick：drawGInstrument 画完后
  S_LAST = 12
};

struct Rec {                 // 单条阶段记录（进 core dump）
  uint32_t ms;               // millis()
  uint32_t dur;              // 遍历耗时 us（未遍历为 0）
  uint16_t stack;            // loopTask 栈余量字（仅遍历条目记录）
  uint8_t stage;
  uint8_t flags;             // bit0=执行了遍历 bit1=遍历发现损坏
};

// 全部 COREDUMP_DRAM_ATTR：abort/崩溃后仍可从 flash core dump 读回
COREDUMP_DRAM_ATTR Rec ring[64];
COREDUMP_DRAM_ATTR uint32_t head = 0;        // 总写入数（环形下标 = head%64）
COREDUMP_DRAM_ATTR uint32_t total = 0;
COREDUMP_DRAM_ATTR uint32_t walks = 0;
COREDUMP_DRAM_ATTR uint32_t walksThisPass = 0;
COREDUMP_DRAM_ATTR uint8_t  nextWalk = S_MSG; // 轮转遍历的目标阶段
COREDUMP_DRAM_ATTR uint32_t maxWalkUs = 0;
COREDUMP_DRAM_ATTR uint16_t minStack = 0xFFFF;
COREDUMP_DRAM_ATTR uint32_t failTick = 0;
COREDUMP_DRAM_ATTR uint8_t  failStage = 0;
COREDUMP_DRAM_ATTR uint32_t lastStatMs = 0;

// 损坏已确认：打印最近阶段序列，然后 abort 留 core dump。
// 注意：此路径不再使用 printf 长行（Arduino printf >63 字符会走堆分配）。
inline void fail(uint8_t stage, uint32_t ms) {
  failStage = stage;
  failTick = ms;
  Serial.printf("HEAPCHK FAIL stage=%u at=%lu\n", stage, (unsigned long)ms);
  Serial.println("HEAPCHK ring old->new:");
  for (uint32_t k = 2; k <= 65; k++) {       // 失败条目本身是最新一条
    const Rec &e = ring[(head + 64 - k) % 64];
    if (!e.stage) continue;                  // 环未写满时的空槽
    Serial.printf(" t=%lu s=%u f=%u d=%lu\n",
                  (unsigned long)e.ms, e.stage, e.flags, (unsigned long)e.dur);
  }
  Serial.println("HEAPCHK aborting for coredump");
  Serial.flush();
  abort();
}

// 10 秒一条自证行（检查在跑、开销、loopTask 最小栈余量）。挂在 S_MSG 上，不碰 MapFrame。
inline void stats(uint32_t now) {
  if (lastStatMs && uint32_t(now - lastStatMs) < 10000) return;
  lastStatMs = now;
  Serial.printf("HEAPCHK n=%lu walks=%lu maxus=%lu stMinB=%u\n",
                (unsigned long)total, (unsigned long)walks,
                (unsigned long)maxWalkUs, (unsigned)(minStack == 0xFFFF ? 0 : minStack * 4));
}

// 每个阶段边界调用一次。轮转策略：仅当 stage==nextWalk 时做全内部堆遍历；
// S_MSG 时若上一轮 loop 一次遍历都没发生（nextWalk 停在未触发的阶段）则强制遍历，
// 保证空闲期也 ≥1 次遍历/loop。任何损坏都会在 ≤ 数个阶段内被下一次遍历抓到，
// 环形记录给出 last-ok 遍历与失败遍历之间全部阶段过渡，写入者被夹在很窄的括号里。
inline void stage(uint8_t st) {
  const bool passStart = (st == S_MSG);
  bool doWalk = (st == nextWalk);
  if (passStart) {
    if (total && walksThisPass == 0) doWalk = true;
    walksThisPass = 0;
  }
  Rec &r = ring[head % 64];
  r.ms = millis(); r.dur = 0; r.stack = 0; r.stage = st; r.flags = 0;
  ++head; ++total;
  if (doWalk) {
    const uint32_t t0 = micros();
    const bool ok = heap_caps_check_integrity(MALLOC_CAP_INTERNAL, true);
    r.dur = uint32_t(micros() - t0);
    r.flags = uint8_t(1 | (ok ? 0 : 2));
    r.stack = (uint16_t)uxTaskGetStackHighWaterMark(nullptr);
    if (r.stack && r.stack < minStack) minStack = r.stack;
    if (r.dur > maxWalkUs) maxWalkUs = r.dur;
    ++walks; ++walksThisPass;
    nextWalk = (st >= S_LAST) ? S_MSG : uint8_t(st + 1);
    if (!ok) fail(st, r.ms);
  }
  if (passStart) stats(r.ms);
}

}  // namespace HeapChecks

// 阶段打点宏：诊断版在各边界一行插入；正式版整体移除时零残留。
#define HEAPCHK(s) HeapChecks::stage(HeapChecks::S_##s)
