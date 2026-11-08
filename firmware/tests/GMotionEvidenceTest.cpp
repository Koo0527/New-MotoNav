#include <cassert>
#include <cstring>
#include <initializer_list>
#include "../boards/175/MotoNav/GInstrumentRuntime.h"
using namespace GInstrument;
int main() {
  MotionEvidence motion;
  assert(motion.current(0,true,1)==Motion::Unknown);
  assert(!motion.receive("#GM,0",0,false,1));
  assert(motion.receive("#GM,0",100,true,1));
  assert(motion.current(3099,true,1)==Motion::Stopped);
  assert(motion.current(3100,true,1)==Motion::Unknown);
  assert(motion.receive("#GM,0",2000,true,1));
  assert(motion.current(4000,true,1)==Motion::Stopped);
  assert(motion.current(4000,true,2)==Motion::Unknown);
  assert(motion.current(4000,false,1)==Motion::Unknown);
  motion.maintain(false,1);
  assert(motion.current(4000,true,1)==Motion::Unknown);
  assert(motion.receive("#GM,1",4500,true,2));
  assert(motion.current(4500,true,2)==Motion::Moving);
  for(const char *bad:{"GM,0","#GM,","#GM,-1","#GM,+1","#GM,3","#GM,00","#GM,0x","#GM,0\n"})
    assert(!motion.receive(bad,4501,true,2));
  assert(motion.current(4501,true,2)==Motion::Moving);
  assert(motion.receive("#GM,2",4502,true,2));
  assert(motion.current(4502,true,2)==Motion::Unknown);
  assert(motion.receive("#GM,0",0xfffffff0u,true,3));
  assert(motion.current(0x10,true,3)==Motion::Stopped);
  assert(motion.current(uint32_t(0xfffffff0u+3000),true,3)==Motion::Unknown);
  // Queue delay, authentication changes and reconnects cannot lend an old report a fresh lease.
  assert(!motion.receiveQueued("#GM,0",100,false,4,101,true,4));
  assert(!motion.receiveQueued("#GM,0",100,true,3,101,true,4));
  assert(!motion.receiveQueued("#GM,0",100,true,4,3100,true,4));
  assert(!motion.receiveQueued("#GM,0",100,true,4,101,false,4));
  assert(motion.receiveQueued("#GM,0",100,true,4,2000,true,4));
  assert(motion.current(3099,true,4)==Motion::Stopped);
  assert(motion.current(3100,true,4)==Motion::Unknown);
  AutoMount entry;
  assert(!entry.poll(true,false,Motion::Moving));
  assert(!entry.poll(true,false,Motion::Unknown));
  assert(entry.poll(true,false,Motion::Stopped));
  entry.finish();
  entry.poll(false,false,Motion::Unknown);
  assert(entry.poll(true,false,Motion::Unknown));
  // Navigation auto-record and reconnect subscriptions are not a deliberate page entry.
  // An unknown motion state must never re-create the installation mount by itself.
  AutoMount subscription;
  assert(!subscription.poll(false,true,Motion::Unknown));
  subscription.finish();
  subscription.poll(false,false,Motion::Unknown);
  assert(!subscription.poll(false,true,Motion::Unknown));
  subscription.finish();
  AutoMount stoppedSubscription;
  assert(stoppedSubscription.poll(false,true,Motion::Stopped));
  // A later page entry remains a deliberate calibration request even without motion evidence.
  AutoMount laterEntry;
  laterEntry.poll(false,true,Motion::Unknown);
  assert(laterEntry.poll(true,true,Motion::Unknown));
  // Calibration source gates: trusted stops require Stopped for the whole window,
  // explicit pages/manual may proceed on Unknown but never on Moving.
  assert(!CalibrationPolicy::mayRun(CalibrationSource::TrustedStop,Motion::Unknown));
  assert(!CalibrationPolicy::mayRun(CalibrationSource::TrustedStop,Motion::Moving));
  assert(CalibrationPolicy::mayRun(CalibrationSource::TrustedStop,Motion::Stopped));
  assert(CalibrationPolicy::mayRun(CalibrationSource::PhonePage,Motion::Unknown));
  assert(CalibrationPolicy::mayRun(CalibrationSource::ScreenPage,Motion::Unknown));
  assert(CalibrationPolicy::mayRun(CalibrationSource::Manual,Motion::Unknown));
  assert(!CalibrationPolicy::mayRun(CalibrationSource::PhonePage,Motion::Moving));
  assert(!CalibrationGate::mayStart(CalibrationSource::TrustedStop,Motion::Stopped,false));
  assert(!CalibrationGate::maySave(CalibrationSource::PhonePage,Motion::Unknown,false));
  assert(CalibrationGate::mayStart(CalibrationSource::PhonePage,Motion::Unknown,true));
  assert(CalibrationGate::maySave(CalibrationSource::Manual,Motion::Unknown,true));
  assert(!CalibrationGate::mayStart(CalibrationSource::ScreenPage,Motion::Moving,true));
  // Manual calibration is bound to the authenticated connection that queued #GC.
  ManualCalibrationSession manual;
  assert(!manual.receive(false,1,true,1));
  assert(!manual.receive(true,1,false,1));
  assert(!manual.receive(true,1,true,2));
  assert(manual.receive(true,1,true,1));
  assert(manual.valid(true,1));
  assert(!manual.valid(false,1));
  assert(!manual.valid(true,2));
  int writes=0;
  if(CalibrationGate::maySave(CalibrationSource::Manual,Motion::Stopped,manual.valid(true,1)))++writes;
  assert(writes==1);
  if(CalibrationGate::maySave(CalibrationSource::Manual,Motion::Stopped,manual.valid(true,2)))++writes;
  assert(writes==1); // A new connection cannot save the old candidate.
  manual.clear();
  assert(!manual.valid(true,1));
  // Phone entry is bound to the authenticated session, current stream token and 3 s queue age.
  PhoneEntry phone;uint32_t phoneToken;bool phoneEnter;
  assert(PhoneEntry::parse("#GE,1234aBcD,1",phoneToken,phoneEnter)&&phoneToken==0x1234abcd&&phoneEnter);
  assert(PhoneEntry::parse("#GE,1234ABCD,0",phoneToken,phoneEnter)&&phoneToken==0x1234abcd&&!phoneEnter);
  for(const char *bad:{"#GE,1234ABCD","#GE,1234ABCD,2","#GE,1234ABC,1","#GE,1234ABCDE,1","#GE,1234ABCD,1\n","#GE,ZZZZZZZZ,1"})
    assert(!PhoneEntry::parse(bad,phoneToken,phoneEnter));
  const uint32_t phoneId=0x1234abcd;
  assert(!phone.receive("#GE,1234ABCD,1",100,false,1,true,phoneId));
  assert(!phone.receive("#GE,1234ABCD,1",100,true,1,false,phoneId));
  assert(!phone.receive("#GE,1234ABCD,1",100,true,1,true,0xdeadbeef));
  assert(phone.receive("#GE,1234ABCD,1",100,true,1,true,phoneId));
  assert(phone.at==100&&phone.current(true,1,true,phoneId));
  assert(phone.receive("#GE,1234ABCD,1",200,true,1,true,phoneId));
  assert(phone.at==100); // A repeated 1 is not a new entry event.
  assert(phone.generation()==1);
  assert(!phone.receive("#GE,1234ABCD,0",300,true,1,true,0xdeadbeef));
  assert(phone.current(true,1,true,phoneId));
  assert(phone.receive("#GE,1234ABCD,0",300,true,1,true,phoneId));
  assert(!phone.current(true,1,true,phoneId));
  assert(phone.receiveQueued("#GE,1234ABCD,1",1000,true,1,1001,true,1,true,phoneId));
  assert(phone.generation()==2);
  assert(phone.current(true,1,true,phoneId));
  assert(!phone.receiveQueued("#GE,1234ABCD,1",1000,true,1,4000,true,1,true,phoneId));
  phone.maintain(true,2,true,phoneId);
  assert(!phone.current(true,2,true,phoneId));
  phone.receive("#GE,1234ABCD,1",5000,true,2,true,phoneId);
  phone.maintain(true,2,false,phoneId);
  assert(!phone.current(true,2,true,phoneId));
  phone.receive("#GE,1234ABCD,1",5000,true,2,true,phoneId);
  phone.maintain(false,2,true,phoneId);
  assert(!phone.current(true,2,true,phoneId));
  phone.receive("#GE,1234ABCD,1",6000,true,2,true,phoneId);
  phone.maintain(true,2,true,0xdeadbeef);
  assert(!phone.current(true,2,true,phoneId));
  // Phone page entry is a deliberate Unknown calibration source, but a repeated
  // request cannot re-arm after completion; leaving and re-entering can.
  AutoMount phoneMount;
  assert(!phoneMount.poll(false,false,Motion::Unknown,false));
  assert(phoneMount.poll(false,false,Motion::Unknown,true));
  assert(phoneMount.source==CalibrationSource::PhonePage);
  phoneMount.finish();
  assert(!phoneMount.poll(false,false,Motion::Unknown,true));
  phoneMount.poll(false,false,Motion::Unknown,false);
  assert(phoneMount.poll(false,false,Motion::Unknown,true));
  phoneMount.cancel();
  assert(!phoneMount.poll(false,false,Motion::Unknown,true));
  phoneMount.poll(false,false,Motion::Unknown,false);
  assert(phoneMount.poll(false,false,Motion::Unknown,true));
  AutoMount quickEntry;
  assert(quickEntry.poll(false,true,Motion::Unknown,true,1));
  quickEntry.finish();
  assert(!quickEntry.poll(false,true,Motion::Unknown,true,1)); // duplicate 1
  assert(quickEntry.poll(false,true,Motion::Unknown,true,2));  // new token's explicit request
  quickEntry.finish();
  assert(!quickEntry.poll(false,true,Motion::Unknown,true,2)); // an open page does not authorize fault recovery
  AutoMount installed;
  assert(!installed.poll(false,true,Motion::Stopped,false,0,false));
  assert(!installed.pending); // A saved mount only needs runtime recovery.
  assert(installed.poll(true,true,Motion::Unknown,false,0,false)); // Actual entry still calibrates.
  // An explicit phone page entry promotes a subscription waiting for a stop,
  // because the user has asserted they are parked even without motion evidence.
  AutoMount mixed;
  assert(!mixed.poll(false,true,Motion::Moving,false));
  assert(mixed.source==CalibrationSource::TrustedStop);
  assert(mixed.poll(false,true,Motion::Unknown,true));
  assert(mixed.source==CalibrationSource::PhonePage);
  // A sampling gap cannot count as three seconds of continuous quiet.
  CalibrationWindow window;window.begin(0);
  for(unsigned i=0;i<150;i++)assert(window.sample({0,0,1},{},i*18)==0);
  assert(window.sample({0,0,1},{},4000)==0);
  assert(window.pose.stable==1);
  for(unsigned i=1;i<168;i++)assert(window.sample({0,0,1},{},4000+i*18)==(i==167?1:0));
}
