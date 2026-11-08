#include <algorithm>
#include <cassert>
#include <cstdio>
#include <string>
#include <vector>
#include "../../boards/175/MotoNav/src/protocol/AckFifo.h"
using String=std::string;
String operator+(String s,int n){return s+std::to_string(n);}
struct Tx {
 String value;std::vector<String> sent;
 void setValue(uint8_t *p,size_t n){value.assign(reinterpret_cast<char*>(p),n);}
 void notify(){sent.push_back(value);}
} tx;
Tx *txChar=&tx;
bool bleConnected=true,bleAuthed=false,pendingBuildingCapability=true,hidMusicMode=false,musicLyrics=false;
int authNotifies=0;unsigned long bleAuthAt=0,now=500;
unsigned long millis(){return now;}
String pendingInstrumentStatus,pendingHidStatus,pendingLyricsStatus,pendingMediaStatus,pendingBootAck,pendingStat2,pendingProf,pendingBat,pendingEvt,pendingGStreamStatus;
AckFifo pendingAck;
struct {bool dirty=false;} deviceControls;
void controlSendStatus(){}void controlPowerStatus(){}void gInstrumentNotify(){}
bool hidMediaReady(){return false;}
struct {void resend(){}int controlMask(){return 0;}bool nextFrame(uint8_t*,size_t&,unsigned long){return false;}} appleMedia;
#include "../../boards/175/MotoNav/src/connectivity/Notifications.h"
int mpal2(){return std::count(tx.sent.begin(),tx.sent.end(),"CAP,MPAL,2");}
int mpal(){return std::count(tx.sent.begin(),tx.sent.end(),"CAP,MPAL,1");}
int main(){
 sendPendingAck();assert(tx.sent.empty() && authNotifies==0 && pendingBuildingCapability);
 bleAuthed=true;bleConnected=false;sendPendingAck();assert(tx.sent.empty());
 bleConnected=true;sendPendingAck();assert(mpal()==2 && authNotifies==1 && !pendingBuildingCapability);
 now=1600;sendPendingAck();assert(mpal()==3 && authNotifies==2);
 now=4100;sendPendingAck();assert(mpal()==4 && authNotifies==3);
 sendPendingAck();assert(mpal()==4);
 pendingBuildingCapability=true;sendPendingAck();assert(mpal()==5 && !pendingBuildingCapability);
 bleAuthed=false;pendingBuildingCapability=true;sendPendingAck();assert(mpal()==5 && pendingBuildingCapability);
 assert(mpal2()==mpal());
 puts("PASS production MPAL authenticated retries, capability query resend, exact 10-byte notification and disconnected/auth gating");
}
