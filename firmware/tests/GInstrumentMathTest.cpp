#ifdef NDEBUG
#undef NDEBUG
#endif
#include <cassert>
#include <cstdio>
#include <limits>
#include <initializer_list>
#include "../boards/175/MotoNav/InstrumentCommands.h"
#include "../boards/175/MotoNav/GInstrumentMath.h"
#include "../boards/175/MotoNav/BootTone.h"
using namespace GInstrument;
int main(){
  int a=-1,b=-1;
  assert(InstrumentCommands::pair("BS,1,20","BS,",a,b)&&a==1&&b==20);
  for(const char *bad:{"BS,4294967297,20","BS,1,4294967316","BS,-1,20","BS,+1,20","BS, 1,20","BS,1,20x","BS,1,","BS,,20","BS,00000,20"})
    assert(!InstrumentCommands::pair(bad,"BS,",a,b));
  Estimator hardware;assert(makeMount({-0.079f,-0.088f,0.998f},{},1,0,hardware.mount));
  for(int i=0;i<168;i++)hardware.sample({-0.079f+(i%3-1)*0.001f,-0.088f,0.998f},{4.1f+(i%5-2)*0.04f,2.1f+(i%3-1)*0.04f,0.25f+(i%5-2)*0.06f},1.f/56,Motion::Stopped);
  assert(hardware.available&&fabsf(hardware.runtimeBias.x-4.1f)<0.02f&&fabsf(hardware.lateral)<0.01f&&fabsf(hardware.longitudinal)<0.01f);
  hardware.reset();for(int i=0;i<336;i++)hardware.sample({0,0,1},{4.1f+(i%2?2:-2),2.1f,0.25f},1.f/56,Motion::Stopped);assert(!hardware.initialized);
  hardware.reset();for(int i=0;i<336;i++)hardware.sample({0.3f,0,1},{4.1f,2.1f,0.25f},1.f/56,Motion::Stopped);assert(!hardware.initialized);
  Estimator e;assert(makeMount({0,0,1},{},1,0,e.mount));
  for(int i=0;i<168;i++)e.sample({0,0,1},{0.2f,0,0},1.f/56,Motion::Stopped);
  assert(e.available&&fabsf(e.lateral)<0.001f&&fabsf(e.longitudinal)<0.001f);
  // Sustained horizontal acceleration is not folded into the gravity estimate.
  for(int i=0;i<56*20;i++)e.sample({0.3f,0.2f,1},{0.2f,0,0},1.f/56,Motion::Unknown);
  assert(e.available&&fabsf(e.lateral+0.2f)<0.005f&&fabsf(e.longitudinal-0.3f)<0.005f);
  // Roll the bike 30 degrees with the matching gravity trace; static lean is zero.
  for(int i=1;i<=56;i++){
    float angle=i*(30.0f/56)*0.01745329252f;
    e.sample({0,sinf(angle),cosf(angle)},{30.2f,0,0},1.f/56,Motion::Stopped);
  }
  for(int i=0;i<56*5;i++)e.sample({0,0.5f,0.8660254f},{0.2f,0,0},1.f/56,Motion::Stopped);
  assert(e.available&&fabsf(e.lateral)<0.01f&&fabsf(e.longitudinal)<0.01f);
  // A new startup on the side stand initializes from current gravity, not saved up.
  e.reset();for(int i=0;i<168;i++)e.sample({0,0.5f,0.8660254f},{0.4f,0,0},1.f/56,Motion::Stopped);
  assert(e.available&&fabsf(e.longitudinal)<0.005f&&fabsf(e.runtimeBias.x-0.4f)<0.001f);
  auto savedForward=e.mount.forward;e.reset();assert(e.mount.valid&&e.mount.forward.x==savedForward.x&&!e.initialized);
  for(int i=0;i<168;i++)e.sample({0,0,1},{0.2f,0,0},1.f/56,Motion::Stopped);assert(e.available);
  e.sample({4,0,1},{},1.f/56,Motion::Stopped);assert(!e.available&&!e.initialized);
  e.sample({std::numeric_limits<float>::quiet_NaN(),0,1},{},1.f/56,Motion::Stopped);assert(!e.available);
  e.sample({0,0,1},{512,0,0},1.f/56,Motion::Stopped);assert(!e.available);
  for(int i=0;i<168;i++)e.sample({0.3f,0,1},{5,0,0},1.f/56,Motion::Stopped);assert(!e.initialized);
  Mount m;assert(!makeMount({0,0,1},{},0,0,m));
  assert(makeMount({0,0,1},{},1,90,m));assert(fabsf(m.forward.y+1)<0.001f);
  assert(!makeMount({0,0,1},{},3,0,m));assert(!makeMount({0,0,1},{},1,360,m));
  int peak=0,nonzero=0;for(int i=0;i<BootTone::frames;i++){int n=abs(BootTone::sample(i));if(n>peak)peak=n;if(n)nonzero++;}
  assert(peak<=7000&&peak>6000&&nonzero>4000);assert(BootTone::sample(0)==0&&BootTone::sample(5599)==0);
  assert(BootTone::sample(2600)==0&&BootTone::sample(2750)==0);
  puts("PASS: stationary, sustained acceleration, gyro lean, side-stand startup, bias, saturation, degenerate mounts, boot envelope");
}
