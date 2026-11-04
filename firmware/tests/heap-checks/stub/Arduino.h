// 175c.12diag 宿主测试桩：只提供 HeapChecks.h 用到的 Arduino 符号。
#pragma once
#include <cstdio>
#include <cstdarg>
#include <string>
#include <vector>

extern unsigned long gMs, gUs;
inline unsigned long millis() { return gMs; }
inline unsigned long micros() { return gUs; }

struct SerialCapture {
  std::vector<std::string> lines;
  char buf[512];
  void println(const char *s) { lines.push_back(s); }
  void printf(const char *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    vsnprintf(buf, sizeof(buf), fmt, ap); va_end(ap);
    lines.push_back(buf);
  }
  void flush() {}
};
extern SerialCapture Serial;
