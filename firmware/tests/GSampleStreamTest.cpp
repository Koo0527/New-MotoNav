#include <cassert>
#include <cstdio>
#include "../boards/175/MotoNav/GInstrumentRuntime.h"
using namespace GInstrument;

static uint32_t timestamp(const uint8_t *frame) {
  return uint32_t(frame[5])|(uint32_t(frame[6])<<8)|(uint32_t(frame[7])<<16)|(uint32_t(frame[8])<<24);
}

int main() {
  Estimator estimator;estimator.initialized=true;estimator.up={0,0,1};
  assert(makeMount(estimator.up,{},1,0,estimator.mount));
  Output output;Stream stream;stream.command(1,20,0,true);
  unsigned delivered=0;uint32_t last=0;int16_t lastValue=-1;
  // The main loop can only return every 108ms. Six actual samples still
  // produce their individual estimates and timestamps, not a repeated latest value.
  for(unsigned batch=1;batch<=100;batch++) {
    for(unsigned i=0;i<6;i++) {
      const uint32_t at=BatchClock::sampleTime(batch*108,i,6,0.018f);
      const float force=float((batch-1)*6+i)/1000;
      estimator.sample({force,0,1},{},0.018f,Motion::Moving);
      assert(estimator.available);
      if(output.update(at,true,estimator.lateral,estimator.longitudinal))
        stream.produce(1,at,Output::milli(output.lateral),Output::milli(output.longitudinal));
    }
    while(stream.pending) {
      const auto *frame=stream.front();const auto at=timestamp(frame);
      const int16_t value=int16_t(uint16_t(frame[15])|(uint16_t(frame[16])<<8));
      assert(at>last && value>lastValue && frame[2]==1);
      last=at;lastValue=value;++delivered;stream.pop();
    }
  }
  assert(delivered==216 && stream.overwritten==0);
  assert(BatchClock::sampleTime(10,0,2,0.018f)==uint32_t(10-18));
  Output wrapped;
  assert(wrapped.update(0xfffffff0u,true,1,1));
  assert(!wrapped.update(0x10,true,1,1));
  assert(wrapped.update(0x30,true,1,1));
  puts("PASS sample stream: batched real estimates, 20Hz phase, bounded FIFO, monotonic board time and wrap");
}
