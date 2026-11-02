#pragma once
#include "../../TouchLockBadge.h"
uint32_t controlFeedbackUntil=0;
// Only the main loop touches panel/state; BLE callbacks continue queueing while asleep.
void controlCancelGestures() {
  dragAbort(); sliding=false; dragging=false;
  touchDown=false;touchHold=0;touchHoldAt=0;touchEat=false;
  musicPressed=-1;musicDirty=true;
  if(pendingEvt.startsWith("T,"))pendingEvt="";
  deviceControls.consumeTouch(millis());
}
void controlWake() {
  deviceControls.wake();controlWakeFrame=true;
  idlePowerOffReset(&idlePowerOffTimer,millis());
  navDirty=true;wxDirty=true;musicDirty=true;
  controlCancelGestures();
  // Keep the panel black until the current page has been composed and flushed.
  if(flushDone)xSemaphoreTake(flushDone,portMAX_DELAY);
  panel->displayOn();panel->setBrightness(0);controlBrightness=0;
  if(flushDone)xSemaphoreGive(flushDone);
}
bool controlTouchGate(bool down,uint32_t now) {
  const int action=deviceControls.touchGate(down,now);
  if(action==2)controlWake();
  if(action)return false;
  if(down)idlePowerOffReset(&idlePowerOffTimer,now);
  return true;
}

void controlBootTick() {
  if(controlFeedbackUntil && int32_t(controlFeedbackUntil-millis())<=0) {controlFeedbackUntil=0;controlWakeFrame=true;}
  const int event=deviceControls.bootPoll(digitalRead(0)==LOW,millis());
  if(event)idlePowerOffReset(&idlePowerOffTimer,millis());
  if(event==2){controlCancelGestures();controlWakeFrame=true;controlFeedbackUntil=millis()+1000;}
  if(event==3)controlWake();
}
void controlSleep() {
  controlCancelGestures();
  if(flushDone)xSemaphoreTake(flushDone,portMAX_DELAY);
  deviceControls.asleep=true;deviceControls.dirty=true;
  panel->setBrightness(0);panel->displayOff();controlBrightness=0;
  if(flushDone)xSemaphoreGive(flushDone);
  needFlush=false;
}

#include "../../AxpPowerKey.h"
AxpPowerKey controlPowerKey;
bool controlPmuWrite(uint8_t reg,uint8_t value) {
  Wire.beginTransmission(PMU_ADDR);Wire.write(reg);Wire.write(value);
  return Wire.endTransmission()==0;
}
void controlPowerKeyBegin() {
  Serial.printf("PWR short-press %s\n",controlPowerKey.begin(pmuRead,controlPmuWrite)?"ready":"unavailable");
}
void controlPowerKeyTick() {
  static uint32_t lastPoll=0;
  const uint32_t now=millis();
  if(uint32_t(now-lastPoll)<40)return;
  lastPoll=now;
  if(!controlPowerKey.poll(pmuRead,controlPmuWrite))return;
  deviceControls.powerShortPress();
  idlePowerOffReset(&idlePowerOffTimer,now);
  if(deviceControls.asleep)controlSleep();else controlWake();
  Serial.printf("PWR short-press: screen %s\n",deviceControls.asleep?"off":"on");
}
void controlApplyTheme() {
  const bool night=deviceControls.night();
  if(nightOn!=night){cancelPendingRaster();nightOn=night;navDirty=true;}
}
void controlFadeTick() {
  if(deviceControls.asleep || controlWakeFrame || millis()-controlFadeAt<100)return;
  const int next=DeviceControls::fadeStep(controlBrightness,deviceControls.targetBrightness());
  if(next==controlBrightness)return;
  if(flushDone)xSemaphoreTake(flushDone,portMAX_DELAY);
  panel->setBrightness(next);controlBrightness=next;controlFadeAt=millis();
  if(flushDone)xSemaphoreGive(flushDone);
}
void controlPowerStatus() {
  pendingPowerStatus=String("PS,")+deviceControls.usbSeconds+","+deviceControls.batterySeconds;
}
bool controlCommand(const String &m) {
  if(m=="#CTL" || m=="#CTL?"){deviceControls.dirty=true;return true;}
  if(m.startsWith("#TM,")) {
    deviceControls.receiveTheme(m.c_str());controlApplyTheme();return true;
  }
  if(m=="#PS" || m=="#PS?"){controlPowerStatus();return true;}
  if(m.startsWith("#PS,")) {
    unsigned usb=0,battery=0;
    if(DeviceControls::parsePower(m.c_str(),usb,battery)) {
      if(usb!=deviceControls.usbSeconds || battery!=deviceControls.batterySeconds) {
        Preferences pr;
        if(pr.begin("motonav",false)) {
          // One packed value avoids a partially saved settings pair.
          if(pr.putUInt("powersave",(usb<<16)|battery)==sizeof(uint32_t)) {
            deviceControls.setPower(usb,battery);
            idlePowerOffReset(&idlePowerOffTimer,millis());
          }
          pr.end();
        }
      }
    }
    controlPowerStatus();return true;
  }
  return false;
}
void controlSessionTick() {
  static uint32_t epoch=0;
  if(epoch!=mediaConnectionEpoch) {
    epoch=mediaConnectionEpoch;deviceControls.themeSession=false;deviceControls.dirty=true;
  }
}
void controlSendStatus() {
  if(!txChar || !bleConnected || !bleAuthed)return;
  if(deviceControls.dirty) {
    char status[24];snprintf(status,sizeof(status),"CTL,%04X,%d,%d,%d,%d",
      deviceControls.revision,deviceControls.tunnel,deviceControls.locked,deviceControls.asleep,deviceControls.pending);
    txChar->setValue((uint8_t*)status,strlen(status));txChar->notify();deviceControls.dirty=false;
  }
  if(pendingPowerStatus.length()) {
    txChar->setValue((uint8_t*)pendingPowerStatus.c_str(),pendingPowerStatus.length());txChar->notify();pendingPowerStatus="";
  }
}

void controlDrawLock() {
  const bool feedback=controlFeedbackUntil && int32_t(controlFeedbackUntil-millis())>0;
  if(!needFlush && !feedback)return;
  // v7.12.10-pages.175c.9：锁定徽标移到左上 CX-44，与蓝牙点、电池和百分比让出间距；
  // 先擦后画——锁定时画徽标，解锁时仅擦除，整屏重绘即使被跳过也不留残影。
  // 状态栏局部刷新的擦除矩形（CX-9 起）在徽标右侧，不会再误擦锁图标。
  TouchLockBadge::erase(CX);
  if(deviceControls.locked) TouchLockBadge::draw(CX);
  needFlush=true;
  if(feedback) {
    gfx->fillRoundRect(CX-100,46,200,28,6,C_BLACK);
    printCentered(deviceControls.locked?"TOUCH LOCKED":"TOUCH UNLOCKED",CX,52,2,C_YELLOW);
    needFlush=true;
  }
}
