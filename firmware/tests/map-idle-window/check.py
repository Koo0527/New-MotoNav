"""Test the real continuous navigation draw gate with fake flush ownership."""
import os
import pathlib
import subprocess
import tempfile

here = pathlib.Path(__file__).resolve()
source = (here.parents[2] / "boards/175/MotoNav/MotoNav.ino").read_text()
start = source.index("  weatherTick();")
end = source.index("  // 5.", start)
gate = source[start:end]
harness = r'''
#include <cassert>
#include <cstdint>
#include <string>

static uint32_t now;
static uint32_t millis() { return now; }
static std::string actions;
static bool inNav = true, navDirty, mapNow = true, controlWakeFrame;
static bool fxOn, callOn, pairOn, sliding;
static int page;
static bool flushDone = true, token = true;

static void weatherTick() {}
static void flushWait() { assert(flushDone && token); token = false; actions += "take "; }
static void vTaskDelay(int ticks) {
  assert(ticks == 2 && (!flushDone || !token));
  now += ticks;
  actions += "delay ";
}
static void xSemaphoreGive(bool semaphore) {
  assert(semaphore && !token); token = true; actions += "give ";
}
static void drawNavFrame() { assert(token); actions += "draw"; }

static void draw() {
  navDirty = true;
  actions.clear();
GATE
}

int main() {
  now = UINT32_MAX - 20;
  draw();
  assert(actions == "draw" && !navDirty);
  now += 249;
  draw();
  assert(actions == "draw");
  ++now;
  draw();
  assert(actions == "take delay give draw");
  now += 249;
  draw();
  assert(actions == "draw");
  ++now;
  controlWakeFrame = true;
  draw();
  assert(actions == "draw");
  controlWakeFrame = false;
  callOn = true;
  draw();
  assert(actions.empty());
  callOn = false;
  now += 500;
  draw();
  assert(actions == "draw");
  flushDone = false;
  now += 250;
  draw();
  assert(actions == "delay draw");
  mapNow = false;
  now += 500;
  draw();
  assert(actions == "draw");
  mapNow = true;
  draw();
  assert(actions == "draw");
}
'''
with tempfile.TemporaryDirectory() as temporary:
    src = pathlib.Path(temporary) / "wiring.cpp"
    bin_path = src.with_suffix("")
    src.write_text(harness.replace("GATE", gate))
    subprocess.run([os.environ.get("CXX", "c++"), "-std=c++17", "-O2",
                    "-fsanitize=address,undefined", str(src), "-o", str(bin_path)], check=True)
    subprocess.run([str(bin_path)], check=True)
print("map idle window preserves first frame, wake, wraparound and flush ownership")
