#pragma once
// v7.x 待发确认的定长 FIFO：同一轮主循环里多个批次完成时不再互相覆盖（原来单槽 String 会丢 ack）。
// 纯 C++、无 Arduino 依赖，桌面单测（firmware/tests）可直接包含。
#include <stdint.h>
#include <stdarg.h>
#include <stdio.h>
#include <string.h>

struct AckFifo {
  static const uint8_t SLOTS = 4;
  static const uint8_t SLOT_LEN = 24;   // 消息形如 "K,3,255"，24 留足余量
  char buf[SLOTS][SLOT_LEN];
  uint8_t head = 0, count = 0;          // head = 最旧；(head+count-1)%SLOTS = 最新
  uint32_t dropped = 0;                 // 溢出丢最旧的计数（诊断用）

  bool push(const char *s) {
    if (!s || !s[0]) return false;
    if (count == SLOTS) {               // 满：丢最旧腾位置
      head = (head + 1) % SLOTS;
      count--;
      dropped++;
    }
    uint8_t idx = (head + count) % SLOTS;
    strncpy(buf[idx], s, SLOT_LEN - 1);
    buf[idx][SLOT_LEN - 1] = 0;
    count++;
    return true;
  }
  void pushf(const char *fmt, ...) {
    char tmp[SLOT_LEN];
    va_list ap; va_start(ap, fmt);
    vsnprintf(tmp, sizeof(tmp), fmt, ap);
    va_end(ap);
    push(tmp);
  }
  bool pop(char *out) {                 // 主循环通知处 drain-all
    if (count == 0) return false;
    strcpy(out, buf[head]);
    head = (head + 1) % SLOTS;
    count--;
    return true;
  }
  // 撤销还没发出去的 "K,<type>,<id>"（type=3 批次被取消时用，对齐原 cancelPendingRaster 语义）
  void removeAck(int type, int id) {
    char key[SLOT_LEN];
    snprintf(key, sizeof(key), "K,%d,%d", type, id);
    for (uint8_t i = 0; i < count; i++) {
      if (strcmp(buf[(head + i) % SLOTS], key) == 0) {
        for (uint8_t j = i; j + 1 < count; j++)
          strcpy(buf[(head + j) % SLOTS], buf[(head + j + 1) % SLOTS]);
        count--;
        return;                          // 只删最早的一条匹配
      }
    }
  }
};
