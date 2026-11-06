#!/usr/bin/env python3
"""TDD regression for wake-vs-flush panel ownership.

The production controlWake body is compiled with a barrier stub. A busy barrier
must prevent displayOn/setBrightness and must never be bypassed by a direct
xSemaphoreTake timeout branch.
"""
import pathlib, subprocess, tempfile

root = pathlib.Path(__file__).resolve().parents[3]
source = (root / "firmware/boards/175/MotoNav/src/power/DeviceControlRuntime.h").read_text()
start = source.index("void controlWake()")
end = source.index("\nbool controlTouchGate", start)
wake = source[start:end]

stubs = r'''
#include <cassert>
#include <cstdint>
#include <stdexcept>
#include <string>

#define pdMS_TO_TICKS(x) (x)
#define pdTRUE 1

struct DeviceControlsStub {
    bool asleep = false;
    void wake() {}
};
DeviceControlsStub deviceControls;

int panelCalls = 0;
struct PanelStub {
    void displayOn() { ++panelCalls; }
    void setBrightness(int) { ++panelCalls; }
};
PanelStub panelObj;
PanelStub *panel = &panelObj;
int controlBrightness = 0;
bool controlWakeFrame = false;
bool navDirty = false, wxDirty = false, musicDirty = false;
uint32_t idlePowerOffTimer = 0;
int flushDone = 1;
int gives = 0;
int takeResult = 0;
int barrierCalls = 0;
bool barrierFail = false;

uint32_t millis() { return 0; }
void idlePowerOffReset(uint32_t *, uint32_t) {}
void controlCancelGestures() {}
void flushWait() {
    ++barrierCalls;
    if (barrierFail) throw std::runtime_error("flush busy");
}
int xSemaphoreTake(int, int) { return takeResult; }
void xSemaphoreGive(int) { ++gives; }
struct SerialStub { void println(const char *) {} };
SerialStub Serial;
'''

test = r'''
int main() {
    barrierFail = true;
    panelCalls = 0;
    try { controlWake(); assert(false); }
    catch (const std::runtime_error &) { assert(panelCalls == 0 && barrierCalls == 1); }

    barrierFail = false;
    barrierCalls = 0;
    panelCalls = 0;
    gives = 0;
    takeResult = 1;
    controlWake();
    assert(barrierCalls == 1 && panelCalls == 2 && gives == 1);
    return 0;
}
'''

code = stubs + "\n" + wake + "\n" + test
with tempfile.TemporaryDirectory() as d:
    path = pathlib.Path(d) / "panel_ownership.cpp"
    path.write_text(code)
    binary = pathlib.Path(d) / "panel_ownership"
    subprocess.run(["c++", "-std=c++17", "-Wno-unknown-attributes", str(path), "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
print("controlWake flush barrier ownership regression passed")
