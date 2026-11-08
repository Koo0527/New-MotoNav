"""Offline source road hue tones, not elevation. Never writes production/wire packets."""
from pathlib import Path
from PIL import Image,ImageDraw
import json,csv,hashlib,subprocess,tempfile
HERE=Path(__file__).resolve().parent;ROOT=HERE.parents[3]
IN=ROOT/'output/map-edge-bridge/source-casing-prototype'
OUT=ROOT/'output/map-edge-bridge/road-tones-prototype'

def hue(c):
 r,g,b=c
 if not(r>=g>b and (r-b)*100>r*18 and (g-b)*6>=r-b):return None
 return 60*(g-b)/(r-b)
def road(c):
 h=hue(c)
 return 1 if h is None else 8 if h<=42 else 9
def pack(c):return ((c[0]>>3)<<11)|((c[1]>>2)<<5)|(c[2]>>3)
def expand(c):return ((c>>11&31)*255//31,(c>>5&63)*255//63,(c&31)*255//31)
def image(idx,n,pal):
 im=Image.new('RGB',(n,n));im.putdata([pal[v] for v in idx]);return im

def main():
 OUT.mkdir(parents=True,exist_ok=True)
 with tempfile.TemporaryDirectory(prefix='motonav-tones-') as tmp:
  binary=Path(tmp)/'palette';subprocess.run(['c++','-std=c++11',str(HERE/'palette.cpp'),'-o',str(binary)],check=True)
  rows=[list(map(int,line.split())) for line in subprocess.check_output([str(binary)],text=True).splitlines()]
  row=next(v for v in rows if v[0]==2);base,standard,park,water,roof,outline=row[1:]
 # Derive two deliberately flat gray levels in the existing theme, all quantized RGB565.
 # Offline 8/9 are palette slots, not new material/protocol IDs.
 pal565=[base,standard,park,water,roof,outline,roof,outline,pack((198,202,202)),pack((112,122,122))]
 pal=[expand(c) for c in pal565];report={'label':'OFFLINE road colour categories, NOT height/z-order','palette565':pal565,'paletteRGB':pal,'sourceHueBoundary':42,'scenes':[]}
 for folder in sorted(IN.iterdir()):
  if not folder.is_dir() or not (folder/'baseline.idx').exists():continue
  name=folder.name;out=OUT/name;out.mkdir(exist_ok=True)
  src=Image.open(folder/'source-sampled.png').convert('RGB');n=src.width
  baseline=(folder/'baseline.idx').read_bytes();bounded=(folder/'local-final.idx').read_bytes();mask=(folder/'local-mask.idx').read_bytes()
  raw=list(src.get_flattened_data());ids=bytearray(bounded)
  for p,v in enumerate(ids):
   if v==1:ids[p]=road(raw[p])
  assert all(ids[p]==0 for p,v in enumerate(mask) if v)
  assert len(pal565)<=16 and max(ids)<len(pal565)
  current=image(baseline,n,pal);tones=image(ids,n,pal)
  current.save(out/'gta5-currentflat.png');tones.save(out/'gta5-tones.png');src.save(out/'source.png');(out/'offline-palette-slots.idx').write_bytes(ids)
  rois=[('overview-424',(388,388,812,812)),('main-highway-crossing',(510,560,690,690)),('ordinary-junction',(875,505,925,555)),('narrow-ramp',(640,640,710,700))] if name=='06-mingbo' else [('overview-424',(388,388,812,812)),('center-junction',(510,510,690,690))]
  if name!='06-mingbo':
   def white(x,y):
    r,g,b=raw[y*n+x];return min(r,g,b)>=254
   found=None
   for y in range(220,1000,3):
    if found:break
    for x in range(220,1000,3):
     if all(white(x+dx,y+dy) for dx,dy in [(0,0),(-6,0),(6,0),(0,-6),(0,6)]) and sum(white(x+dx,y+dy) for dx,dy in [(-8,-8),(8,-8),(-8,8),(8,8)])<=1:
      rect=(x-25,y-25,x+25,y+25)
      if not any(hue(raw[yy*n+xx]) is not None for yy in range(y-25,y+25) for xx in range(x-25,x+25)):
       found=rect;break
   if found:rois.append(('white-junction-negative',found))
  entry={'scene':name,'sourceSampleSHA256':hashlib.sha256((folder/'source-sampled.png').read_bytes()).hexdigest(),'tonePixels':{str(i):ids.count(i) for i in [1,8,9]},'markedCasing':sum(mask),'rois':[]}
  for label,rect in rois:
   scale=2 if label=='overview-424' else 5;w=(rect[2]-rect[0])*scale;h=(rect[3]-rect[1])*scale
   canvas=Image.new('RGB',(w*3,h+32),'white');draw=ImageDraw.Draw(canvas)
   for j,(im,title) in enumerate(zip([src,current,tones],['Source RGB','Current flat GTA5','Source road tones + existing casing'])):
    canvas.paste(im.crop(rect).resize((w,h),Image.Resampling.NEAREST),(j*w,32));draw.text((j*w+5,9),title,fill='black')
   canvas.save(out/(label+'-comparison.png'));entry['rois'].append({'label':label,'rect':rect,'beforeAfterDifferentPixels':sum(current.getpixel((x,y))!=tones.getpixel((x,y)) for y in range(rect[1],rect[3]) for x in range(rect[0],rect[2]))})
  if name=='06-mingbo':
   rect=(510,560,690,690);native=Image.open(folder/'main-highway-crossing-native-source.png').convert('RGB')
   native.save(out/'main-highway-crossing-native-source.png')
   w,h=900,650;canvas=Image.new('RGB',(w*3,h+32),'white');draw=ImageDraw.Draw(canvas)
   for j,(im,title) in enumerate(zip([native,current.crop(rect),tones.crop(rect)],['Native PNG source crop','Current flat GTA5','Source road tones + existing casing'])):
    canvas.paste(im.resize((w,h),Image.Resampling.NEAREST),(j*w,32));draw.text((j*w+5,9),title,fill='black')
   canvas.save(out/'main-highway-crossing-native-comparison.png')
  if name=='06-mingbo':
   with (out/'warm-source-frequency.csv').open('w') as f:
    from collections import Counter
    wr=csv.writer(f);wr.writerow(['R','G','B','hue','toneSlot','pixels'])
    for color,count in Counter(raw).most_common():
     if hue(color) is not None:wr.writerow([*color,round(hue(color),3),road(color),count])
  report['scenes'].append(entry)
 for c in [(247,195,107),(255,190,107),(255,195,99)]:assert road(c)==8
 for c in [(247,223,132),(255,231,156)]:assert road(c)==9
 for c in [(255,255,255),(190,190,190),(248,249,250)]:assert road(c)==1
 report['toolSHA256']={str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in [HERE/'tones.py',HERE/'palette.cpp']}
 report['productionSHA256']={str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in [ROOT/'ios/MotoNav/MapGeo.swift',ROOT/'firmware/boards/175/MotoNav/GameMapStyle.h']}
 (OUT/'report.json').write_text(json.dumps(report,indent=2)+'\n')
 print(OUT)
if __name__=='__main__':main()
