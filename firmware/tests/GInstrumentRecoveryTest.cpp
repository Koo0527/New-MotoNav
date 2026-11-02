#include <cassert>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <initializer_list>
#include "../boards/175/MotoNav/GInstrumentMath.h"
using namespace GInstrument;

void recoverTilt() {
  Estimator e;e.mount={{1,0,0},{},1,0,true};
  for(int i=0;i<168;i++)e.sample({0,0,1},{4.1f,2.1f,0.25f},1.f/56,Motion::Stopped);
  assert(e.available);
  // A small gyro integration error after a real 30-degree tilt must not latch gravity sideways.
  for(int i=1;i<=28;i++) {
    float a=i*(30.0f/28)*0.01745329252f;
    e.sample({sinf(a),0,cosf(a)},{4.1f,-55+2.1f,0.25f},1.f/56,Motion::Stopped);
  }
  for(int i=0;i<56*4;i++)e.sample({0.5f,0,0.8660254f},{4.5f,2.1f,0.25f},1.f/56,Motion::Stopped);
  assert(e.available&&fabsf(e.lateral)<0.01f&&fabsf(e.longitudinal)<0.01f);
  assert(fabsf(e.runtimeBias.x-4.5f)<0.02f);
  for(int i=1;i<=28;i++) {
    float a=(30-i*(30.0f/28))*0.01745329252f;
    e.sample({sinf(a),0,cosf(a)},{4.5f,55+2.1f,0.25f},1.f/56,Motion::Stopped);
  }
  for(int i=0;i<56*4;i++)e.sample({0,0,1},{4.5f,2.1f,0.25f},1.f/56,Motion::Stopped);
  assert(e.available&&fabsf(e.lateral)<0.01f&&fabsf(e.longitudinal)<0.01f);
  // Quiet gyro alone cannot zero sustained acceleration, including small forces near 1g total.
  for(float force:{0.1f,0.3f}) {
    for(int i=0;i<56*20;i++)e.sample({force,0,1},{4.5f,2.1f,0.25f},1.f/56,Motion::Unknown);
    assert(e.available&&fabsf(e.longitudinal-force)<0.01f);
  }
}

void physicalAxes() {
  Estimator e;assert(makeMount({0,0,1},{},1,0,e.mount));
  for(int i=0;i<168;i++)e.sample({0,0,1},{},1.f/56,Motion::Stopped);
  // Measured board axes: USB rear=-X, face=+Z. Forward=+X and right=-Y.
  e.sample({0.25f,-0.4f,1},{},1.f/56,Motion::Stopped);
  assert(e.available&&fabsf(e.longitudinal-0.25f)<0.001f&&fabsf(e.lateral-0.4f)<0.001f);
  e.sample({-0.3f,0.2f,1},{},1.f/56,Motion::Stopped);
  assert(fabsf(e.longitudinal+0.3f)<0.001f&&fabsf(e.lateral+0.2f)<0.001f);
  assert(makeMount({0,0,1},{},1,90,e.mount));
  e.sample({-0.2f,-0.3f,1},{},1.f/56,Motion::Stopped);
  assert(fabsf(e.longitudinal-0.3f)<0.001f&&fabsf(e.lateral-0.2f)<0.001f);
  // Screen-back reference is physically -Z when mounted upright, not the screen face.
  Estimator upright;assert(makeMount({1,0,0},{},0,0,upright.mount));
  for(int i=0;i<168;i++)upright.sample({1,0,0},{},1.f/56,Motion::Stopped);
  upright.sample({1,-0.2f,-0.3f},{},1.f/56,Motion::Stopped);
  assert(upright.available&&fabsf(upright.longitudinal-0.3f)<0.001f&&fabsf(upright.lateral-0.2f)<0.001f);
  // A vertical dashboard is valid too: the screen back resolves the vertical USB reference.
  assert(makeMount({1,0,0},{},1,0,upright.mount));
  upright.sample({1,-0.2f,-0.3f},{},1.f/56,Motion::Stopped);
  assert(upright.available&&fabsf(upright.longitudinal-0.3f)<0.001f&&fabsf(upright.lateral-0.2f)<0.001f);
}

void movingTilt() {
  Estimator e;e.mount={{1,0,0},{},1,0,true};
  for(int i=0;i<168;i++)e.sample({0,0,1},{},1.f/56,Motion::Stopped);
  for(int i=1;i<=28;i++) {
    float a=i*(20.0f/28)*0.01745329252f;
    e.sample({sinf(a),0,cosf(a)},{0,-40,0},1.0f/56,Motion::Unknown);
  }
  // Real force after a tilt must survive while the vehicle is moving or speed is unknown.
  for(int i=0;i<56*20;i++)e.sample({0.5299587f,0,0.8712886f},{},1.0f/56,Motion::Unknown);
  assert(e.available&&fabsf(e.longitudinal-0.2f)<0.005f);
}

void slowTilt() {
  Estimator e;e.mount={{1,0,0},{},1,0,true};
  for(int i=0;i<168;i++)e.sample({0,0,1},{},1.f/56,Motion::Stopped);
  for(int i=1;i<=56*15;i++) {
    float a=(2.0f*i/56)*0.01745329252f;
    e.sample({sinf(a),0,cosf(a)},{0,-1.8f,0},1.f/56,Motion::Stopped);
  }
  for(int i=0;i<56*4;i++)e.sample({0.5f,0,0.8660254f},{},1.f/56,Motion::Stopped);
  assert(e.available&&fabsf(e.longitudinal)<0.01f&&fabsf(e.lateral)<0.01f);
}

void verticalRecovery() {
  Estimator e;assert(makeMount({0,0,1},{},1,0,e.mount));
  for(int i=0;i<168;i++)e.sample({0,0,1},{},1.f/56,Motion::Stopped);
  for(int i=1;i<=56;i++) {
    float a=(90.0f*i/56)*0.01745329252f;
    e.sample({sinf(a),0,cosf(a)},{0,-90,0},1.f/56,Motion::Stopped);
  }
  for(int i=0;i<56*4;i++)e.sample({1,0,0},{},1.f/56,Motion::Stopped);
  assert(e.available&&fabsf(e.longitudinal)<0.01f&&fabsf(e.lateral)<0.01f);
}

int main(int argc,char **argv) {
  if(argc==1||!strcmp(argv[1],"recovery"))recoverTilt();
  if(argc==1||!strcmp(argv[1],"axes"))physicalAxes();
  if(argc==1)movingTilt();
  if(argc==1||!strcmp(argv[1],"slow"))slowTilt();
  if(argc==1||!strcmp(argv[1],"vertical"))verticalRecovery();
  puts("PASS: static tilt recovery, gyro bias, sustained acceleration and USB-rear physical axes");
}
