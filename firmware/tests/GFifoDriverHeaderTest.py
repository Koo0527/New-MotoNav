"""Exercise the production QMI8658 FIFO header gate before any destructive read."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / 'libraries/SensorLib/src/sensor/imu/qmi8658/SensorQMI8658.cpp').read_text()
start = source.index('uint16_t SensorQMI8658::readFromFifo(')
gate = source[start:source.index('    size_t buffer_size = fifo_bytes;', start)]
stub = r'''
#include <cassert>
#include <cstdint>
#include <cstring>
#define SENSORLIB_LOG_D(...) ((void)0)
struct AccelerometerData {};
struct GyroscopeData {};
struct SensorQMI8658 {
  static constexpr uint16_t FifoPairPending=UINT16_MAX;
  static constexpr unsigned MASK_FIFO_EMPTY=0x10,REG_FIFO_SMPL_CNT_L=0x15;
  bool _fifo_enabled=true,_accel_enabled=true,_gyro_enabled=true;void *hal=this;
  uint8_t low=0,status=0x10;
  uint8_t getFifoStatus(){return status;}
  int readRegBuff(unsigned,uint8_t *out,unsigned){out[0]=low;out[1]=status;return 0;}
  uint16_t readFromFifo(AccelerometerData*,uint16_t,GyroscopeData*,uint16_t);
};
'''
cases = r'''
int main() {
  SensorQMI8658 sensor;AccelerometerData a;GyroscopeData w;
  for(unsigned words=1;words<6;words++) {
    sensor.low=words;
    assert(sensor.readFromFifo(&a,32,&w,32)==SensorQMI8658::FifoPairPending);
  }
  sensor.low=6;assert(sensor.readFromFifo(&a,32,&w,32)==1);
  sensor.status=0x30;assert(sensor.readFromFifo(&a,32,&w,32)==0);
  sensor.status=0x90;assert(sensor.readFromFifo(&a,32,&w,32)==0);
}
'''
with tempfile.TemporaryDirectory(prefix='g-fifo-driver-') as directory:
    folder = Path(directory)
    (folder / 'test.cpp').write_text(stub + gate + 'return fifo_bytes / 12;\n}\n' + cases)
    subprocess.run(['clang++', '-std=c++17', str(folder / 'test.cpp'), '-o', str(folder / 'test')], check=True)
    subprocess.run([str(folder / 'test')], check=True)
print('PASS production FIFO header gate: partial XYZ waits, full/overflow rejects')
