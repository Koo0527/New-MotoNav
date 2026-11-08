"""B: retain measured stable pavement tones; offline, no production writes."""
from pathlib import Path
from PIL import Image, ImageDraw, ImageFilter
from collections import Counter
import csv, hashlib, json, platform, statistics, subprocess, tempfile, time
ROOT=Path(__file__).resolve().parents[3]; HERE=Path(__file__).resolve().parent
OUT=ROOT/'output/map-edge-bridge/road-multitone-preview'; N=1200

def pack(c):return ((c[0]>>3)<<11)|((c[1]>>2)<<5)|(c[2]>>3)
def expand(c):return ((c>>11&31)*255//31,(c>>5&63)*255//63,(c&31)*255//31)
def lum(c):return (30*c[0]+59*c[1]+11*c[2])/100
def family(c):return 8 if lum(c)<214 else 9 if lum(c)<226 else 11

def candidate(src,original):
    raw=list(src.get_flattened_data()); ids=bytearray(original)
    eligible=Image.frombytes('L',src.size,bytes(255 if v in (8,9) else 0 for v in original))
    core=eligible.filter(ImageFilter.MinFilter(3)).tobytes()
    spans=[bytes(b-a for a,b in zip(ch.filter(ImageFilter.MinFilter(3)).tobytes(),ch.filter(ImageFilter.MaxFilter(3)).tobytes())) for ch in src.split()]
    stable=bytes(255 if m and max(spans[k][p] for k in range(3))<=12 else 0 for p,m in enumerate(core))
    labels=bytearray(family(c) if stable[p] else 0 for p,c in enumerate(raw))
    # Only propagate a measured core family within two sampled pixels; never grow road geometry.
    for _ in range(2):
        before=labels[:]
        for p,v in enumerate(original):
            if v not in (8,9) or before[p] or p<N or p>=N*(N-1) or p%N in (0,N-1):continue
            votes=Counter(before[p+d] for d in (-N-1,-N,-N+1,-1,1,N-1,N,N+1) if before[p+d])
            if votes:
                winner,count=votes.most_common(1)[0]
                if count>=3:labels[p]=winner
    for p,v in enumerate(labels):
        if v:ids[p]=v
    assert all(a==b for a,b in zip(ids,original) if b not in (8,9))
    assert all(ids[p]==10 for p,v in enumerate(original) if v==10)
    assert all(labels[p]==11 for p,v in enumerate(ids) if v==11)
    assert set(ids)<=set(range(12))
    return ids,stable,labels

def rle_size(ids):
    runs=[];last=None;n=0
    for v in ids:
        if v!=last:
            if n:runs.append(n)
            last=v;n=0
        n+=1
    if n:runs.append(n)
    return 48+sum(2*(n//271)+(0 if n%271==0 else 1 if n%271<=15 else 2) for n in runs)

def render(ids,pal):
    im=Image.frombytes('P',(N,N),bytes(ids));im.putpalette([x for c in pal for x in expand(c)]+[0]*(768-len(pal)*3));return im.convert('RGB')

def sheet(images,titles,rect,scale,path):
    w=(rect[2]-rect[0])*scale;h=(rect[3]-rect[1])*scale
    canvas=Image.new('RGB',(w*3,h+32),'white');d=ImageDraw.Draw(canvas)
    for col,(im,title) in enumerate(zip(images,titles)):
        canvas.paste(im.crop(rect).resize((w,h),Image.Resampling.NEAREST),(col*w,32));d.text((col*w+8,10),title,fill='black')
    canvas.save(path)

def main():
    OUT.mkdir(parents=True,exist_ok=True)
    sources=['ios/MotoNav/MapGeo.swift','ios/MotoNav/RasterProcessing.swift','ios/MotoNav/RoadPalette.swift','firmware/boards/175/MotoNav/GameMapStyle.h']
    hashes={p:hashlib.sha256((ROOT/p).read_bytes()).hexdigest() for p in sources}
    manifest=json.loads((ROOT/'output/map-edge-bridge/road-palette-qa/source-manifest.json').read_text())
    assert all(hashes[p]==manifest[p] for p in sources), 'Existing QA masks must match production sources'
    with tempfile.TemporaryDirectory(prefix='motonav-multitone-') as td:
        td=Path(td)
        subprocess.run(['c++','-std=c++11','-O2',str(HERE/'palette.cpp'),'-o',str(td/'pal')],check=True)
        palettes=[list(map(int,line.split())) for line in subprocess.check_output([str(td/'pal')],text=True).splitlines()]
        subprocess.run(['swiftc','-O','-module-cache-path',str(td/'modules'),*[str(ROOT/p) for p in sources[:3]],str(HERE/'main.swift'),'-o',str(td/'check')],check=True)
        subprocess.run([str(td/'check'),str(ROOT),str(OUT)],check=True)
    report={'method':{'luminance':'0.30R + 0.59G + 0.11B','stableCore':'3x3 warm-only mask, RGB channel max-min <=12','warmLuminanceBoundaries':[214,226],'propagation':'2 rounds, >=3 neighboring labels, only original warm-road pixels','offlineSlots':[1,8,9,11],'roadElevationInferred':False},'meaning':'source road color families, NOT height or z-order','host':platform.platform(),'productionHashes':hashes,'timingCaution':'Swift full production classify vs Python additional stable-tone stage: different scopes/languages, not a speed ratio; host only, no device measurements','scenes':[]}
    for name,base in [('06-mingbo','fresh-mingbo'),('04-interchange','fresh-default-five')]:
        out=OUT/name;out.mkdir(exist_ok=True)
        folder=ROOT/'output/map-edge-bridge'/base/name;qa=ROOT/'output/map-edge-bridge/road-palette-qa'/name
        data=(folder/'base-sampled-2m.argb32le').read_bytes();assert len(data)==N*N*4
        source=Image.frombytes('RGBA',(N,N),data,'raw','BGRA').convert('RGB')
        # Same RGB565 display quantization for source and both themed columns.
        source565=Image.new('RGB',source.size);source565.putdata([expand(pack(c)) for c in source.get_flattened_data()]);source565.save(out/'source-rgb565.png')
        original=(qa/'building.idx').read_bytes();assert len(original)==N*N
        start=time.perf_counter();ids,stable,labels=candidate(source,original);elapsed=(time.perf_counter()-start)*1000
        (out/'candidate-offline.idx').write_bytes(ids)
        entry={'scene':name,'sourceSHA256':hashlib.sha256(data).hexdigest(),'pythonAdditionalStageHostMilliseconds':elapsed,'productionRLEBytes':rle_size(original),'candidateEstimatedRLEBytes':rle_size(ids),'changedPixelsMeaning':'semantic index changes only; see displayChangedPixels for actual themed RGB565 changes','displayChangedPixels':{},'changedPixels':sum(a!=b for a,b in zip(ids,original)),'unchangedNonWarmMask':True,'toneCoverage':{},'rois':[]}
        assert rle_size(original)==(qa/'building.bin').stat().st_size
        raw=list(source.get_flattened_data())
        with (out/'stable-colors.csv').open('w') as f:
            wr=csv.writer(f);wr.writerow(['R','G','B','lum','family','corePixels'])
            for c,n in Counter(c for p,c in enumerate(raw) if stable[p]).most_common():wr.writerow([*c,lum(c),family(c),n])
        for v in (1,8,9,11):
            corelum=[lum(c) for p,c in enumerate(raw) if stable[p] and labels[p]==v]
            entry['toneCoverage'][str(v)]={'allPixels':ids.count(v),'stableCorePixels':len(corelum),'stableCoreLumRange':[min(corelum),max(corelum)] if corelum else None}
        entry['unresolvedWarmFallbackPixels']=sum(v in (8,9) and not labels[p] for p,v in enumerate(original))
        rois=[('overview',(388,388,812,812),1),('core',(510,560,690,690),4),('ordinary-junction',(875,505,925,555),6)] if name=='06-mingbo' else [('overview',(388,388,812,812),1),('core',(510,510,690,690),4)]
        # Locate an ordinary white junction automatically, requiring no warm-road changes in its crop.
        if name=='04-interchange':
            for y in range(220,1000,3):
                found=False
                for x in range(220,1000,3):
                    if all(original[(y+dy)*N+x+dx]==1 for dx,dy in [(0,0),(-6,0),(6,0),(0,-6),(0,6)]) and sum(original[(y+dy)*N+x+dx]==1 for dx,dy in [(-8,-8),(8,-8),(-8,8),(8,8)])<=1:
                        rect=(x-25,y-25,x+25,y+25)
                        if all(original[yy*N+xx]==ids[yy*N+xx] for yy in range(y-25,y+25) for xx in range(x-25,x+25)):
                            rois.append(('ordinary-negative',rect,6));found=True;break
                if found:break
            assert found,'Need ordinary junction negative'
        for label,rect,scale in rois:entry['rois'].append({'name':label,'rect':rect,'changedPixels':sum(ids[y*N+x]!=original[y*N+x] for y in range(rect[1],rect[3]) for x in range(rect[0],rect[2]))})
        for t,n,*pal in palettes:
            candidatepal=pal[:]
            k=(45 if t==1 else 75) if n else 100
            warm={1:[(32,32,35),(64,64,68),(96,96,101)],2:[(112,122,122),(154,164,164),(198,202,202)],3:[(33,70,72),(56,130,129),(80,170,168)]}[t]
            for slot,c in zip((8,9,11),warm):candidatepal[slot]=pack(tuple(v*k//100 for v in c))
            assert all(candidatepal[v]==pal[v] for v in (*range(8),10))
            assert len({candidatepal[v] for v in (1,8,9,11)})==4
            current=render(original,pal);proposed=render(ids,candidatepal)
            entry['displayChangedPixels'][f't{t}-n{n}']=sum(pal[a]!=candidatepal[b] for a,b in zip(original,ids))
            if t==2 and n==0:
                controlpal=pal[:];controlpal[11]=pack((154,164,164))
                assert controlpal[8:10]==pal[8:10]
                control=render(ids,controlpal);control.save(out/'t2-n0-split-only.png')
                entry['splitOnlyDisplayChangedPixels']=sum(pal[a]!=controlpal[b] for a,b in zip(original,ids))
                rect=(510,560,690,690) if name=='06-mingbo' else (510,510,690,690)
                sheet([current,control,proposed],['Production GTA5 day','Control: same 8/9, add 11 only','B: source-luminance remap'],rect,4,out/'t2-n0-core-control-comparison.png')
            current.save(out/f't{t}-n{n}-production.png');proposed.save(out/f't{t}-n{n}-candidate.png')
            for label,rect,scale in rois:
                sheet([source565,current,proposed],['Source RGB565',f'Production T{t} {"night" if n else "day"}','B: 3 stable warm families + ordinary'],rect,scale,out/f't{t}-n{n}-{label}-comparison.png')
        assert all(roi['changedPixels']==0 for roi in entry['rois'] if roi['name'].startswith('ordinary'))
        report['scenes'].append(entry)
    assert family((247,195,107))==8 and family((247,223,132))==9 and family((255,235,156))==11
    assert rle_size(bytes([1]*271))==50 and rle_size(bytes([1]*272))==51
    assert all(hashlib.sha256((ROOT/p).read_bytes()).hexdigest()==v for p,v in hashes.items())
    (OUT/'report.json').write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps(report['scenes'],indent=2))
if __name__=='__main__':main()
