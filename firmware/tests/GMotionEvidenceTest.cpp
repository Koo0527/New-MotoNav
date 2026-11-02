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
  // A sampling gap cannot count as three seconds of continuous quiet.
  CalibrationWindow window;window.begin(0);
  for(unsigned i=0;i<150;i++)assert(window.sample({0,0,1},{},i*18)==0);
  assert(window.sample({0,0,1},{},4000)==0);
  assert(window.pose.stable==1);
  for(unsigned i=1;i<168;i++)assert(window.sample({0,0,1},{},4000+i*18)==(i==167?1:0));
}
