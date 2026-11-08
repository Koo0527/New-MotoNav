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
enum class CalibrationSource : uint8_t { ScreenPage, PhonePage, Manual, TrustedStop };
// Trusted stops must be Stopped for the whole window; explicit page/manual
// requests tolerate Unknown (the user says the vehicle is parked) but never Moving.
struct CalibrationPolicy {
  static bool mayRun(CalibrationSource source,Motion motion) {
    return source==CalibrationSource::TrustedStop ? motion==Motion::Stopped : motion!=Motion::Moving;
  }
};
struct CalibrationGate {
  static bool mayStart(CalibrationSource source,Motion motion,bool sessionValid) {
    return sessionValid&&CalibrationPolicy::mayRun(source,motion);
  }
  static bool maySave(CalibrationSource source,Motion motion,bool sessionValid) {
    return mayStart(source,motion,sessionValid);
  }
};
// A manual #GC request is bound to the authenticated connection that queued it.
struct ManualCalibrationSession {
  bool bound=false;uint32_t epoch=0;
  bool receive(bool receivedAuthenticated,uint32_t receivedEpoch,bool currentAuthenticated,uint32_t currentEpoch) {
    if(!receivedAuthenticated||!currentAuthenticated||receivedEpoch!=currentEpoch){clear();return false;}
    bound=true;epoch=receivedEpoch;return true;
  }
  bool valid(bool authenticated,uint32_t currentEpoch) const {
    return bound&&authenticated&&epoch==currentEpoch;
  }
  void clear(){bound=false;epoch=0;}
};
// A phone page entry is an expiring observation bound to the authenticated
// connection and the current #GS stream token. It is never a cached setting.
struct PhoneEntry {
  bool requested=false;uint32_t token=0,epoch=0,at=0,entries=0;
  void clear(){requested=false;token=0;epoch=0;at=0;}
  static bool parse(const char *s,uint32_t &token,bool &enter) {
    if(std::strlen(s)!=14||std::strncmp(s,"#GE,",4)||s[12]!=',')return false;
    token=0;
    for(int i=4;i<12;i++) {
      char c=s[i];unsigned digit;
      if(c>='0'&&c<='9')digit=c-'0';else if(c>='a'&&c<='f')digit=c-'a'+10;
      else if(c>='A'&&c<='F')digit=c-'A'+10;else return false;
      token=(token<<4)|digit;
    }
    if(s[13]=='1')enter=true;else if(s[13]=='0')enter=false;else return false;
    return true;
  }
  bool receive(const char *s,uint32_t now,bool authenticated,uint32_t connectionEpoch,
               bool streamActive,uint32_t streamToken) {
    uint32_t t;bool enter;
    if(!authenticated||!streamActive||!parse(s,t,enter)||t!=streamToken)return false;
    if(enter) {
      if(requested&&token==t&&epoch==connectionEpoch)return true; // repeated 1 is not a new event
      requested=true;token=t;epoch=connectionEpoch;at=now;++entries;return true;
    }
    if(requested&&token==t&&epoch==connectionEpoch)clear();
    return true;
  }
  bool receiveQueued(const char *s,uint32_t receivedAt,bool receivedAuthenticated,uint32_t receivedEpoch,
                     uint32_t now,bool authenticated,uint32_t connectionEpoch,bool streamActive,uint32_t streamToken) {
    maintain(authenticated,connectionEpoch,streamActive,streamToken);
    if(!receivedAuthenticated||receivedEpoch!=connectionEpoch||uint32_t(now-receivedAt)>=3000)return false;
    return receive(s,receivedAt,authenticated,connectionEpoch,streamActive,streamToken);
  }
  void maintain(bool authenticated,uint32_t connectionEpoch,bool streamActive,uint32_t streamToken) {
    if(!requested)return;
    if(!authenticated||epoch!=connectionEpoch||!streamActive||token!=streamToken)clear();
  }
  bool current(bool authenticated,uint32_t connectionEpoch,bool streamActive,uint32_t streamToken) const {
    return requested&&authenticated&&epoch==connectionEpoch&&streamActive&&token==streamToken;
  }
  uint32_t generation() const { return entries; }
};
struct FifoStatus {  // Read the actual FIFO word count; avoid interpreting the ambiguous bit4 name.
  enum class Kind:uint8_t{Empty,Half,Complete,Overflow};
  static unsigned bytes(uint8_t low,uint8_t status) {
    return 2*(((status&3)<<8)|low);
  }
  static Kind kind(uint8_t low,uint8_t status) {
    if(status&0xa0)return Kind::Overflow;       // full/watermark/overflow flags are real loss
    const unsigned b=bytes(low,status);
    if(b>1536)return Kind::Overflow;
    if(!b)return Kind::Empty;
    if(b%12)return Kind::Half;                   // accel/gyro or partial XYZ still being written
    if(b/12>32)return Kind::Overflow;            // consumer arrays are 32 pairs
    return Kind::Complete;
  }
  static int count(uint8_t low,uint8_t status) {
    const Kind k=kind(low,status);
    if(k==Kind::Overflow)return -2;
    if(k!=Kind::Complete)return 0;
    return int(bytes(low,status)/12);
  }
};
// A non-integral XYZ count is allowed to settle for at most two polls and
// 100 ms from its first observation. It never reads or integrates a half frame.
struct FifoWait {
  static constexpr uint8_t maxPolls=2;
  static constexpr uint32_t maxMs=100;
  bool active=false;uint32_t firstAt=0;uint8_t polls=0;
  void reset(){active=false;firstAt=0;polls=0;}
  bool wait(uint32_t now) {
    if(!active){active=true;firstAt=now;polls=1;return true;}
    if(uint32_t(now-firstAt)>=maxMs||polls>=maxPolls){reset();return false;}
    ++polls;return true;
  }
};
struct BatchClock {
  static constexpr uint32_t freshnessMs=250,maxGapMs=500;
  uint32_t at=0;bool primed=false;
  void reset(){primed=false;}
  static uint32_t sampleTime(uint32_t end,unsigned index,unsigned count,float dt) {
    return end-uint32_t(lroundf(float(count-1-index)*dt*1000));
  }
  float interval(uint32_t now,unsigned count) {
    if(!count)return 0;
    uint32_t elapsed=uint32_t(now-at);
    float dt=primed?elapsed/(1000.0f*count):1.0f/56;
    // A late poll can use a full backlog. Allow two pairs for FIFO/clock phase.
    const bool gap=primed&&(elapsed>maxGapMs||
      (elapsed>freshnessMs&&elapsed*56>(count+2)*1000));
    at=now;primed=true;
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
  bool page=false,stream=false,phone=false,pending=false,waitForStop=false;
  uint32_t phoneGeneration=0;
  CalibrationSource source=CalibrationSource::TrustedStop;
  bool poll(bool visible,bool streaming,Motion motion,bool phoneEntry=false,uint32_t generation=0,bool needsMount=true){
    const bool pageEntry=visible&&!page;
    const bool phoneEntryEdge=phoneEntry&&(!phone||generation!=phoneGeneration);
    const bool subscription=streaming&&!stream;
    if(pageEntry){pending=true;waitForStop=false;source=CalibrationSource::ScreenPage;}
    else if(phoneEntryEdge&&(!pending||source==CalibrationSource::TrustedStop)){
      // A deliberate phone page entry is allowed to replace a subscription
      // that is merely waiting for a stop; it still never overrides manual work.
      pending=true;waitForStop=false;source=CalibrationSource::PhonePage;
    }
    else if(subscription&&!pending&&needsMount){
      // An automatic record or reconnect subscription may only use a trusted stop.
      // It must never turn an unknown motion state into a new installation mount.
      source=CalibrationSource::TrustedStop;
      if(motion==Motion::Stopped){pending=true;waitForStop=false;}
      else if(motion==Motion::Moving){pending=true;waitForStop=true;}
    }
    page=visible;stream=streaming;phone=phoneEntry;if(phoneEntry)phoneGeneration=generation;
    if(!visible&&!streaming&&!phoneEntry){pending=false;waitForStop=false;}
    if(pending&&source==CalibrationSource::ScreenPage&&!visible){pending=false;waitForStop=false;}
    if(pending&&source==CalibrationSource::PhonePage&&!phoneEntry){pending=false;waitForStop=false;}
    if(pending&&motion==Motion::Moving)waitForStop=true;
    const bool explicitSource=source==CalibrationSource::ScreenPage||source==CalibrationSource::PhonePage;
    return pending&&(motion==Motion::Stopped||(explicitSource&&motion==Motion::Unknown&&!waitForStop));
  }
  void finish(){pending=false;}
  void cancel(){pending=false;waitForStop=false;}
};
struct Stream {
  uint32_t epoch=0;
  uint32_t token=0,renewedAt=0,generated=0,overwritten=0,notifyAttempts=0,notifySkipped=0;uint16_t seq=0;bool active=false,pending=false;
  uint8_t bytes[17]={};
  static constexpr unsigned capacity=8;
  uint8_t queued[capacity][17]={};unsigned first=0,size=0;
  uint32_t discarded=0;
  void clearPending(){discarded+=size;first=size=0;pending=false;}
  const uint8_t *front()const{return size?queued[first]:nullptr;}
  void pop(){if(size){first=(first+1)%capacity;--size;}pending=size>0;}
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
      if(!active||token!=requested){seq=0;clearPending();}
      token=requested;renewedAt=now;active=true;return true;
    }
    if(rate==0&&active&&token==requested){active=false;clearPending();return true;}
    return false;
  }
  bool holdsPower(uint32_t now,bool authenticated) const {
    return active&&authenticated&&uint32_t(now-renewedAt)<15000;
  }
  bool tick(uint32_t now,bool authenticated) {
    if(active&&!holdsPower(now,authenticated)){active=false;clearPending();return true;}
    return false;
  }
  void maintain(uint32_t now,bool authenticated,uint32_t connectionEpoch,IdlePowerOffTimer &idle) {
    bool ended=false;
    if(epoch!=connectionEpoch){epoch=connectionEpoch;ended=active;active=false;clearPending();}
    ended=tick(now,authenticated)||ended;
    if(ended)idlePowerOffReset(&idle,now);
  }
  static void le(uint8_t *out,uint32_t value,unsigned n){for(unsigned i=0;i<n;i++)out[i]=uint8_t(value>>(8*i));}
  void frame(uint8_t *out,uint8_t flags,uint32_t now,int16_t lat,int16_t longitudinal) {
    out[0]=0xa7;out[1]=1;out[2]=flags;le(out+3,seq++,2);le(out+5,now,4);le(out+9,token,4);
    le(out+13,uint16_t(lat),2);le(out+15,uint16_t(longitudinal),2);
  }
  bool produce(uint8_t flags,uint32_t now,int16_t lat,int16_t longitudinal) {
    if(size==capacity){pop();++overwritten;}
    frame(bytes,flags,now,lat,longitudinal);
    std::memcpy(queued[(first+size)%capacity],bytes,sizeof(bytes));++size;
    ++generated;pending=true;return true;
  }
  void recordNotifyAttempt(){++notifyAttempts;}
  void recordNotifySkipped(){++notifySkipped;}
};
struct Output {
  struct Point {uint32_t at=0;float lateral=0,longitudinal=0;bool valid=false;};
  Point trail[100];unsigned head=0,count=0;uint32_t at=0,nextAt=0;bool sampled=false,valid=false;
  float lateral=0,longitudinal=0,accel=0,brake=0,left=0,right=0;
  void clear(){head=count=0;accel=brake=left=right=0;}
  bool update(uint32_t now,bool available,float x,float y) {
    if(sampled) {
      if(int32_t(now-at)<0||int32_t(now-nextAt)<0)return false;
      nextAt+=(uint32_t(now-nextAt)/50+1)*50;
    }else nextAt=now+50;
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
