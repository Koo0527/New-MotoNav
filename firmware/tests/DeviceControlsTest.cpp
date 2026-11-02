#include <cassert>
#include <cstring>
#include <initializer_list>
#include "../boards/175/MotoNav/DeviceControls.h"
int main() {
 unsigned usb=0,battery=0;
 assert(DeviceControls::parsePower("#PS,600,120",usb,battery));
 for(const char *m : {"#PS,4294967356,120","#PS, 60,120","#PS,+60,120","#PS,-0,120","#PS,600,120x","#PS,600,","#PS,600,0"})assert(!DeviceControls::parsePower(m,usb,battery));
 DeviceControls touch;touch.asleep=true;
 assert(touch.touchGate(true,100)==2);assert(!touch.asleep);
 assert(touch.touchGate(false,150)==1);assert(touch.touchGate(true,160)==1);
 assert(touch.touchGate(false,241)==1);assert(touch.touchGate(true,250)==0);
 touch.locked=true;touch.asleep=true;assert(touch.touchGate(true,300)==1);assert(touch.asleep);
 touch.locked=false;touch.consumeTouch(350);assert(touch.touchGate(true,400)==1);
 assert(touch.touchGate(false,481)==1);assert(touch.touchGate(true,500)==2);
 DeviceControls c;
 for(const char *m : {"#TM,", "#TM,0", "#TM,0000,", "#TM,0000,5,5,0,", "#TM,0000,+5,5,0,0", "#TM,0000,5,5,0,-0"})assert(!c.receiveTheme(m));
 c.bootBegin(false,0);
 assert(c.bootPoll(true,10)==0); assert(c.bootPoll(true,39)==0);
 assert(c.bootPoll(true,40)==0); assert(c.bootPoll(false,100)==0);
 assert(c.bootPoll(false,130)==1); assert(c.tunnel && c.pending && c.revision==1);
 assert(c.receiveTheme("#TM,0000,200,70,0,0")); assert(c.tunnel && c.pending);
 assert(c.receiveTheme("#TM,0001,200,70,0,1")); assert(!c.pending && c.targetBrightness()==70 && c.night());
 assert(!c.receiveTheme("#TM,0001,200,70,0,1x")); assert(!c.receiveTheme("#TM,001,200,70,0,1"));
 assert(!c.receiveTheme("#TM,0001,256,70,0,1"));
 c.bootPoll(true,200);c.bootPoll(true,230);assert(c.bootPoll(true,1430)==2);assert(c.locked);
 c.bootPoll(false,1500);assert(c.bootPoll(false,1530)==0);
 c.asleep=true;c.bootPoll(true,1600);assert(c.bootPoll(true,1630)==3);assert(!c.asleep);
 assert(c.bootPoll(true,5000)==0);c.bootPoll(false,5100);assert(c.bootPoll(false,5130)==0);
 DeviceControls startup;startup.bootBegin(true,0);assert(startup.bootPoll(true,2000)==0);
 startup.bootPoll(false,2100);assert(startup.bootPoll(false,2130)==0);
 assert(c.setPower(0,240));assert(!c.setPower(1,240));assert(!c.setPower(600,300));
 assert(c.sleepDue(120000,0,true,false)==false);assert(c.sleepDue(240000,0,true,false));
 assert(!c.sleepDue(999999,0,false,false));assert(!c.sleepDue(999999,0,true,true));
 assert(DeviceControls::fadeStep(200,70)==168);assert(DeviceControls::fadeStep(60,70)==70);
}
