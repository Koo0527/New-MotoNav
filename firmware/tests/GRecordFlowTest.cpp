#include <cassert>
#include <cstdio>
#include "../boards/175/MotoNav/GInstrumentRuntime.h"
using namespace GInstrument;

int main() {
  Stream stream;
  assert(stream.command(0x12345678u, 20, 1000, true));
  assert(stream.produce(1, 1000, 10, -20));
  assert(stream.generated == 1);
  assert(stream.overwritten == 0);
  assert(stream.pending);
  assert(stream.produce(1, 1107, 20, -30));
  assert(stream.generated == 2);
  assert(stream.overwritten == 0); // Two real frames from one FIFO batch must both remain queued.
  stream.recordNotifyAttempt();
  assert(stream.notifyAttempts == 1);
  stream.pop();
  assert(stream.pending && stream.front()[3]==1);
  stream.pop();assert(!stream.pending);

  // Two generated frames per notification sweep must retain both timestamps.
  Stream cadence;
  assert(cadence.command(0x89abcdefu, 20, 0, true));
  for (int i = 0; i < 10; ++i) {
    assert(cadence.produce(1, uint32_t(i) * 107u, int16_t(i), int16_t(-i)));
    if (i % 2 == 1) {
      while(cadence.pending){cadence.recordNotifyAttempt();cadence.pop();}
    }
  }
  assert(cadence.generated == 10);
  assert(cadence.overwritten == 0);
  assert(cadence.notifyAttempts == 10);

  for(unsigned i=0;i<10;i++)cadence.produce(1,2000+i*50,0,0);
  assert(cadence.size==8 && cadence.overwritten==2 && cadence.front()[3]==12);
  cadence.command(7,20,3000,true);
  assert(!cadence.pending && cadence.size==0 && cadence.discarded==8);
  cadence.produce(1,3000,0,0);assert(cadence.front()[3]==0);
  cadence.tick(18000,true);assert(!cadence.pending && cadence.size==0);

  cadence.recordNotifySkipped();
  assert(cadence.notifySkipped == 1);

  std::printf("GRecordFlowTest passed\n");
  return 0;
}
