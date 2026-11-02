from pathlib import Path
import subprocess, tempfile
root = Path(__file__).resolve().parents[3]
base = root / 'firmware/boards/175/MotoNav'
source = (base / 'src/map/MapHud.h').read_text()
function = source[source.index('void drawMapLanes()'):]
stub = r'''
#include <cassert>
#include <cmath>
constexpr int CX=233;int laneN=0,navDist=0,drawn=0;
bool ringActive=false,hasCam=false;
void dimRect(int,int,int,int,int,int){}
void drawLanesAt(float,float,float,float){drawn++;}
'''
cases = r'''
int main(){
 for(int metres:{120,500,1500,5000}){
  navDist=metres;ringActive=metres<=500;laneN=4;drawn=0;
  drawMapLanes();assert(drawn==1); // SDK-provided lanes outlive the turn-ring window.
 }
 laneN=0;drawn=0;drawMapLanes();assert(drawn==0);
}
'''
with tempfile.TemporaryDirectory() as d:
 p=Path(d);(p/'main.cpp').write_text('#include <initializer_list>\n'+stub+function+cases)
 subprocess.run(['clang++','-std=c++17','-fsanitize=address,undefined',str(p/'main.cpp'),'-o',str(p/'test')],check=True)
 subprocess.run([str(p/'test')],check=True)
for file in ['src/pages/NavigationPage.h','src/map/NavigationMarkers.h']:
 assert 'laneN > 0 && ringActive' not in (base/file).read_text(), file+' still hides highway lanes or omits their obstacle'
print('PASS highway lanes: SDK lifetime independent of the 500m turn ring; HUD avoidance agrees')
