#ifdef NDEBUG
#undef NDEBUG
#endif
// Executes the production gesture and weather pages using an in-memory display.
#include <algorithm>
#include <cassert>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <iomanip>
#include <sstream>
#include <string>
#include <vector>
using std::min; using std::max;
struct String : std::string {
  using std::string::string; using std::string::operator=;
  String()=default; String(const std::string& s):std::string(s){}
  String(int n):std::string(std::to_string(n)){}
  String(unsigned n):std::string(std::to_string(n)){}
  String(float n,int places):std::string(format(n,places)){}
  static std::string format(double n,int p){std::ostringstream s;s<<std::fixed<<std::setprecision(p)<<n;return s.str();}
  void toCharArray(char* b,size_t n)const{if(n){std::strncpy(b,c_str(),n);b[n-1]=0;}}
  int toInt()const{return std::atoi(c_str());}
};
String operator+(const std::string& s,int n){return String(s+std::to_string(n));}
constexpr float PI=3.14159265358979323846f;
constexpr int LCD_WIDTH=466,LCD_HEIGHT=466,CX=233,WAIT_READY=1,WAIT_NOLINK=0;
constexpr int MALLOC_CAP_SPIRAM=1;
constexpr uint16_t C_BLACK=0,C_CYAN=0x07ff,C_WHITE=0xffff,C_GREY=0x8410,C_ORANGE=0xfd20,C_RED=0xf800,C_YELLOW=0xffe0;
template<class T> T constrain(T n,T lo,T hi){return min(hi,max(lo,n));}
uint32_t fakeNow=100;
unsigned long millis(){fakeNow+=5;return fakeNow;}
void* heap_caps_malloc(size_t n,int){return std::malloc(n);}
void xSemaphoreGive(int){}
int flushDone=0;
struct Canvas {
  uint16_t pixels[466*466]{};
  void fillScreen(uint16_t c){std::fill(pixels,pixels+466*466,c);}
  uint16_t* getFramebuffer(){return pixels;}
  void drawPixel(int x,int y,uint16_t c){if(x>=0&&x<466&&y>=0&&y<466)pixels[y*466+x]=c;}
  void drawFastHLine(int x,int y,int w,uint16_t c){fillRect(x,y,w,1,c);}
  void drawFastVLine(int x,int y,int h,uint16_t c){fillRect(x,y,1,h,c);}
  void drawCircle(int x,int y,int r,uint16_t c){for(int i=0;i<720;i++){float a=i*0.00872664626f;drawPixel(lroundf(x+r*cosf(a)),lroundf(y+r*sinf(a)),c);}}
  void drawLine(int x,int y,int xx,int yy,uint16_t c){int n=max(abs(xx-x),abs(yy-y));for(int i=0;i<=n;i++)drawPixel(n?x+(xx-x)*i/n:x,n?y+(yy-y)*i/n:y,c);}
  void fillRect(int x,int y,int w,int h,uint16_t c){for(int j=y;j<y+h;j++)for(int i=x;i<x+w;i++)drawPixel(i,j,c);}
  void fillRoundRect(int x,int y,int w,int h,int,uint16_t c){fillRect(x,y,w,h,c);}
  void drawRoundRect(int x,int y,int w,int h,int,uint16_t c){fillRect(x,y,w,h,c);}
  void fillTriangle(int ax,int ay,int bx,int by,int cx,int cy,uint16_t c){
    for(int y=min({ay,by,cy});y<=max({ay,by,cy});y++)for(int x=min({ax,bx,cx});x<=max({ax,bx,cx});x++){
      int a=(x-ax)*(by-ay)-(y-ay)*(bx-ax),b=(x-bx)*(cy-by)-(y-by)*(cx-bx),d=(x-cx)*(ay-cy)-(y-cy)*(ax-cx);
      if((a>=0&&b>=0&&d>=0)||(a<=0&&b<=0&&d<=0))drawPixel(x,y,c);
    }
  }
} canvas;
Canvas* gfx=&canvas;
struct Text {std::string value;int y;int x=0;};
std::vector<Text> text;
void printCentered(const std::string& s,int x,int y,int,uint16_t){text.push_back({s,y,x});}
void drawTextImg(int slot,int y,uint8_t){text.push_back({"bitmap-slot-"+std::to_string(slot),y});}
void aaDisc(float x,float y,float r,uint16_t c){for(int j=(int)(y-r);j<=y+r;j++)for(int i=(int)(x-r);i<=x+r;i++)if((i-x)*(i-x)+(j-y)*(j-y)<=r*r)canvas.drawPixel(i,j,c);}
uint16_t blend565(uint16_t a,uint16_t,int){return a;}
void drawRedRing(){}
void flushWait(){}
void flushAsync(){}
void drawNavFrame(){text.push_back({"navigation",0});}
void drawWaiting(int){text.push_back({"home",0});}
bool onWaitScreen=false,frameIsMap=false,bleConnected=true,bleAuthed=true,needFlush=false;
bool inNav=true,cruiseOn=false,callOn=false,pairOn=false,sliding=false,wxDirty=false;
int page=0,wxDetail=0,navDist=120,riderPrevF=0,riderPrevZ=0;
unsigned long pageAt=0;
bool musicDirty=false,musicHave=false,musicPlaying=false,hidMusicMode=false,musicLyrics=false,navDirty=false,catForce=false;
int musicAck=0,musicPressed=-1;
unsigned long musicAckUntil=0,hidTapAt=0;
String pendingEvt,navDir="L";
float rotCosF=1,rotSinF=0;
bool rotFree=false; int screenRot=0;
uint16_t* fbBuf[2]={nullptr,nullptr}; uint16_t* flushSrc=nullptr;
struct {int showW=0;} imgs[13];
struct {
  bool available=false;
  struct {bool known=false;int state=0;double elapsed=0,rate=1;} playback;
  unsigned long playbackAt=0;
  struct {String text;} values[4];
  int controlMask(){return 0;} bool controlReady(int){return false;} bool control(int){return false;}
} appleMedia;
namespace AppleMediaData { double duration(const char*){return 0;} }
bool hidMediaReady(){return false;}
struct {bool enqueue(int){return true;}} hidPulses;
#include "../boards/175/MotoNav/GInstrumentRuntime.h"
GInstrument::Estimator gEstimator;GInstrument::Output gOutput;int gState=0;
#include "../boards/175/MotoNav/FixedPageLayout.h"
#include "../boards/175/MotoNav/TouchLockBadge.h"
// v7.12.10-pages.175c.9 起分页点由 FixedPageLayout 共享实现（真画到内存画布上）。
void drawPageDots(){FixedPageLayout::drawPageDots(page,wxDetail,inNav);}
#include "../boards/175/MotoNav/src/pages/WeatherPage.h"
#include "../boards/175/MotoNav/src/pages/PageNavigation.h"

void reset(int p=0,int detail=0){
  page=p;wxDetail=detail;dragging=false;sliding=false;dragV=0;pageAt=fakeNow;
  text.clear();wxDirty=false;musicDirty=false;pendingEvt="";
}
void swipe(int dx,int dy,bool finish=true){
  dragMove(-dx,-dy,millis()); // The hardware has both axis flips enabled.
  if(finish)dragEnd();
}
bool has(const std::string& value){for(const auto& s:text)if(s.value==value)return true;return false;}
int main(){
  reset(3);gOutput.update(0,true,0.25f,0.5f);gState=2;drawGInstrument();
  assert(has("ACCEL 0.50g")&&has("R 0.25"));
  unsigned before=gScaleIndex;gInstrumentTap(316,86);assert(gScaleIndex==(before+1)%3);
  gInstrumentTap(146,86);assert(gOutput.count==0&&gOutput.accel==0);
  gOutput.update(100,false,0,0);gState=5;text.clear();drawGInstrument();assert(has("G DATA UNAVAILABLE"));

  // v7.12.10-pages.175c.9：G 仪表页提示点——右侧两个纵向点（下点高亮，G 在首页下方），
  // 不画底部横向点；首次显示、100ms 连续刷新、无数据重绘、换页返回后都在。
  auto dotAt=[&](int x,int y){return canvas.pixels[y*466+x];};
  auto gDotsVisible=[&](){
    assert(dotAt(438,224)==0x4208&&dotAt(438,242)==C_WHITE);
    assert(dotAt(213,444)==C_BLACK&&dotAt(233,444)==C_BLACK&&dotAt(253,444)==C_BLACK);
  };
  reset(3);gOutput.update(0,true,0.25f,0.5f);gState=2;text.clear();
  drawGInstrument();gDotsVisible();                                   // 首次显示
  { // 右侧峰值文字右缘收在 x=431，与纵向点(x≥435)不重叠
    const Text* r=nullptr;for(const auto&t:text)if(!r&&t.value.rfind("R ",0)==0)r=&t;
    assert(r&&r->x+(int)r->value.length()*6/2<=431);
  }
  fakeNow+=200;gInstrumentPageTick();gDotsVisible();                  // 持续刷新仍保留
  gOutput.update(0,false,0,0);gState=5;drawGInstrument();gDotsVisible(); // 无数据整屏重绘仍保留
  swipe(0,350);assert(page==0);swipe(0,-350);assert(page==3);
  fakeNow+=200;gInstrumentPageTick();gDotsVisible();                  // 换页返回后仍保留

  // v7.12.10-pages.175c.9：锁定徽标在左上 CX-44，与蓝牙点、电池（含充电标与三位百分比）
  // 以及状态栏局部刷新擦除矩形都不相交；先擦后画不留残影。
  const auto badge=TouchLockBadge::bounds(CX);
  auto disjoint=[&](int x0,int y0,int x1,int y1){
    return badge.x+badge.w-1<x0||x1<badge.x||badge.y+badge.h-1<y0||y1<badge.y;
  };
  assert(disjoint(CX-7,23,CX+7,37));    // 蓝牙点 (CX,30) r7
  assert(disjoint(CX+14,22,CX+60,40));  // 电池主体+充电标+“100”三位百分比
  assert(disjoint(CX-9,21,CX+67,39));   // 状态栏局部刷新擦除矩形不误擦徽标
  TouchLockBadge::draw(CX);
  assert(dotAt(CX-44,28)==C_YELLOW);
  TouchLockBadge::erase(CX);
  assert(dotAt(CX-44,28)==C_BLACK);

  // Every adjacent transition is reversible; outside edges are immovable.
  reset();swipe(350,0);assert(page==2);
  swipe(-350,0);assert(page==0);
  swipe(-350,0);assert(page==1&&wxDetail==0);
  swipe(0,350);assert(page==1&&wxDetail==1);
  swipe(0,350);assert(page==1&&wxDetail==1&&!dragging);
  swipe(350,0);assert(page==1&&wxDetail==1&&!dragging);
  swipe(0,-350);assert(page==1&&wxDetail==0);
  swipe(0,-350);assert(page==1&&wxDetail==2);
  swipe(0,-350);assert(page==1&&wxDetail==2&&!dragging);
  swipe(0,350);assert(page==1&&wxDetail==0);
  swipe(350,0);assert(page==0);
  swipe(0,350);assert(page==0&&!dragging);
  swipe(0,-350);assert(page==3);
  swipe(350,0);assert(page==3&&!dragging);
  swipe(0,-350);assert(page==3&&!dragging);
  swipe(0,350);assert(page==0);
  reset(2);swipe(350,0);assert(page==2&&!dragging);
  swipe(0,350);assert(page==2&&!dragging);

  // Preparing and cancelling a vertical drag must not change the actual detail.
  reset(1,0);swipe(0,24,false);assert(dragging&&wxDetail==0);
  dragV=0;dragEnd();assert(page==1&&wxDetail==0&&!sliding);
  reset(1,1);swipe(0,-80,false);dragAbort();assert(page==1&&wxDetail==1);

  // New warnings and screen taps never steal the selected weather page.
  reset(1,1);wxHave=true;
  parseWeatherExtra("#WX,42,1,3,2,123,0,40");assert(wxDetail==1&&wxDirty);
  weatherTap();assert(wxDetail==1);
  reset(1,0);parseWeatherExtra("#WX,42,2,4,2,124,0,40");assert(wxDetail==0);

  // Near a turn and after 15 seconds: user-selected pages remain visible.
  reset(2);fakeNow+=90000;musicTick();assert(page==2);
  reset(1,2);fakeNow+=90000;weatherTick();assert(page==1&&wxDetail==2);

  // Missing weather data retains the selected page and never invents no-rain.
  wxExtra=false;wxHave=false;reset(1,1);drawWeather();
  assert(has("RAIN / AIR")&&has("RAIN DATA UNAVAILABLE")&&!has("WEATHER"));
  reset(1,2);drawWeather();assert(has("ALERT DATA UNAVAILABLE"));
  wxExtra=true;wxHave=true;wxRainN=2;wxRain[0]=-1;wxRain[1]=-1;
  reset(1,1);drawWeather();assert(has("RAIN DATA UNAVAILABLE"));
  wxRain[0]=0;wxRain[1]=0;reset(1,1);drawWeather();
  assert(has("NEXT 2H  MAX 0.00 mm/5m"));
  wxRain[1]=40;reset(1,1);drawWeather();assert(has("NEXT 2H  MAX 0.40 mm/5m"));
  wxHave=false;wxExtra=false;reset(1,0);drawWeather();assert(has("WEATHER"));

  // Phone offline, no weather data: all five positions still remain accessible.
  bleConnected=false;bleAuthed=false;reset();swipe(-350,0);swipe(0,-350);
  assert(page==1&&wxDetail==2);swipe(0,350);swipe(350,0);swipe(350,0);assert(page==2);
  std::puts("PASS: fixed adjacency, gesture commit/cancel/abort, page persistence, offline access, and missing/rain/alert states");
}
