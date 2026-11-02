#pragma once
#include <Arduino.h>
#include <Preferences.h>
#include <Wire.h>
#include <driver/i2s_std.h>
#include <sensor/imu/qmi8658/SensorQMI8658.hpp>
#include "src/audio/es8311.h"
#include "BootTone.h"
#include "GInstrumentMath.h"
#include "GInstrumentRuntime.h"
#include "InstrumentCommands.h"

bool bootSoundEnabled=true;
int bootSoundVolume=20;
i2s_chan_handle_t bootAudioTx=nullptr;
es8311_handle_t bootCodec=nullptr;
uint32_t bootAudioAt=0;size_t bootAudioSent=0;
int16_t bootAudioPcm[BootTone::frames*2];
void bootSoundStop(){
  digitalWrite(46,LOW);
  if(bootCodec){es8311_voice_mute(bootCodec,true);es8311_delete(bootCodec);bootCodec=nullptr;}
  if(bootAudioTx){i2s_channel_disable(bootAudioTx);i2s_del_channel(bootAudioTx);bootAudioTx=nullptr;}
}
void bootSoundTick(){
  if(!bootAudioTx)return;
  size_t sent=0;
  if(bootAudioSent<sizeof(bootAudioPcm)){
    esp_err_t err=i2s_channel_write(bootAudioTx,(uint8_t*)bootAudioPcm+bootAudioSent,sizeof(bootAudioPcm)-bootAudioSent,&sent,0);
    bootAudioSent+=sent;
    if(err!=ESP_OK&&err!=ESP_ERR_TIMEOUT){bootSoundStop();return;}
  }
  if(millis()-bootAudioAt>=430)bootSoundStop();
}
void bootSoundBegin(){
  pinMode(46,OUTPUT);digitalWrite(46,LOW);
  Preferences p;p.begin("motonav",true);bootSoundEnabled=p.getBool("sound",true);
  bootSoundVolume=constrain(p.getInt("soundvol",20),0,100);
  if(p.isKey("soundcfg")){uint32_t saved=p.getUInt("soundcfg",0x100|20);
    if((saved&~0x1ffU)==0 && (saved&0xff)<=100){bootSoundEnabled=(saved&0x100)!=0;bootSoundVolume=saved&0xff;}}
  p.end();
  if(!bootSoundEnabled||!bootSoundVolume)return;
  i2s_chan_config_t channel=I2S_CHANNEL_DEFAULT_CONFIG(I2S_NUM_AUTO,I2S_ROLE_MASTER);
  channel.dma_desc_num=12;channel.dma_frame_num=512;
  if(i2s_new_channel(&channel,&bootAudioTx,nullptr)!=ESP_OK){bootSoundStop();return;}
  i2s_std_config_t cfg={};cfg.clk_cfg=I2S_STD_CLK_DEFAULT_CONFIG(BootTone::rate);
  cfg.slot_cfg=I2S_STD_PHILIPS_SLOT_DEFAULT_CONFIG(I2S_DATA_BIT_WIDTH_16BIT,I2S_SLOT_MODE_STEREO);
  cfg.gpio_cfg.mclk=GPIO_NUM_16;cfg.gpio_cfg.bclk=GPIO_NUM_9;cfg.gpio_cfg.ws=GPIO_NUM_45;
  cfg.gpio_cfg.dout=GPIO_NUM_8;cfg.gpio_cfg.din=I2S_GPIO_UNUSED;
  if(i2s_channel_init_std_mode(bootAudioTx,&cfg)!=ESP_OK||i2s_channel_enable(bootAudioTx)!=ESP_OK){bootSoundStop();return;}
  bootCodec=es8311_create(0,ES8311_ADDRESS_0);
  es8311_clock_config_t clock={false,false,true,BootTone::rate*256,BootTone::rate};
  if(!bootCodec||es8311_init(bootCodec,&clock,ES8311_RESOLUTION_16,ES8311_RESOLUTION_16)!=ESP_OK||
    es8311_voice_volume_set(bootCodec,bootSoundVolume,nullptr)!=ESP_OK){bootSoundStop();return;}
  // No microphone path: power down ADC/PGA after the vendor DAC initialization.
  Wire.beginTransmission(ES8311_ADDRESS_0);Wire.write(0x0e);Wire.write(0xff);
  if(Wire.endTransmission()!=0){bootSoundStop();return;}
  for(int i=0;i<BootTone::frames;i++)bootAudioPcm[i*2]=bootAudioPcm[i*2+1]=BootTone::sample(i);
  bootAudioSent=0;bootAudioAt=millis();digitalWrite(46,HIGH);bootSoundTick();
}
String bootSoundCommand(String command){
  if(command.startsWith("#"))command.remove(0,1);
  if(command!="BS"&&!command.startsWith("BS,"))return "";
  int enabled,volume;
  if(command!="BS"){
    if(!InstrumentCommands::pair(command.c_str(),"BS,",enabled,volume)||enabled>1||volume>100)return "BS,ERR";
    if(bootSoundEnabled!=bool(enabled)||bootSoundVolume!=volume){
      Preferences p;bool saved=false;
      if(p.begin("motonav",false)){saved=p.putUInt("soundcfg",(enabled?0x100U:0U)|unsigned(volume))==sizeof(uint32_t);p.end();}
      if(saved){bootSoundEnabled=enabled;bootSoundVolume=volume;}
      else Serial.println("Boot sound settings not saved");
    }
    if(!enabled||!volume)bootSoundStop();
  }
  return String("BS,")+int(bootSoundEnabled)+","+bootSoundVolume;
}

SensorQMI8658 gSensor;
GInstrument::Estimator gEstimator;
GInstrument::CalibrationWindow gQuiet;
GInstrument::BatchClock gBatchClock;
GInstrument::Output gOutput;
GInstrument::Stream gStream;
GInstrument::MotionEvidence gMotion;
GInstrument::AutoMount gAutoMount;
bool gSensorPresent=false,gSampling=false,gCalibration=false,gCalibrationAuto=false,gSaturated=false;
int gState=0,gCalRef=0,gCalAngle=0,gAddress=0x6b,gLastFault=0;
uint32_t gPollAt=0,gDataAt=0,gDiagnosticUntil=0,gLastDiagAt=0;
uint32_t gSamples=0,gValidSamples=0,gErrors=0,gOverflows=0,gFallbacks=0,gLastSamples=0,gCpuUs=0;
GInstrument::Vec gRawA{},gRawW{};
uint32_t gResets=0,gLastPollGap=0;unsigned gLastBatchSamples=0;float gLastBatchDt=0;
GInstrument::Motion gCurrentMotion(){return gMotion.current(millis(),bleConnected&&bleAuthed,mediaConnectionEpoch);}
void gInvalidate(){
  gEstimator.reset();gQuiet.pose.reset();gOutput.valid=false;gStream.pending=false;++gResets;
}

bool gRead(uint8_t reg,uint8_t *data,size_t n) {
  Wire.beginTransmission(gAddress);Wire.write(reg);
  if(Wire.endTransmission(false)!=0 || Wire.requestFrom(uint8_t(gAddress),uint8_t(n))!=n)return false;
  for(size_t i=0;i<n;i++)data[i]=Wire.read();
  return true;
}
int gReg(uint8_t reg){uint8_t value=0;return gRead(reg,&value,1)?value:-1;}
bool gWrite(uint8_t reg,uint8_t value) {
  Wire.beginTransmission(gAddress);Wire.write(reg);Wire.write(value);return Wire.endTransmission()==0;
}
void gDiagnostic(bool force=false) {
  uint32_t now=millis();if(!force&&uint32_t(now-gLastDiagAt)<1000)return;gLastDiagAt=now;
  uint8_t fifo[2]={},raw[12]={};bool ok=gRead(0x15,fifo,2);
  bool rawOk=gRead(0x35,raw,sizeof(raw));
  int16_t xyz[6]={};for(int i=0;i<6;i++)xyz[i]=int16_t(uint16_t(raw[i*2])|(uint16_t(raw[i*2+1])<<8));
  Serial.printf("G state=%d id=%02X addr=%02X ctrl=%02X/%02X/%02X/%02X/%02X fifo=%02X:%02X wm=%d status=%02X n=%lu valid=%lu hz=%lu err=%lu ovf=%lu direct=%lu cpu_us=%lu fault=%d a=%.3f/%.3f/%.3f w=%.2f/%.2f/%.2f pose=%d raw=%d:%d/%d/%d/%d/%d/%d axis=USB_REAR_NEG_X_FACE_POS_Z\n",
    gState,gReg(0x00),gAddress,gReg(0x02),gReg(0x03),gReg(0x04),gReg(0x06),gReg(0x08),
    ok?fifo[1]:255,ok?fifo[0]:255,gReg(0x13),gReg(0x2e),
    (unsigned long)gSamples,(unsigned long)gValidSamples,(unsigned long)(gSamples-gLastSamples),(unsigned long)gErrors,
    (unsigned long)gOverflows,(unsigned long)gFallbacks,(unsigned long)gCpuUs,gLastFault,
    gRawA.x,gRawA.y,gRawA.z,gRawW.x,gRawW.y,gRawW.z,gQuiet.active?gQuiet.pose.stable:gEstimator.stable,rawOk,xyz[0],xyz[1],xyz[2],xyz[3],xyz[4],xyz[5]);
  Serial.printf("G pose up=%.3f/%.3f/%.3f g=%.3f/%.3f quiet=%.2f motion=%d mount=%d/%d bias=%.3f/%.3f/%.3f batch=%u dt=%.6f poll_ms=%lu resets=%lu motion_rx_age_ms=%lu\n",
    gEstimator.up.x,gEstimator.up.y,gEstimator.up.z,gEstimator.lateral,gEstimator.longitudinal,
    gEstimator.quietSeconds,int(gCurrentMotion()),gEstimator.mount.ref,gEstimator.mount.angle,
    gEstimator.runtimeBias.x,gEstimator.runtimeBias.y,gEstimator.runtimeBias.z,gLastBatchSamples,gLastBatchDt,
    (unsigned long)gLastPollGap,(unsigned long)gResets,(unsigned long)uint32_t(now-gMotion.at));
  gLastSamples=gSamples;gCpuUs=0;
}
void gInstrumentBegin(){
  Preferences p;p.begin("motonav",true);
  GInstrument::Mount mount;
  // A new key invalidates old unverified PCB mappings without rewriting historical records.
  if(p.getBytesLength("gmount2")==sizeof(mount))p.getBytes("gmount2",&mount,sizeof(mount));p.end();
  if(mount.valid&&mount.ref>=0&&mount.ref<=2&&mount.angle>=0&&mount.angle<=359&&
     fabsf(GInstrument::norm(mount.forward)-1)<0.01f&&GInstrument::norm(mount.bias)<15){
    gEstimator.mount=mount;gState=1;
  }
  gSensorPresent=gSensor.begin(Wire,gAddress);
  if(!gSensorPresent){gAddress=0x6a;gSensorPresent=gSensor.begin(Wire,gAddress);}
  if(gSensorPresent)gSensorPresent=gSensor.configAccel(SensorQMI8658::AccelRange::FS_4G,56.0f,SensorQMI8658::LpfMode::MODE_3)&&
    gSensor.configGyro(SensorQMI8658::GyroRange::FS_512DPS,56.0f,SensorQMI8658::LpfMode::MODE_3);
  if(!gSensorPresent)gState=5;
  gDiagnostic(true);
}
String gInstrumentStatus(){return String("GC,")+gState+","+gEstimator.mount.ref+","+gEstimator.mount.angle;}
void gBeginCalibration(int ref,int angle,bool automatic) {
  gCalRef=ref;gCalAngle=angle;gCalibration=true;gCalibrationAuto=automatic;
  gQuiet.continuous=automatic;gQuiet.begin(millis());gState=3;gOutput.valid=false;
  if(gSampling){gSensor.resetFifo();gBatchClock.reset();}
}
void gStreamSessionTick() {
  const bool authenticated=bleConnected&&bleAuthed;
  gMotion.maintain(authenticated,mediaConnectionEpoch);
  const bool sameSession=gStream.epoch==mediaConnectionEpoch;
  const bool wasActive=gStream.active;
  if(!sameSession||!authenticated)pendingGStreamStatus="";
  const uint32_t token=gStream.token;
  gStream.maintain(millis(),authenticated,mediaConnectionEpoch,idlePowerOffTimer);
  if(wasActive&&!gStream.active&&authenticated&&sameSession) {
    char reply[20];snprintf(reply,sizeof(reply),"GS,%08lX,0",(unsigned long)token);pendingGStreamStatus=reply;
  }
}
String gInstrumentCommand(String command){
  if(command.startsWith("#GS,")) {
    uint32_t token=0;unsigned rate=0;
    if(!GInstrument::Stream::parse(command.c_str(),token,rate))return "GS,ERR";
    const bool wasActive=gStream.active;
    const bool fresh=rate==20&&(!gStream.active||gStream.token!=token);
    if(gStream.command(token,rate,millis(),bleConnected&&bleAuthed)){pendingGStreamStatus="";if(fresh)gOutput.clear();}
    if(wasActive&&!gStream.active)idlePowerOffReset(&idlePowerOffTimer,millis());
    char reply[20];snprintf(reply,sizeof(reply),"GS,%08lX,%d",(unsigned long)token,gStream.active&&gStream.token==token?1:0);return reply;
  }
  if(command.startsWith("#"))command.remove(0,1);
  if(command=="GD") {
    gDiagnosticUntil=millis()+15000;gDiagnostic(true);
    return String("GD,")+gState+","+gSamples+","+gErrors;
  }
  if(command=="GQ")return gInstrumentStatus();
  if(!command.startsWith("GC,"))return "";
  int ref,angle;
  if(gCurrentMotion()==GInstrument::Motion::Moving||!InstrumentCommands::pair(command.c_str(),"GC,",ref,angle)||ref>2||angle>359){gState=4;return gInstrumentStatus();}
  if(!gSensorPresent){gState=5;return gInstrumentStatus();}
  gAutoMount.finish();gBeginCalibration(ref,angle,false);
  return gInstrumentStatus();
}
void gInstrumentNotify() {
  if(!gStream.holdsPower(millis(),bleConnected&&bleAuthed)){gStream.pending=false;return;}
  if(gStream.pending){txChar->setValue(gStream.bytes,sizeof(gStream.bytes));txChar->notify();gStream.pending=false;}
}
void gInstrumentSample(GInstrument::Vec av,GInstrument::Vec wv,uint32_t now,float dt,GInstrument::Motion motion) {
  gRawA=av;gRawW=wv;++gSamples;
  gSaturated=fabsf(av.x)>=3.99f||fabsf(av.y)>=3.99f||fabsf(av.z)>=3.99f||fabsf(wv.x)>=511||fabsf(wv.y)>=511||fabsf(wv.z)>=511;
  if(gCalibration) {
    int result=gQuiet.sample(av,wv,now);
    if(result) {
      GInstrument::Mount candidate;
      bool saved=false;
      if(result>0&&GInstrument::makeMount(GInstrument::unit(gQuiet.pose.meanA),gQuiet.pose.meanW,gCalRef,gCalAngle,candidate)) {
        Preferences p;if(p.begin("motonav",false)){saved=p.putBytes("gmount2",&candidate,sizeof(candidate))==sizeof(candidate);p.end();}
      }
      if(saved) {
        gEstimator.mount=candidate;gEstimator.reset();gEstimator.up=GInstrument::unit(gQuiet.pose.meanA);
        gEstimator.runtimeBias=gQuiet.pose.meanW;gEstimator.initialized=true;gOutput.clear();gState=2;
      }else {gState=4;gEstimator.reset();}
      gCalibration=false;gCalibrationAuto=false;gAutoMount.finish();pendingInstrumentStatus=gInstrumentStatus();
    }
  }
  // A failed attempt retains the saved mount; fresh stationary data rebuilds runtime gravity.
  if(!gCalibration){gEstimator.sample(av,wv,dt,motion);if(gEstimator.available&&!gSaturated)++gValidSamples;if(gState!=4)gState=gEstimator.available?2:gEstimator.mount.valid?1:0;}
}
void gInstrumentTick(bool active){
  uint32_t cpuAt=micros();const uint32_t now=millis();
  const bool recording=gStream.holdsPower(now,bleConnected&&bleAuthed);
  const bool visible=page==3&&!deviceControls.asleep;
  const GInstrument::Motion motion=gCurrentMotion();
  const bool calibrationAllowed=motion!=GInstrument::Motion::Moving;
  const bool autoWaiting=gAutoMount.poll(visible,recording,motion);
  if(gCalibration&&((gCalibrationAuto&&(!calibrationAllowed||(!visible&&!recording)))||(!gCalibrationAuto&&!calibrationAllowed))) {
    gCalibration=false;gQuiet.active=false;gState=gCalibrationAuto?(gEstimator.mount.valid?1:0):4;
    gCalibrationAuto=false;gEstimator.reset();pendingInstrumentStatus=gInstrumentStatus();
  }
  if(gCalibration&&!gCalibrationAuto&&uint32_t(now-gQuiet.began)>=15000){gCalibration=false;gQuiet.active=false;gState=4;gEstimator.reset();pendingInstrumentStatus=gInstrumentStatus();}
  if(autoWaiting&&!gCalibration&&gSensorPresent) {
    gBeginCalibration(gEstimator.mount.ref,gEstimator.mount.angle,true);pendingInstrumentStatus=gInstrumentStatus();
  }
  active=active||gCalibration||recording||(gDiagnosticUntil&&int32_t(gDiagnosticUntil-now)>0);
  if(!gSensorPresent){gState=5;}
  else if(active!=gSampling){
    if(active) {
      // SensorLib configFifo ignores its watermark argument; explicitly set one sample.
      bool ok=gSensor.enableAccel()&&gSensor.enableGyro()&&gSensor.configFifo(SensorQMI8658::FifoMode::STREAM,SensorQMI8658::FifoSamples::SAMPLES_128,1)&&gWrite(0x13,1);
      if(!ok){gState=5;++gErrors;gSensor.disableAccel();gSensor.disableGyro();}
      else {gSampling=true;gSensor.resetFifo();gDataAt=now;gPollAt=now;gBatchClock.reset();gEstimator.reset();if(!gCalibration)gState=gEstimator.mount.valid?1:0;}
    }else{gSensor.configureFifo(false);gSensor.disableAccel();gSensor.disableGyro();gSampling=false;gEstimator.reset();}
  }
  if(gSensorPresent&&gSampling&&uint32_t(now-gPollAt)>=15) {
    gLastPollGap=uint32_t(now-gPollAt);bool gap=gLastPollGap>500;gPollAt=now;
    uint8_t fifo[2]={};bool ok=gRead(0x15,fifo,2);
    int count=ok?GInstrument::FifoStatus::count(fifo[0],fifo[1]):-1;
    if(gap||count<0||count>32) {
      gLastFault=gap?1:!ok?2:count==-1?3:4;
      if(count==-2||count>32)++gOverflows;else ++gErrors;
      gSensor.resetFifo();gBatchClock.reset();gInvalidate();gState=gCalibration?3:5;
    }else if(count) {
      AccelerometerData a[32];GyroscopeData w[32];
      uint16_t n=gSensor.readFromFifo(a,32,w,32);
      if(!n) {
        gLastFault=5;++gErrors;gInvalidate();gBatchClock.reset();
        // Preserve real samples if this driver/chip FIFO combination stalls; diagnose it explicitly.
        if(gSensor.isDataReady()&&gSensor.readAccel(a[0])&&gSensor.readGyro(w[0])){n=1;++gFallbacks;gSensor.resetFifo();}
      }
      const float dt=gBatchClock.interval(now,n);gLastBatchSamples=n;gLastBatchDt=dt;
      if(n&&!dt){gLastFault=6;++gErrors;gInvalidate();gBatchClock.reset();gState=gCalibration?3:5;}
      if(n&&dt){if(uint32_t(now-gDataAt)>250)gInvalidate();gDataAt=now;}
      for(uint16_t i=0;i<n&&dt;i++) {
        GInstrument::Vec av{a[i].mps2.x/GInstrument::gravity,a[i].mps2.y/GInstrument::gravity,a[i].mps2.z/GInstrument::gravity};
        GInstrument::Vec wv{w[i].dps.x,w[i].dps.y,w[i].dps.z};
        gInstrumentSample(av,wv,now,dt,motion);
      }
    }
    if(uint32_t(now-gDataAt)>250){
      if(gEstimator.initialized||gEstimator.stable||gQuiet.pose.stable)gInvalidate();
      if(uint32_t(now-gDataAt)>1000)gState=5;
    }
  }
  bool valid=gSensorPresent&&gSampling&&!gCalibration&&gEstimator.available&&uint32_t(now-gDataAt)<=250&&!gSaturated;
  if(active&&gOutput.update(now,valid,gEstimator.lateral,gEstimator.longitudinal)&&recording) {
    uint8_t flags=(valid?1:0)|(gCalibration?2:0)|(gSaturated?4:0)|(!valid&&!gCalibration&&gSensorPresent&&!gEstimator.initialized?8:0)|(gState==5?16:0);
    gStream.frame(gStream.bytes,flags,now,valid?GInstrument::Output::milli(gOutput.lateral):0,valid?GInstrument::Output::milli(gOutput.longitudinal):0);gStream.pending=true;
  }
  gCpuUs+=micros()-cpuAt;
  if(active)gDiagnostic();
}

void gInstrumentSerialTick() {
  static char line[5]={};static unsigned length=0;static bool discard=false;
  for(unsigned n=0;n<16&&Serial.available();++n) {
    char c=Serial.read();if(c=='\r')continue;
    if(c=='\n') {
      if(!discard&&length==3&&!memcmp(line,"#GD",3)){gDiagnosticUntil=millis()+15000;gDiagnostic(true);}
      length=0;discard=false;
    }else if(length<sizeof(line)-1)line[length++]=c;else discard=true;
  }
}
