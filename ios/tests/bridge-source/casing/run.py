"""Offline native-source casing A/B. No production writes; requires existing Swift/Pillow."""
from pathlib import Path
from PIL import Image,ImageDraw
from collections import Counter
import subprocess,tempfile,json,hashlib,time,csv
HERE=Path(__file__).resolve().parent
ROOT=HERE.parents[3]
OUT=ROOT/'output/map-edge-bridge/source-casing-prototype'
SOURCE=ROOT/'ios/MotoNav/MapGeo.swift'
ROIS=json.loads((HERE.parent/'mingbo-rois.json').read_text())

def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def expand(v):return ((v>>11&31)*255//31,(v>>5&63)*255//63,(v&31)*255//31)
def render(idx,size,pal):
    im=Image.new('RGB',(size,size));im.putdata([pal[v] for v in idx]);return im

def main():
    OUT.mkdir(parents=True,exist_ok=True)
    original=SOURCE.read_text()
    modified=original.replace('private static func recoverGrayRoads(', 'static func recoverGrayRoads(')
    marker='static func smoothGameRaster(_ source: [UInt8], w: Int, h: Int) -> [UInt8] {'
    assert modified.count(marker)==1
    modified=modified.replace(marker,'static func smoothGameRaster(_ source: [UInt8], w: Int, h: Int, protected: [UInt8]? = nil) -> [UInt8] {')
    marker='guard source[p] == PX_BLOCK, out[p] == PX_BLOCK else { continue }'
    assert modified.count(marker)==1
    modified=modified.replace(marker,'guard source[p] == PX_BLOCK, out[p] == PX_BLOCK, protected?[p] != 1 else { continue }')
    (OUT/'MapGeo-offline.swift').write_text(modified)
    # Execute the real palette function; MapState's legacy THEMES rows are overridden.
    with tempfile.TemporaryDirectory(prefix='motonav-palette-') as tmp:
        binary=Path(tmp)/'palette'
        subprocess.run(['c++','-std=c++11',str(HERE/'palette.cpp'),'-o',str(binary)],check=True)
        palettes={}
        for line in subprocess.check_output([str(binary)],text=True).splitlines():
            theme,*colors=map(int,line.split());palettes[str(theme)]=[expand(v) for v in colors]
    scenes=[ROOT/'output/map-edge-bridge/fresh-mingbo/06-mingbo']+sorted((ROOT/'output/map-edge-bridge/fresh-default-five').glob('*'))
    report={'productionSHA256':sha(SOURCE),'paletteSourceSHA256':sha(ROOT/'firmware/boards/175/MotoNav/GameMapStyle.h'),'paletteRGB':palettes,'scenes':[],'modifiedProduction':False}
    with tempfile.TemporaryDirectory(prefix='motonav-casing-') as td:
        td=Path(td);copy=td/'MapGeo.swift';copy.write_text(modified)
        subprocess.run(['swiftc','-O','-module-cache-path',str(td/'modules'),str(copy),str(HERE/'Casing.swift'),str(HERE/'main.swift'),str(ROOT/'ios/MotoNav/RasterProcessing.swift'),'-o',str(td/'run')],check=True)
        for scene in scenes:
            raw=scene/'base-sampled-2m.argb32le'
            if not raw.exists():continue
            name=scene.name;folder=OUT/name;folder.mkdir(exist_ok=True)
            n=int((raw.stat().st_size//4)**.5);assert n*n*4==raw.stat().st_size
            info=json.loads(subprocess.run([str(td/'run'),str(raw),str(folder),str(n)]+([str(scene)] if name=='06-mingbo' else []),check=True,capture_output=True,text=True).stdout)
            info.update(scene=name,rawSHA256=sha(raw),size=n)
            info['buildingRawSHA256']={str(q):sha(scene/f'building-{q}-sampled-2m.argb32le') for q in range(4)} if name=='06-mingbo' else {}
            b=raw.read_bytes();rgb=Image.frombytes('RGBA',(n,n),b,'raw','BGRA').convert('RGB');rgb.save(folder/'source-sampled.png')
            stages={k:(folder/(k+'.idx')).read_bytes() for k in ['baseline','color-mask','color-final','local-mask','local-final','local-unprotected']}
            for mode in ['color','local']:
                mask=stages[mode+'-mask']; info[mode]['sourceColors']=Counter(rgb.getpixel((p%n,p//n)) for p,v in enumerate(mask) if v).most_common(24)
                info[mode]['removedByColumnMax']=max(sum(stages['baseline'][y*n+x]==1 and stages[mode+'-final'][y*n+x]==0 for y in range(n)) for x in range(n))
                # A marked pixel deep inside a dark warm patch would indicate deleting pavement.
                info[mode]['solid3x3Marks']=sum(mask[p] and all(mask[p+dy*n+dx] for dy in [-1,0,1] for dx in [-1,0,1]) for y in range(1,n-1) for x in range(1,n-1) for p in [y*n+x])
            if name=='06-mingbo':
                native=Image.open(scene/'base.png').convert('RGB');proj=json.loads((scene/'base.json').read_text())
                with (folder/'source-marks.csv').open('w') as file:
                    writer=csv.writer(file);writer.writerow(['x','y','r','g','b','colorMask','localMask','localFinal','buildingFinal'])
                    built=(folder/'local-buildingfull.idx').read_bytes()
                    for p,v in enumerate(stages['color-mask']):
                        if v:writer.writerow([p%n,p//n,*rgb.getpixel((p%n,p//n)),v,stages['local-mask'][p],stages['local-final'][p],built[p]])
                for roi in ROIS:
                    rect=roi['rect'];x0,y0,x1,y1=rect
                    native.crop((proj['columns'][x0],proj['rows'][y0],proj['columns'][x1-1]+1,proj['rows'][y1-1]+1)).save(folder/(roi['name']+'-native-source.png'))
                    marked=rgb.crop(rect)
                    for y in range(y0,y1):
                        for x in range(x0,x1):
                            p=y*n+x
                            if stages['color-mask'][p]:marked.putpixel((x-x0,y-y0),(255,0,255) if stages['local-mask'][p] else (0,255,255))
                    marked.resize((marked.width*5,marked.height*5),Image.Resampling.NEAREST).save(folder/(roi['name']+'-source-marks.png'))
            for theme in [1,2,3]:
                ims=[rgb]+[render(stages[k],n,palettes[str(theme)]) for k in ['baseline','color-final','local-final']]
                for k,im in zip(['source','baseline','color','local'],ims):
                    if k != 'source':im.save(folder/f'theme{theme}-{k}.png')
                if name=='06-mingbo':
                    for roi in ROIS:
                        rect=roi['rect'];rw=rect[2]-rect[0];rh=rect[3]-rect[1]
                        canvas=Image.new('RGB',(rw*4*4,rh*4+30),'white');draw=ImageDraw.Draw(canvas)
                        for j,(im,label) in enumerate(zip(ims,['Source RGB','Before','A color only','B local thin + protect'])):
                            canvas.paste(im.crop(rect).resize((rw*4,rh*4),Image.Resampling.NEAREST),(j*rw*4,30));draw.text((j*rw*4+4,8),label,fill='black')
                        canvas.save(folder/f'{roi["name"]}-theme{theme}.png')
            if name=='06-mingbo':
                built=(folder/'local-buildingfull.idx').read_bytes()
                for roi in ROIS:
                    rect=roi['rect'];rw=rect[2]-rect[0];rh=rect[3]-rect[1]
                    baseIm=render(stages['local-final'],n,palettes['2'])
                    pal=palettes['2'][:4]+palettes['2'][4:6]*2
                    builtIm=render(built,n,pal)
                    canvas=Image.new('RGB',(rw*4*3,rh*4+30),'white');draw=ImageDraw.Draw(canvas)
                    marked=rgb.copy()
                    for p,v in enumerate(stages['local-mask']):
                        if v and built[p]>=4:marked.putpixel((p%n,p//n),(255,0,255))
                    for j,(im,label) in enumerate(zip([baseIm,builtIm,marked],['B protected base','Actual buildingfull merge','Magenta = casing overwritten'])):
                        canvas.paste(im.crop(rect).resize((rw*4,rh*4),Image.Resampling.NEAREST),(j*rw*4,30));draw.text((j*rw*4+4,8),label,fill='black')
                    canvas.save(folder/f'{roi["name"]}-building-overlay.png')
                info['rois']=[]
                for roi in ROIS:
                    x0,y0,x1,y1=roi['rect'];ids=[y*n+x for y in range(y0,y1) for x in range(x0,x1)]
                    info['rois'].append(dict(roi,counts={k:sum(stages[k][p] == 1 for p in ids) for k in stages}))
                info['probes']=[]
                for x,y in [(612,591),(612,593),(612,596),(612,619),(612,621),(612,624),(615,620)]:
                    p=y*n+x;info['probes'].append(dict(x=x,y=y,rgb=rgb.getpixel((x,y)),stages={k:v[p] for k,v in stages.items()}))
            report['scenes'].append(info)
            print(name,info['local'],flush=True)
    assert sha(SOURCE)==report['productionSHA256']
    report['toolSHA256']={p.name:sha(p) for p in [HERE/'run.py',HERE/'Casing.swift',HERE/'main.swift',HERE/'palette.cpp']}
    (OUT/'report.json').write_text(json.dumps(report,indent=2)+'\n')

if __name__=='__main__':main()
