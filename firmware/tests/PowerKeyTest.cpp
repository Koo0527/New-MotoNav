#include <cassert>
#include <cstdint>
#include "../boards/175/MotoNav/AxpPowerKey.h"
#include "../boards/175/MotoNav/DeviceControls.h"
int main() {
  int regs[256]={};regs[3]=0x4a;regs[0x41]=0x80;regs[0x49]=0x48;
  int lastReg=-1,lastValue=-1;bool failRead=false,failWrite=false;
  auto read=[&](uint8_t r){return failRead?-1:regs[r];};
  auto write=[&](uint8_t r,uint8_t value){
    assert(r==0x41||r==0x49); // Never change shutdown or long-press timing registers.
    if(failWrite)return false;
    lastReg=r;lastValue=value;
    if(r==0x49)regs[r]&=~value;else regs[r]=value;
    return true;
  };
  AxpPowerKey key;
  assert(key.begin(read,write));assert(regs[0x41]==0x8c);
  assert(regs[0x49]==0x40); // Boot key discarded; unrelated IRQ left intact.
  regs[0x49]|=8;assert(key.poll(read,write));assert(!key.poll(read,write));
  assert(lastReg==0x49&&lastValue==8);
  regs[0x49]|=4;assert(!key.poll(read,write));assert(regs[0x49]==0x40);
  regs[0x49]|=12;assert(!key.poll(read,write)); // Long press wins.
  regs[0x49]|=8;failWrite=true;assert(!key.poll(read,write));
  failWrite=false;assert(key.poll(read,write));
  failRead=true;assert(!key.poll(read,write));failRead=false;
  regs[3]=0;assert(!key.begin(read,write));assert(!key.poll(read,write));
  DeviceControls c;
  assert(!c.activityWake(true,false));
  c.powerShortPress();assert(c.asleep&&c.manualSleep);
  assert(!c.activityWake(true,false));assert(!c.activityWake(true,false));
  c.powerShortPress();assert(!c.asleep&&!c.manualSleep);
  c.locked=true;c.powerShortPress();assert(c.asleep&&c.locked);
  assert(c.activityWake(true,true)); // A new call wakes.
  c.wake();assert(!c.manualSleep&&!c.asleep&&c.locked);
  c.activityWake(false,false);c.powerShortPress();
  assert(c.activityWake(true,false)); // New navigation wakes an idle manual sleep.
  c.wake();c.powerShortPress();c.activityWake(false,false);
  assert(!c.activityWake(false,false));
  c.wake();c.asleep=true;assert(c.activityWake(true,false));
  assert(!c.pending&&c.revision==0); // Power key never changes tunnel revision.
}
