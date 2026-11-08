"""Analysis-only manually bounded lower casing trace; never used in detection."""
from pathlib import Path
from PIL import Image,ImageDraw
import json,csv
HERE=Path(__file__).resolve().parent;ROOT=HERE.parents[3]
f=ROOT/'output/map-edge-bridge/source-casing-prototype/06-mingbo'
s=ROOT/'output/map-edge-bridge/fresh-mingbo/06-mingbo'
a=Image.open(f/'source-sampled.png').convert('RGB');native=Image.open(s/'base.png').convert('RGB');proj=json.loads((s/'base.json').read_text());cols=proj['columns'];rows=proj['rows'];n=a.width
m=(f/'local-mask.idx').read_bytes();c=(f/'color-mask.idx').read_bytes()
def lum(rgb):return sum(x*w for x,w in zip(rgb,[30,59,11]))/100
def warm(rgb):r,g,b=rgb;return r>=g>b and (r-b)*100>r*18 and (g-b)*6>=r-b
result=[];canvas=a.crop((540,600,651,653)).resize((888,424));draw=ImageDraw.Draw(canvas)
for x in range(540,651):
 cy=round(642-(x-551)/3);ys=range(cy-3,cy+4)
 samples=[(lum(a.getpixel((x,y))),y,a.getpixel((x,y))) for y in ys if warm(a.getpixel((x,y)))]
 val,y,rgb=min(samples)
 # Exact native source cells in the 2m column footprint, around the traced band.
 left=(cols[x-1]+cols[x]+1)//2;right=(cols[x]+cols[x+1]+1)//2
 vals=[(lum(native.getpixel((xx,yy))),xx,yy,native.getpixel((xx,yy))) for xx in range(left,right) for yy in range(rows[cy-3],rows[cy+3]+1) if warm(native.getpixel((xx,yy)))]
 nv,nx,ny,nrgb=min(vals)
 result.append(dict(x=x,y=y,rgb=rgb,luminance=val,color=c[y*n+x],local=m[y*n+x],nativeRGB=nrgb,nativeLum=nv,nativeX=nx,nativeY=ny,observedDark=val<=196,nativeObservedDark=nv<=196))
 if val<=196:draw.rectangle(((x-540)*8,(y-600)*8,(x-540)*8+7,(y-600)*8+7),outline='magenta' if m[y*n+x] else 'cyan',width=2)
canvas.save(f/'lower-trace-recall.png')
with (f/'lower-trace-recall.csv').open('w') as file:
 w=csv.DictWriter(file,fieldnames=result[0].keys());w.writeheader();w.writerows(result)
summary=dict(columns=len(result),sampledDark=sum(v['observedDark'] for v in result),nativeDark=sum(v['nativeObservedDark'] for v in result),marked=sum(v['local'] for v in result),darkMissR=sum(v['observedDark'] and not v['color'] for v in result),darkMissThin=sum(v['observedDark'] and v['color'] and not v['local'] for v in result),nativeDarkSampleLost=sum(v['nativeObservedDark'] and not v['observedDark'] for v in result),minRGBCounts={})
from collections import Counter
summary['sampledDarkMarked']=sum(v['observedDark'] and v['local'] for v in result)
old=list(csv.DictReader((ROOT/'output/map-edge-bridge/near-road-source/mingbo/base-observed-lower-casing-trace.csv').open()))
summary['original87TraceLocalRecall']=sum(m[int(v['worldY'])*n+int(v['worldX'])] for v in old)
summary['minRGBCounts']={str(k):v for k,v in Counter(tuple(i['rgb']) for i in result).items()}
(f/'lower-trace-recall.json').write_text(json.dumps(summary,indent=2)+'\n');print(summary)
