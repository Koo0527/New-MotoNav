#pragma once
#include <stdint.h>

// Only the key IRQ bits are acknowledged; PMIC power-off timings stay untouched.
struct AxpPowerKey {
  bool ready=false;
  template<class Read,class Write> bool begin(Read read,Write write) {
    ready=false;
    if(read(0x03)!=0x4a)return false;
    const int enabled=read(0x41),status=read(0x49);
    if(enabled<0||status<0)return false;
    if((status&0x0c)&&!write(0x49,status&0x0c))return false;
    if(!write(0x41,enabled|0x0c))return false;
    ready=true;return true;
  }
  template<class Read,class Write> bool poll(Read read,Write write) {
    if(!ready)return false;
    const int status=read(0x49);
    if(status<0||!(status&0x0c))return false;
    if(!write(0x49,status&0x0c))return false;
    return (status&0x0c)==0x08;
  }
};
