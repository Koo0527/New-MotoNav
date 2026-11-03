#pragma once
// v7.x RX 入口校验策略（纯 C++、无 Arduino 依赖），桌面单测（firmware/tests）直接包含。
// 背景：setMTU(517) 时合法单次写上限是 MTU-3=514；原来把超长写截断到 512 入队，
// 会让"完整"分片内部悄悄缺字节且没有任何检测。策略改为：合法长度原样入队，超长整包丢弃。
#include <stdint.h>
#include <stddef.h>

#define RXQ_MAX 514   // 覆盖 setMTU(517)-3 的合法上限；改动这里必须同步改 setMTU

// 返回可入队长度；0 表示应整包丢弃（调用方计数后 return）
static inline size_t rxqAcceptLen(size_t n) { return (n != 0 && n <= (size_t)RXQ_MAX) ? n : 0; }

// 'B' 文字位图分片的 part 序号必须在 [0, parts) 内：越界 part 会设错 mask 位（1UL<<part 对 ≥32 是 UB）
static inline bool bitmapPartInRange(int part, int parts) { return part >= 0 && part < parts; }
