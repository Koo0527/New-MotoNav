#include <cassert>
#include <cmath>
#include <cstdio>
#include <initializer_list>
#include <limits>
#include "../boards/175/MotoNav/GInstrumentMath.h"
using namespace GInstrument;

int main() {
  Estimator e;assert(makeMount({0,0,1},{},1,0,e.mount));
  for(int i=0;i<168;i++)e.sample({0,0,1},{},1.f/56,Motion::Stopped);
  // Gravity can be wrong without a preceding measured tilt (e.g. accumulated bias).
  e.up=unit({0.02f,0,1});
  for(int i=0;i<56*5;i++)e.sample({0,0,1},{},1.f/56,Motion::Stopped);
  assert(e.available&&fabsf(e.longitudinal)<0.01f);
  // Unknown motion must not slowly fold even a small real force into gravity.
  for(int i=0;i<56*60;i++)e.sample({0.005f,0,1},{},1.f/56,Motion::Unknown);
  assert(e.available&&fabsf(e.longitudinal-0.005f)<0.0005f);
  // Lost attitude cannot be initialized from a constant force during motion or an unknown stop.
  for(Motion motion:{Motion::Moving,Motion::Unknown}) {
    e.reset();
    for(int i=0;i<56*5;i++)e.sample({0.2f,0,1},{},1.f/56,motion);
    assert(!e.initialized&&!e.available);
  }
  // Replay the reported failure: 5 minutes of residual gyro bias, followed by a trusted stop.
  for(int i=0;i<168;i++)e.sample({0,0,1},{},1.f/56,Motion::Stopped);
  for(int i=0;i<56*300;i++)e.sample({0,0,1},{0.08f,0.08f,0.08f},1.f/56,Motion::Unknown);
  assert(fabsf(e.lateral)>0.1f||fabsf(e.longitudinal)>0.1f);
  for(int i=0;i<56*5;i++)e.sample({0,0,1},{0.08f,0.08f,0.08f},1.f/56,Motion::Stopped);
  assert(e.available&&fabsf(e.lateral)<0.01f&&fabsf(e.longitudinal)<0.01f);
  for(Motion motion:{Motion::Moving,Motion::Unknown})for(float force:{0.05f,0.1f,0.2f,0.3f}) {
    Estimator t;assert(makeMount({0,0,1},{},1,0,t.mount));
    for(int i=0;i<168;i++)t.sample({0,0,1},{},1.f/56,Motion::Stopped);
    for(int i=1;i<=56;i++) {
      float angle=(20.f*i/56)*0.01745329252f;
      t.sample({sinf(angle),0,cosf(angle)},{0,-20,0},1.f/56,motion);
    }
    const Vec up{ sinf(20.f*0.01745329252f),0,cosf(20.f*0.01745329252f) };
    const Vec forward=unit(horizontal({1,0,0},up));
    const Vec a=add(up,mul(forward,force));
    for(int i=0;i<56*60;i++)t.sample(a,{},1.f/56,motion);
    assert(t.available&&fabsf(t.longitudinal-force)<fmaxf(0.005f,force*0.05f)&&fabsf(t.lateral)<0.01f);
  }
  // Installation angle and yaw must not exchange the longitudinal and lateral channels.
  for(float pitch:{0.f,45.f,85.f,90.f})for(int yaw:{0,35,90}) {
    const float radians=pitch*0.01745329252f;
    const Vec up{sinf(radians),0,cosf(radians)};
    Estimator t;assert(makeMount(up,{},1,yaw,t.mount));
    for(int i=0;i<168;i++)t.sample(up,{},1.f/56,Motion::Stopped);
    Vec forward=t.mount.forward,right=unit(cross(forward,up));
    for(int axis=0;axis<2;axis++)for(float force:{-0.3f,0.3f}) {
      t.sample(add(up,mul(axis?right:forward,force)),{},1.f/56,Motion::Unknown);
      assert(t.available);
      assert(fabsf(t.longitudinal-(axis?0:force))<0.01f&&fabsf(t.lateral-(axis?force:0))<0.01f);
    }
  }
  e.sample({0,0,1},{},std::numeric_limits<float>::quiet_NaN(),Motion::Stopped);
  assert(!e.initialized&&!e.available);
  for(int i=0;i<168;i++)e.sample({0,0,1},{},0.001f,Motion::Stopped);
  assert(!e.initialized);
  puts("PASS: trusted stop restores gravity without tilt; unknown motion preserves force");
}
