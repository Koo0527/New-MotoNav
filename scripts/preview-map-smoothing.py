#!/usr/bin/env python3
"""Synthetic SAME INPUT evidence using production Swift processing/C++ rasterRows.

Requires existing swiftc/clang++/Pillow. No SDK, device, network or coordinates.
AA is explicitly compiled on for review; firmware's default flag remains off.
"""
from pathlib import Path
import argparse, hashlib, json, subprocess, tempfile
from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--baseline', type=Path, default=Path('/private/tmp/motonav-smoothing-baseline'))
parser.add_argument('--output', type=Path, default=ROOT/'output/map-smoothing')
args = parser.parse_args()
out = args.output.resolve(); out.mkdir(parents=True, exist_ok=True)
scenes = ['dense-courtyard', 'river-bridge', 'parallel-roads', 'curved-park', 'tile-seam']
angles = [0, 17, 43, 90, 137]

# Deliberately synthetic, not screenshots. All four materials, buildings, holes,
# narrow separators and diagonal edges exist in each 2.4km-shaped test grid.
for n, name in enumerate(scenes):
    image = Image.new('RGB', (1200, 1200), '#f8f9fa'); d = ImageDraw.Draw(image)
    d.polygon([(0, 0), (250, 0), (380, 530), (250, 1200), (0, 1200)], fill='#8dbbea')
    d.ellipse((800, 650, 1320, 1230), fill='#70a878')
    d.line([(130, 1100), (470, 750), (600, 400), (1050, 160)], fill='white', width=18+n*2)
    d.line([(100, 540), (1100, 610)], fill='#f4b864', width=18)
    d.line([(520, 60), (570, 1120)], fill='white', width=12)
    d.line([(545, 60), (595, 1120)], fill='white', width=12)
    d.arc((380, 350, 1050, 1020), 175+n*5, 340, fill='white', width=13)
    # One pixel saw teeth on a large road: deterministic capture threshold noise.
    for x in range(410, 850, 11): d.point((x, 540+(x-100)*70//1000-9), fill='#f8f9fa')
    image.save(out/f'{name}-source-SYNTHETIC.png')
    raw = [0xff000000 | r<<16 | g<<8 | b for r,g,b in image.getdata()]
    import array
    (out/f'{name}.rgba').write_bytes(array.array('I',raw).tobytes())
    for patch in range(4):
        mask = Image.new('RGB',(600,600),'#f8f9fa'); md=ImageDraw.Draw(mask)
        for y in range(28+n*2,570,96):
            for x in range(30+patch*2,570,100):
                md.rectangle((x,y,x+56,y+60),fill='#ff00ff')
                md.rectangle((x+18,y+18,x+38,y+42),fill='#f8f9fa')
                md.rectangle((x+24,y-2,x+25,y),fill='#ff00ff')
        mr=[0xff000000 | r<<16 | g<<8 | b for r,g,b in mask.getdata()]
        (out/f'{name}-roof-{patch}.rgba').write_bytes(array.array('I',mr).tobytes())

SWIFT = r'''
import Foundation
import Darwin
let folder=URL(fileURLWithPath:CommandLine.arguments[1])
func load(_ name:String)->[UInt32] {
 let d=try! Data(contentsOf:folder.appendingPathComponent(name))
 return d.withUnsafeBytes{Array($0.bindMemory(to:UInt32.self))}
}
let names=["dense-courtyard","river-bridge","parallel-roads","curved-park","tile-seam"]
var records=[[String:Any]]()
for name in names {
 let raw=load(name+".rgba"),roofs=(0..<4).map{load(name+"-roof-\($0).rgba")}
 var durations=[Double](),result=Data(),indices=[UInt8]()
 for iteration in 0..<4 {
  let start=ProcessInfo.processInfo.systemUptime
  let base=MapGeo.classifyAmapBase(raw,w:1200,h:1200)
  let packet=MapGeo.encodeRaster(frameId:1,x0:0,y0:0,w:1200,h:1200,mmPerPx:2000,idx:base)
  var patches=[Int:Data]()
  for i in 0..<4 {patches[i]=try! FastBuildings.simplify(roofs[i])}
  result=FastBuildings.packet(base:packet,patches:patches)
  if iteration>0 {durations.append((ProcessInfo.processInfo.systemUptime-start)*1000)}
  indices=RasterPacket.decode(result)!
  assert(result.count<=480000 && indices.count==1440000 && indices.contains(1) && indices.contains(3))
 }
 try! Data(indices).write(to:folder.appendingPathComponent(name+"-TAG.idx"))
 try! result.write(to:folder.appendingPathComponent(name+"-TAG.bin"))
 records.append(["scene":name,"median_ms":durations.sorted()[1],"iterations_ms":durations,"bytes":result.count])
}
let json=try! JSONSerialization.data(withJSONObject:records,options:[.prettyPrinted,.sortedKeys])
try! json.write(to:folder.appendingPathComponent("TAG-processing.json"))
var usage=rusage();getrusage(RUSAGE_SELF,&usage)
let memory=try! JSONSerialization.data(withJSONObject:["peak_rss_bytes":usage.ru_maxrss,"host":ProcessInfo.processInfo.operatingSystemVersionString],options:[.prettyPrinted,.sortedKeys])
try! memory.write(to:folder.appendingPathComponent("TAG-host-memory.json"))
'''

with tempfile.TemporaryDirectory(prefix='motonav-smoothing-preview-') as tmp:
    tmp=Path(tmp)
    for tag, base in [('before', args.baseline), ('after', ROOT/'ios/MotoNav')]:
        main=tmp/'main.swift'; main.write_text(SWIFT.replace('TAG',tag))
        binary=tmp/tag
        subprocess.run(['swiftc','-O','-module-cache-path',str(tmp/'modules'),str(base/'MapGeo.swift'),str(base/'RasterProcessing.swift'),str(main),'-o',str(binary)],check=True)
        subprocess.run([str(binary),str(out)],check=True)

    # Reuse the existing game preview overlays (production palette/player/route/
    # destination/ring helpers), replacing only its procedural base with rasterRows.
    cpp=(ROOT/'firmware/tests/game_map_preview.cpp').read_text()
    renderer=(ROOT/'firmware/boards/175/MotoNav/src/map/RasterRenderer.h').read_text()
    rows=renderer[renderer.index('struct {'):renderer.index('static inline uint16_t vicePatchColor')]
    headers=ROOT/'firmware/boards/175/MotoNav'
    stub=r'''
#include <cstring>
#include <chrono>
#include <iostream>
#include "HEADER/RasterSmoothing.h"
constexpr int LCD_WIDTH=466,CX=233,MAP_PY=262;
float rasMpp=2,rasX0=0,rasY0=0;
int rasW=1200,rasH=1200,rasBW=75,themeIdx=1,viceBaseShift=13;
bool rasterBackValid=false,rasHasPal=false,rasterViceValid=false,rasterTilesValid=true;
int rasterFrame=1;
uint8_t *rasterBuf=nullptr,*rasterBackBuf=nullptr,*rasterTiles=nullptr;
uint16_t *rasterVice=nullptr;
RasterHeader rasterBackHeader{};
RasterHeader currentRasterHeader(){RasterHeader h{};h.frame=1;h.width=1200;h.height=1200;h.blocksWide=75;h.mm=2000;h.bytes=720000;return h;}
struct {int left[466],right[466];} mapCircleRows;
'''.replace('HEADER',str(headers))
    cpp=cpp.replace('int main(int argc,char **argv) {',stub+'\n'+rows+'\nint main(int argc,char **argv) {')
    cpp=cpp.replace('if(argc!=4&&argc!=5)return 2;','if(argc!=7)return 2;')
    start=cpp.index('  for(int y=0;y<W;y++)for(int x=0;x<W;x++) {',cpp.index('int main'))
    end=cpp.index('  float rx[]',start)
    setup=r'''
  themeIdx=theme;
  std::vector<uint8_t> linear(1440000),packed(720000),tiles(5625);
  std::ifstream input(argv[4],std::ios::binary);input.read((char*)linear.data(),linear.size());if(!input)return 3;
  if(std::string(argv[6])=="pure")std::fill(linear.begin(),linear.end(),0);
  for(int y=0;y<1200;y++)for(int x=0;x<1200;x++){
   uint32_t k=(((y>>4)*75+(x>>4))<<8)|((y&15)<<4)|(x&15);
   packed[k>>1]|=linear[y*1200+x]<<((k&1)*4);
  }
  rasterBuf=packed.data();rasterTiles=tiles.data();size_t cursor=0;
  rasterTileScan(rasterBuf,currentRasterHeader(),rasterTiles,cursor,6000);
  RM.fb=pixels.data();RM.cx=1200;RM.cy=-1200;RM.sc=.32;RM.cs=cosf(atof(argv[5])*PI/180);RM.sn=sinf(atof(argv[5])*PI/180);
  RM.pal[0]=p.base;RM.pal[1]=p.road;RM.pal[2]=p.park;RM.pal[3]=p.water;RM.pal[4]=RM.pal[6]=p.roof;RM.pal[5]=RM.pal[7]=p.outline;
  for(int y=0;y<466;y++) {float dy=y+.5f-CX;int half=abs(dy)<212?sqrtf(212*212-dy*dy):0;mapCircleRows.left[y]=CX-half;mapCircleRows.right[y]=CX+half;}
  auto t=std::chrono::steady_clock::now();
  for(int repeat=0;repeat<100;repeat++)rasterRows(0,466,1);
  std::cout<<std::chrono::duration<double,std::milli>(std::chrono::steady_clock::now()-t).count()/100<<"\n";
'''
    cpp=cpp[:start]+setup+cpp[end:]
    # Temporary source sits elsewhere; resolve includes from original source.
    cpp=cpp.replace('#include "../boards/175/MotoNav/',f'#include "{headers}/')
    font=ImageFont.truetype('/System/Library/Fonts/Supplemental/Arial.ttf',20)
    bench=[]
    for tag,flag in [('before',0),('after-default',0),('after',1)]:
        variant=cpp
        if tag=='before':
            old=(args.baseline/'RasterRenderer.h').read_text()
            oldrows=old[old.index('struct {'):old.index('static inline uint16_t vicePatchColor')]
            variant=variant.replace(rows,oldrows)
        (tmp/'preview.cpp').write_text(variant)
        binary=tmp/f'render-{tag}'
        subprocess.run(['clang++','-std=c++17','-O2','-Wno-unknown-attributes',f'-DMOTONAV_RASTER_SMOOTHING={flag}',str(tmp/'preview.cpp'),'-o',str(binary)],check=True)
        input_tag='after' if tag=='after-default' else tag
        pure=subprocess.check_output([str(binary),'1','0',str(tmp/'pure.ppm'),str(out/f'{scenes[0]}-{input_tag}.idx'),'43','pure'],text=True).strip()
        bench.append(dict(scene='pure-control',rotation=43,phase=tag,theme=1,night=0,render_ms=float(pure),iterations=100))
        for scene,angle in zip(scenes,angles):
            sheet=Image.new('RGB',(3*466,2*506+70),'#17181c'); ink=ImageDraw.Draw(sheet)
            for night in range(2):
                for theme,name in enumerate(['Vice City','GTA5','Cyberpunk'],1):
                    ppm=tmp/'render.ppm'
                    ms=subprocess.check_output([str(binary),str(theme),str(night),str(ppm),str(out/f'{scene}-{input_tag}.idx'),str(angle),'render'],text=True).strip()
                    bench.append(dict(scene=scene,rotation=angle,phase=tag,theme=theme,night=night,render_ms=float(ms),iterations=100))
                    sheet.paste(Image.open(ppm),((theme-1)*466,night*506+35))
                    ink.text(((theme-1)*466+10,night*506+8),f'{name} / {"night" if night else "day"} / {tag}',font=font,fill='white')
            ink.text((12,1020),f'SYNTHETIC {scene} / {angle} degrees / production processing + rasterRows / AA review compiled {flag}',font=font,fill='white')
            sheet.save(out/f'{scene}-{tag}.png')
    (out/'render-benchmark.json').write_text(json.dumps(bench,indent=2)+'\n')
    for scene in scenes:
        a=Image.open(out/f'{scene}-before.png');b=Image.open(out/f'{scene}-after.png')
        pair=Image.new('RGB',(a.width*2,a.height));pair.paste(a);pair.paste(b,(a.width,0));pair.save(out/f'{scene}-comparison.png')
        active=Image.open(out/f'{scene}-after-default.png');pair.paste(active,(a.width,0));pair.save(out/f'{scene}-default-comparison.png')
    closeup=Image.new('RGB',(1200,460),'#17181c');ink=ImageDraw.Draw(closeup)
    for column,(label,box) in enumerate([('roof courtyard',(260,120,340,200)),('road edge',(195,300,275,380)),('destination reference',(100,70,180,150))]):
        for row,tag in enumerate(['before','after']):
            im=Image.open(out/f'parallel-roads-{tag}.png').crop(box)
            closeup.paste(im.resize((200,200),Image.Resampling.NEAREST),(column*400+190,row*230+28))
            ink.text((column*400+8,row*230+4),f'{label} / {tag}',font=font,fill='white')
    closeup.save(out/'detail-SYNTHETIC.png')
manifest={"label":"SYNTHETIC, not SDK screenshots or real area validation","scenes":scenes,"rotations":angles,"raw_input_sha256":{p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in out.glob('*.rgba')},"source_sha256":{str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in [ROOT/'ios/MotoNav/MapGeo.swift',ROOT/'ios/MotoNav/RasterProcessing.swift',ROOT/'firmware/boards/175/MotoNav/src/map/RasterRenderer.h',headers/'RasterSmoothing.h']}}
manifest['baseline_sha256']={p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in [args.baseline/'MapGeo.swift',args.baseline/'RasterProcessing.swift',args.baseline/'RasterRenderer.h']}
(out/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
print(out)
