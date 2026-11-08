#pragma once
#include <cstdint>

// The round G page is a full-screen redraw. Keep it on a 5 Hz budget so the
// main loop retains time for sampling, A7 production and BLE notification.
struct GPageBudget {
  static constexpr uint32_t intervalMs = 200;
  uint32_t last = 0;
  bool started = false;

  bool due(uint32_t now) {
    if (!started) {
      started = true;
      last = now;
      return true;
    }
    if (uint32_t(now - last) < intervalMs) return false;
    last = now;
    return true;
  }
};
