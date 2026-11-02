#pragma once
#include <stdint.h>
#include <stdio.h>
#include <string.h>

// Platform-independent state used by the hardware loop and native regression test.
struct DeviceControls {
  uint16_t revision=0, usbSeconds=600, batterySeconds=120;
  uint8_t normal=200, dim=70;
  bool tunnel=false, locked=false, asleep=false, pending=false, baseNight=false;
  bool themeSession=false, dirty=true;
  bool manualSleep=false, wasNavigating=false, wasUrgent=false;
  void wake() {asleep=false;manualSleep=false;dirty=true;}
  void powerShortPress() {
    if(asleep)wake();
    else {asleep=true;manualSleep=true;dirty=true;}
  }
  bool activityWake(bool navigating,bool urgent) {
    const bool needed=asleep && ((navigating&&(!manualSleep||!wasNavigating)) ||
                                (urgent&&(!manualSleep||!wasUrgent)));
    wasNavigating=navigating;wasUrgent=urgent;
    return needed;
  }
  bool touchBlocked=false;uint32_t touchSeenAt=0;
  void consumeTouch(uint32_t now){touchBlocked=true;touchSeenAt=now;}
  // 0=normal input, 1=consumed, 2=wake. Tolerate the controller's short dropouts.
  int touchGate(bool down,uint32_t now) {
    if(locked || touchBlocked) {
      if(down)consumeTouch(now);
      else if(uint32_t(now-touchSeenAt)>80)touchBlocked=false;
      return 1;
    }
    if(asleep) {
      if(down){asleep=false;dirty=true;consumeTouch(now);return 2;}
      return 1;
    }
    return 0;
  }
  bool rawBoot=false, stableBoot=false, bootConsumed=false, startupHeld=false;
  uint32_t rawAt=0, pressedAt=0;
  void bootBegin(bool held,uint32_t now) {
    rawBoot=stableBoot=held; startupHeld=held; bootConsumed=held; rawAt=pressedAt=now;
  }
  void physicalChange() { ++revision; pending=true; dirty=true; }
  // 1=tunnel, 2=lock, 3=wake. A wake consumes the entire press through release.
  int bootPoll(bool held,uint32_t now) {
    if(held!=rawBoot) { rawBoot=held;rawAt=now; }
    if(rawBoot!=stableBoot && uint32_t(now-rawAt)>=30) {
      stableBoot=rawBoot;
      if(stableBoot) {
        pressedAt=now;bootConsumed=false;
        if(asleep) { asleep=false;bootConsumed=true;dirty=true;return 3; }
      } else {
        if(startupHeld) {startupHeld=false;bootConsumed=false;return 0;}
        if(!bootConsumed) { tunnel=!tunnel;physicalChange();return 1; }
        bootConsumed=false;
      }
    }
    if(rawBoot && stableBoot && !startupHeld && !bootConsumed && uint32_t(now-pressedAt)>=1200) {
      bootConsumed=true;locked=!locked;physicalChange();return 2;
    }
    return 0;
  }
  static bool decimal(const char *&p,unsigned &value,unsigned maximum) {
    if(*p<'0'||*p>'9')return false;
    value=0;
    do { unsigned digit=*p++-'0';if(digit>maximum || value>(maximum-digit)/10)return false;value=value*10+digit; }
    while(*p>='0'&&*p<='9');
    return true;
  }
  static bool parsePower(const char *m,unsigned &usb,unsigned &battery) {
    if(strlen(m)>20||strncmp(m,"#PS,",4))return false;
    const char *p=m+4;
    return decimal(p,usb,1800)&&*p++==','&&decimal(p,battery,240)&&!*p&&validUsb(usb)&&validBattery(battery);
  }
  bool receiveTheme(const char *m) {
    const size_t length=strlen(m);
    if(length<16 || length>20 || strncmp(m,"#TM,",4)!=0)return false;
    unsigned rev=0,n=0,d=0,b=0,t=0;
    for(int i=4;i<8;i++) {
      const char ch=m[i];unsigned digit;
      if(ch>='0'&&ch<='9')digit=ch-'0';
      else if(ch>='a'&&ch<='f')digit=ch-'a'+10;
      else if(ch>='A'&&ch<='F')digit=ch-'A'+10;
      else return false;
      rev=rev*16+digit;
    }
    const char *p=m+8;
    if(*p++!=','||!decimal(p,n,255)||n<5||*p++!=','||!decimal(p,d,255)||d<5||
       *p++!=','||!decimal(p,b,1)||*p++!=','||!decimal(p,t,1)||*p)return false;
    themeSession=true;normal=n;dim=d;baseNight=b;
    if(rev==revision) {
      if(!pending)tunnel=t;
      else if(tunnel==bool(t))pending=false;
    }
    dirty=true;return true;
  }
  bool night() const {return baseNight||tunnel;}
  uint8_t targetBrightness() const {return tunnel && dim<normal ? dim : normal;}
  static int fadeStep(int current,int target) {
    return current<target ? (target-current>32 ? current+32 : target) : (current-target>32 ? current-32 : target);
  }
  static bool validUsb(unsigned s) {return s==0||s==60||s==120||s==300||s==600||s==1800;}
  static bool validBattery(unsigned s) {return s==30||s==60||s==120||s==180||s==240;}
  bool setPower(unsigned usb,unsigned battery) {
    if(!validUsb(usb)||!validBattery(battery))return false;
    usbSeconds=usb;batterySeconds=battery;return true;
  }
  bool sleepDue(uint32_t now,uint32_t since,bool battery,bool protectedNow) const {
    const unsigned seconds=battery?batterySeconds:usbSeconds;
    return !protectedNow && seconds && uint32_t(now-since)>=uint32_t(seconds)*1000;
  }
};
