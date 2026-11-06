#!/usr/bin/env python3
import pathlib, subprocess, sys, tempfile
root=pathlib.Path(__file__).resolve().parents[3]
s=(root/'firmware/boards/175/MotoNav/src/display/DisplayPipeline.h').read_text()
body=s[s.index('void flushWait()'):s.index('void initDoubleBuffer()')]
page=(root/'firmware/boards/175/MotoNav/src/pages/PageNavigation.h').read_text()
selftest=(root/'firmware/boards/175/MotoNav/RenderSelfTest.h').read_text()
page_wait=next(line.strip().split('//')[0] for line in page.splitlines() if 'flushWait(); xSemaphoreGive(flushDone)' in line)
self_wait=[line.strip() for line in selftest.splitlines() if 'flushWait();xSemaphoreGive(flushDone)' in line]
assert len(self_wait)==2

code=r'''
#include <cassert>
#include <initializer_list>
#include <stdexcept>
#define pdMS_TO_TICKS(x) (x)
#define pdTRUE 1
int flushDone=1,flushReq=2,results[8],pos,givesDone,givesReq,waits[8],nwaits;
int xSemaphoreTake(int,int ms){waits[nwaits++]=ms;return results[pos++];}
void xSemaphoreGive(int x){if(x==flushDone) ++givesDone; else ++givesReq;}
bool fastFlushOn=false;
void saveAndRestart(const char*,int,bool){throw std::runtime_error("restart");}
struct {void println(const char*){}} Serial;
struct {void restart(){throw std::runtime_error("restart");}} ESP;
void delay(int){}
int helperTask; void vTaskPrioritySet(int,int){}
struct {bool asleep=false;} deviceControls;
int pixels[2],*fbBuf[2]={&pixels[0],&pixels[1]},fbCur=1,*flushSrc=&pixels[0];
struct G {void flush(){} void setFramebuffer(int*){}} graphics,*gfx=&graphics;
'''+body+'\nvoid pageWait(){'+page_wait+'}\n'+''.join('void selfWait%d(){%s}\n'%(i,line) for i,line in enumerate(self_wait))+r'''
void reset(){pos=givesDone=givesReq=0;nwaits=0;fbCur=1;flushSrc=&pixels[0];for(auto &v:results)v=0;}
int main(){
 reset();try{flushAsync();assert(false);}catch(...){assert(givesReq==0 && fbCur==1 && flushSrc==&pixels[0] && givesDone==0);assert(waits[0]+waits[1]<=4000);}
 reset();results[1]=1;flushAsync();assert(givesReq==1 && fbCur==0);
 reset();try{flushSync();assert(false);}catch(...){assert(givesReq==0 && givesDone==0);}
 reset();results[0]=1;try{flushSync();assert(false);}catch(...){assert(givesReq==1 && givesDone==0);}
 reset();results[0]=results[2]=1;flushSync();assert(givesReq==1 && givesDone==1);
 for(auto caller : {pageWait,selfWait0,selfWait1}) {reset();try{caller();assert(false);}catch(...){assert(givesDone==0);} reset();results[1]=1;caller();assert(givesDone==1);}
 reset();fastFlushOn=true;try{flushAsync();assert(false);}catch(...){assert(givesReq==0 && fbCur==1);}fastFlushOn=false;
}
'''
with tempfile.TemporaryDirectory() as d:
 p=pathlib.Path(d);(p/'test.cpp').write_text(code)
 subprocess.run(['c++','-std=c++17',str(p/'test.cpp'),'-o',str(p/'test')],check=True)
 subprocess.run([str(p/'test')],check=True)
print('production flush ownership regression passed')
subprocess.run([sys.executable, str(pathlib.Path(__file__).with_name('fastpush_check.py'))], check=True)
subprocess.run([sys.executable, str(pathlib.Path(__file__).with_name('panel_ownership_check.py'))], check=True)
