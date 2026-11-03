#pragma once
// 纯 C 的 HUD 文本格式化（宿主可测）。导航热路径（20-30fps 每帧多次）用它写栈缓冲，
// 替代每帧 3-8 次 String 堆分配（v7.x W6：长期碎片化的最主要来源）。
// 输出与 VectorDrawing.h 的 distText / String(int) 逐字节一致：
//   arduino-esp32 的 String(double,1) 走 dtostrf，dtostrf 内部就是 sprintf("%.*f")，
//   所以 "%.1fkm" / "%dm" / "%d" 与原实现的任何输入输出相同。
#include <stdio.h>
#include <stddef.h>

// 复刻 distText(int m)：>=1000m → "%.1fkm"（m/1000.0），否则 "%dm"
static inline void hudDistText(char *out, size_t n, int m) {
  if (m >= 1000) snprintf(out, n, "%.1fkm", (double)m / 1000.0);
  else           snprintf(out, n, "%dm", m);
}

// String(long) 的等价物，返回写出长度（不含 NUL），失败返回负值
static inline int hudFmtInt(char *out, size_t n, long v) {
  return snprintf(out, n, "%ld", v);
}
