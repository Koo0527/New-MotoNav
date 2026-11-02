#pragma once
#include <cmath>
#include <cstdint>
namespace BootTone {
constexpr int rate=16000,frames=5600;
inline int16_t sample(int i){
  if(i<0||i>=frames)return 0;
  float t=i/(float)rate;bool second=t>=0.175f;float local=t-(second?0.175f:0);
  if(local>=0.155f)return 0;
  float envelope=fminf(1,local/0.008f)*fminf(1,(0.155f-local)/0.025f);
  return (int16_t)(7000*envelope*sinf(6.28318530718f*(second?880:659.255f)*local));
}
}
