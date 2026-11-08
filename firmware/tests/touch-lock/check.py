"""Exercise the production lock overlay against an in-memory framebuffer."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[3]
base = root / "firmware/boards/175/MotoNav"
source = (base / "src/power/DeviceControlRuntime.h").read_text()
function = source[source.index("void controlDrawLock()") :]
stub = r'''
#include <cassert>
#include <cstdint>
#include <cstdio>
#include <algorithm>
#include <array>
constexpr int CX=233;
constexpr uint16_t C_BLACK=0,C_YELLOW=0xffe0;
struct Canvas {
  std::array<uint16_t,466*466> pixels{};
  void fillRect(int x,int y,int w,int h,uint16_t c) {
    for(int yy=y;yy<y+h;yy++)for(int xx=x;xx<x+w;xx++)pixels[yy*466+xx]=c;
  }
  void fillRoundRect(int x,int y,int w,int h,int,uint16_t c){fillRect(x,y,w,h,c);}
  void drawRoundRect(int x,int y,int w,int h,int,uint16_t c){fillRect(x,y,w,h,c);}
} canvas;
Canvas* gfx=&canvas;
bool needFlush=true;
uint32_t controlFeedbackUntil=0;
uint32_t millis(){return 100;}
struct {bool locked=false;} deviceControls;
void printCentered(const char*,int,int,int,uint16_t){}
'''
cases = r'''
int main() {
  // An unlocked redraw must preserve the entire navigation frame, including its ring.
  for(unsigned i=0;i<canvas.pixels.size();i++)canvas.pixels[i]=uint16_t(i%65534+1);
  const auto navigation=canvas.pixels;
  controlDrawLock();
  assert(canvas.pixels==navigation && "unlocked overlay damages the navigation frame");

  deviceControls.locked=true;
  controlDrawLock();
  assert(canvas.pixels[28*466+189]==C_YELLOW);

  // Unlock already requests a full page redraw; leave that restored frame intact.
  deviceControls.locked=false;
  canvas.pixels=navigation;needFlush=true;
  controlDrawLock();
  assert(canvas.pixels==navigation);

  // Transient unlock feedback must not erase the separate badge/ring region.
  controlFeedbackUntil=1100;needFlush=false;
  controlDrawLock();
  for(int y=14;y<=35;y++)for(int x=180;x<=198;x++)
    assert(canvas.pixels[y*466+x]==navigation[y*466+x]);
  assert(needFlush);

  controlFeedbackUntil=0;needFlush=false;
  const auto idle=canvas.pixels;
  controlDrawLock();assert(canvas.pixels==idle && !needFlush);
  puts("PASS touch lock: unlocked frames preserved, locked badge visible, restored page and feedback preserved");
}
'''
with tempfile.TemporaryDirectory() as directory:
    path = Path(directory)
    header = '#include "' + str(base / "TouchLockBadge.h") + '"\n'
    (path / "main.cpp").write_text(stub + header + function + cases)
    subprocess.run(["clang++", "-std=c++17", "-fsanitize=address,undefined",
                    str(path / "main.cpp"), "-o", str(path / "test")], check=True)
    subprocess.run([str(path / "test")], check=True)
