#pragma once
#include <cstring>
#include "GInstrumentMath.h"
#include "IdlePowerOff.h"
namespace GInstrument {
struct MotionEvidence {
  Motion state=Motion::Unknown;uint32_t at=0,epoch=0;
  void maintain(bool authenticated,uint32_t connectionEpoch) {
    if(!authenticated||epoch!=connectionEpoch)state=Motion::Unknown;
    epoch=connectionEpoch;
  }
  bool receive(const char *command,uint32_t now,bool authenticated,uint32_t connectionEpoch) {
    maintain(authenticated,connectionEpoch);
    if(!authenticated||std::strlen(command)!=5||std::strncmp(command,"#GM,",4)||command[4]<'0'||command[4]>'2')return false;
    state=Motion(command[4]-'0');at=now;return true;
  }
  bool receiveQueued(const char *command,uint32_t receivedAt,bool receivedAuthenticated,uint32_t receivedEpoch,
                     uint32_t now,bool authenticated,uint32_t connectionEpoch) {
    maintain(authenticated,connectionEpoch);
    if(!receivedAuthenticated||receivedEpoch!=connectionEpoch||uint32_t(now-receivedAt)>=3000)return false;
    return receive(command,receivedAt,authenticated,connectionEpoch);
  }
  Motion current(uint32_t now,bool authenticated,uint32_t connectionEpoch) const {
    return authenticated&&epoch==connectionEpoch&&uint32_t(now-at)<3000?state:Motion::Unknown;
  }
};
struct FifoStatus {
  // Read the actual FIFO word count; avoid interpreting the ambiguous bit4 name.
  static int count(uint8_t low,uint8_t status) {
    if(status&0xa0)return -2;
    const unsigned bytes=2*(((status&3)<<8)|low);
    if(bytes>1536 || bytes%6)return -1;
    // FIFO can expose accel XYZ before the matching gyro XYZ finishes writing.
    return bytes%12 ? 0 : int(bytes/12);
  }
};
struct BatchClock {
  uint32_t at=0;bool primed=false;
  void reset(){primed=false;}
  float interval(uint32_t now,unsigned count) {
    if(!count)return 0;
    uint32_t elapsed=uint32_t(now-at);
    float dt=primed?elapsed/(1000.0f*count):1.0f/56;
    bool gap=primed&&elapsed>500;at=now;primed=true;
    return gap||dt<=0||dt>0.1f?0:dt;
  }
};
struct CalibrationWindow {
  Estimator pose;uint32_t began=0,quietSince=0,lastAt=0;bool active=false,sampled=false;
  bool continuous=false;
  void begin(uint32_t now){pose.reset();began=now;active=true;sampled=false;}
  // Noise restarts the quiet window, while the overall attempt remains bounded.
  int sample(Vec a,Vec w,uint32_t now) {
    if(!active)return 0;
    if(uint32_t(now-began)>=15000){if(!continuous){active=false;return -1;}begin(now);}
    if(sampled&&uint32_t(now-lastAt)>250)pose.reset();
    sampled=true;lastAt=now;
    bool stable=pose.stationary(a,w);
    if(pose.stable==1)quietSince=now;
    if(stable&&uint32_t(now-quietSince)>=3000){active=false;return 1;}
    return 0;
  }
};
struct AutoMount {
  bool page=false,stream=false,pending=false,waitForStop=false;
  bool poll(bool visible,bool streaming,Motion motion){
    if((visible&&!page)||(streaming&&!stream)){pending=true;waitForStop=false;}
    page=visible;stream=streaming;
    if(!visible&&!streaming){pending=false;waitForStop=false;}
    if(pending&&motion==Motion::Moving)waitForStop=true;
    return pending&&(motion==Motion::Stopped||(motion==Motion::Unknown&&!waitForStop));
  }
  void finish(){pending=false;}
};
struct Stream {
  uint32_t epoch=0;
  uint32_t token=0,renewedAt=0;uint16_t seq=0;bool active=false,pending=false;
  uint8_t bytes[17]={};
  static bool parse(const char *s,uint32_t &token,unsigned &rate) {
    const size_t n=std::strlen(s);
    if((n!=14&&n!=15)||std::strncmp(s,"#GS,",4)||s[12]!=',')return false;
    token=0;
    for(int i=4;i<12;i++) {
      char c=s[i];unsigned digit;
      if(c>='0'&&c<='9')digit=c-'0';else if(c>='a'&&c<='f')digit=c-'a'+10;
      else if(c>='A'&&c<='F')digit=c-'A'+10;else return false;
      token=(token<<4)|digit;
    }
    if(!std::strcmp(s+13,"20"))rate=20;else if(!std::strcmp(s+13,"0"))rate=0;else return false;
    return true;
  }
  bool command(uint32_t requested,unsigned rate,uint32_t now,bool authenticated) {
    if(!authenticated)return false;
    if(rate==20) {
      if(!active||token!=requested){seq=0;pending=false;}
      token=requested;renewedAt=now;active=true;return true;
    }
    if(rate==0&&active&&token==requested){active=false;pending=false;return true;}
    return false;
  }
  bool holdsPower(uint32_t now,bool authenticated) const {
    return active&&authenticated&&uint32_t(now-renewedAt)<15000;
  }
  bool tick(uint32_t now,bool authenticated) {
    if(active&&!holdsPower(now,authenticated)){active=false;pending=false;return true;}
    return false;
  }
  void maintain(uint32_t now,bool authenticated,uint32_t connectionEpoch,IdlePowerOffTimer &idle) {
    bool ended=false;
    if(epoch!=connectionEpoch){epoch=connectionEpoch;ended=active;active=false;pending=false;}
    ended=tick(now,authenticated)||ended;
    if(ended)idlePowerOffReset(&idle,now);
  }
  static void le(uint8_t *out,uint32_t value,unsigned n){for(unsigned i=0;i<n;i++)out[i]=uint8_t(value>>(8*i));}
  void frame(uint8_t *out,uint8_t flags,uint32_t now,int16_t lat,int16_t longitudinal) {
    out[0]=0xa7;out[1]=1;out[2]=flags;le(out+3,seq++,2);le(out+5,now,4);le(out+9,token,4);
    le(out+13,uint16_t(lat),2);le(out+15,uint16_t(longitudinal),2);
  }
};
struct Output {
  struct Point {uint32_t at=0;float lateral=0,longitudinal=0;bool valid=false;};
  Point trail[100];unsigned head=0,count=0;uint32_t at=0;bool sampled=false,valid=false;
  float lateral=0,longitudinal=0,accel=0,brake=0,left=0,right=0;
  void clear(){head=count=0;accel=brake=left=right=0;}
  bool update(uint32_t now,bool available,float x,float y) {
    if(sampled&&uint32_t(now-at)<50)return false;
    sampled=true;at=now;valid=available;
    if(valid) {
      lateral=x;longitudinal=y;
      accel=fmaxf(accel,y);brake=fmaxf(brake,-y);left=fmaxf(left,-x);right=fmaxf(right,x);
    }
    trail[head]={now,x,y,valid};head=(head+1)%100;if(count<100)++count;
    return true;
  }
  static int16_t milli(float x){return int16_t(lroundf(fmaxf(-32.767f,fminf(32.767f,x))*1000));}
};
}
