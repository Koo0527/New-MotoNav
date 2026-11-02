#include <cassert>
#include <cstring>
#include <initializer_list>
#include "../boards/175/MotoNav/GInstrumentRuntime.h"
using namespace GInstrument;
int main(){
 IdlePowerOffTimer idle={0,false};Stream lease;lease.maintain(0,true,1,idle);
 lease.command(1,20,0,true);idlePowerOffReset(&idle,0);lease.maintain(10000,true,1,idle);assert(idle.since==0);
 lease.maintain(15000,true,1,idle);assert(idle.since==15000&&!lease.active);
 lease.command(1,20,16000,true);lease.maintain(16050,false,1,idle);assert(idle.since==16050&&!lease.active);
 lease.command(2,20,17000,true);lease.maintain(17001,true,2,idle);assert(idle.since==17001&&!lease.active);
 Stream log;uint32_t token;unsigned rate;
 assert(Stream::parse("#GS,1234aBcD,20",token,rate)&&token==0x1234abcd&&rate==20);
 for(const char *s:{"#GS,0000000,20","#GS,00000000,21","#GS,00000000,+20","#GS,00000000,20x","#GS,zz000000,0"})assert(!Stream::parse(s,token,rate));
 assert(log.command(1,20,100,true));assert(log.holdsPower(15099,true));
 assert(log.tick(15100,true));assert(!log.holdsPower(15100,true));
 log.command(2,20,20000,true);assert(log.command(2,20,25000,true));
 assert(!log.command(1,0,25000,true));assert(log.holdsPower(39999,true));
 assert(log.tick(40000,true));assert(!log.holdsPower(40000,true));
 log.command(3,20,0,true);log.seq=65535;uint8_t b[17];
 log.frame(b,1,0x12345678,-123,456);assert(b[0]==0xa7&&b[1]==1&&b[2]==1&&b[3]==255&&b[4]==255&&b[5]==0x78&&b[8]==0x12&&b[9]==3&&b[13]==0x85&&b[14]==0xff&&b[15]==0xc8&&b[16]==1);assert(log.seq==0);
 assert(log.tick(1,false));assert(!log.pending);assert(!log.command(3,20,1,false));
 assert(FifoStatus::count(3,0)==0); // Half of an accel/gyro pair: wait, do not reset.
 assert(FifoStatus::count(9,0)==0);
 assert(FifoStatus::count(6,0)==1);assert(FifoStatus::count(0,0x10)==0);
 assert(FifoStatus::count(1,0)==-1);assert(FifoStatus::count(0,0x20)==-2);assert(FifoStatus::count(0,0x80)==-2);
 BatchClock cadence;assert(fabsf(cadence.interval(0,1)-1.0f/56)<0.00001f);
 Estimator tilt;assert(makeMount({0,0,1},{},1,0,tilt.mount));tilt.initialized=true;tilt.up={0,0,1};
 uint32_t physical=0;float angle=0;
 for(int batch=0;batch<20;batch++) {
   unsigned n=batch%2?3:1;physical+=batch%2?80:20;float dt=cadence.interval(physical,n);
   for(unsigned i=0;i<n;i++){angle+=30*dt*0.01745329252f;tilt.sample({0,sinf(angle),cosf(angle)},{30,0,0},dt);}
 }
 assert(tilt.available&&fabsf(tilt.lateral)<0.005f&&fabsf(tilt.longitudinal)<0.005f);
 assert(cadence.interval(physical+501,6)==0);cadence.reset();assert(cadence.interval(1,1)>0);assert(cadence.interval(102,1)==0);
 CalibrationWindow fast;fast.begin(0);for(int i=0;i<300;i++)assert(fast.sample({0,0,1},{},i*10)==0);
 assert(fast.sample({0,0,1},{},2999)==0);assert(fast.sample({0,0,1},{},3000)==1);
 CalibrationWindow c;c.begin(10);for(int i=0;i<100;i++)assert(c.sample({0,0,1},{},10+i*18)==0);
 assert(c.sample({0.3f,0,1},{5,0,0},1810)==0);assert(c.pose.stable==0);
 int result=0;for(int i=0;i<168;i++)result=c.sample({0,0,1},{},2000+i*18);assert(result==1);
 c.begin(0);assert(c.sample({0,0,1},{},15000)==-1);
 AutoMount entry;
 assert(!entry.poll(false,false,Motion::Stopped));
 assert(entry.poll(true,false,Motion::Stopped));entry.finish();assert(!entry.poll(true,false,Motion::Stopped));
 entry.poll(false,false,Motion::Stopped);assert(entry.poll(true,false,Motion::Stopped));entry.finish();
 assert(entry.poll(true,true,Motion::Stopped));entry.finish();assert(!entry.poll(true,true,Motion::Stopped));
 entry.poll(false,false,Motion::Stopped);assert(!entry.poll(true,false,Motion::Moving));
 assert(entry.poll(true,false,Motion::Stopped));entry.finish();
 entry.poll(false,false,Motion::Stopped);assert(!entry.poll(false,false,Motion::Stopped));
 CalibrationWindow automatic;automatic.continuous=true;automatic.begin(0);
 assert(automatic.sample({0.3f,0,1},{5,0,0},15000)==0);
 int recovered=0;
 for(int i=0;i<180&&!recovered;i++)recovered=automatic.sample({0.5f,0,0.8660254f},{4.1f,2.1f,0.25f},16000+i*18);
 assert(recovered==1);
 // A one-hour 20Hz session remains bounded; sequence wraps and renewal does not reset it.
 Stream hour;hour.command(0x89abcdef,20,0,true);Output bounded;
 for(uint32_t i=0;i<72000;i++) {
   uint32_t now=i*50;
   if(i%100==0)hour.command(0x89abcdef,20,now,true);
   assert(hour.holdsPower(now,true));
   assert(bounded.update(now,i%10!=0,0.1f,-0.2f));
   hour.frame(hour.bytes,bounded.valid?1:0,now,100,-200);
   assert(hour.bytes[9]==0xef&&hour.bytes[12]==0x89);
 }
 assert(hour.seq==uint16_t(72000)&&bounded.count==100);
 assert(hour.tick(3600000+15000,true));
 Stream wrap;wrap.command(9,20,0xfffffff0u,true);assert(wrap.holdsPower(0x10,true));
 assert(wrap.tick(uint32_t(0xfffffff0u+15000),true));
 CalibrationWindow wrapCal;wrapCal.begin(0xffffff00u);assert(wrapCal.sample({0,0,1},{},uint32_t(0xffffff00u+15000))==-1);
 Output o;assert(o.update(0,true,0.25f,0.5f));assert(!o.update(49,true,1,1));assert(o.update(50,true,-0.75f,-0.6f));
 assert(o.accel==0.5f&&o.brake==0.6f&&o.left==0.75f&&o.right==0.25f);
 assert(o.update(100,false,0,0));assert(!o.valid&&o.count==3);o.clear();assert(o.count==0&&o.accel==0);
}
