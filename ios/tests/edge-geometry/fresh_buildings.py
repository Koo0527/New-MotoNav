"""Fresh-source offline upper-bound replay; preserves production files and packets.

python3 ios/tests/edge-geometry/fresh_buildings.py INPUT_DIR OUTPUT_DIR
Uses already installed Pillow and actual production Swift/C++ implementations.
"""
from pathlib import Path
import argparse, hashlib, json, statistics, subprocess, tempfile, time
from collections import Counter
from PIL import Image, ImageDraw, ImageFilter, ImageFont
from preview import png_from_ppm

ROOT=Path(__file__).resolve().parents[3]
TESTS=Path(__file__).resolve().parent

def topology(mask, size=600):
    seen=bytearray(len(mask)); components=[]; holes=0
    for i in range(len(mask)):
        if seen[i]: continue
        value=mask[i]; seen[i]=1; queue=[i]; head=0; border=False
        while head<len(queue):
            p=queue[head];head+=1;x=p%size;y=p//size
            border |= x==0 or y==0 or x==size-1 or y==size-1
            for n in (p-1 if x else -1,p+1 if x+1<size else -1,p-size if y else -1,p+size if y+1<size else -1):
                if n>=0 and not seen[n] and mask[n]==value:seen[n]=1;queue.append(n)
        if value:components.append(len(queue))
        elif not border:holes+=1
    return dict(components=len(components),holes=holes,occupied=sum(mask),smallComponentsUnder16=sum(n<16 for n in components),largest=max(components,default=0))

def panel(images, labels, path):
    height=max(im.height for im in images);width=sum(im.width for im in images)
    out=Image.new('RGB',(width,height+36),'white');draw=ImageDraw.Draw(out)
    x=0
    for im,label in zip(images,labels):
        out.paste(im.convert('RGB'),(x,36));draw.text((x+8,8),label,fill='black',font=ImageFont.load_default(size=16));x+=im.width
    out.save(path)

def mask_image(mask):return Image.frombytes('L',(600,600),bytes(v*255 for v in mask)).convert('RGB')

def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('input',type=Path);parser.add_argument('output',type=Path)
    args=parser.parse_args();args.output.mkdir(parents=True,exist_ok=True)
    scenes=[p for p in sorted(args.input.iterdir()) if p.is_dir() and (p/'production-base.bin').exists()][:2]
    if (args.input/'production-base.bin').exists():scenes=[args.input]
    assert scenes,'No complete source scene found'
    reports=[]
    with tempfile.TemporaryDirectory(prefix='motonav-fresh-') as temp:
        tmp=Path(temp)
        subprocess.run(['swiftc','-O','-module-cache-path',str(tmp/'modules'),str(ROOT/'ios/MotoNav/MapGeo.swift'),str(ROOT/'ios/MotoNav/RasterProcessing.swift'),str(ROOT/'ios/MotoNav/RoadPalette.swift'),str(ROOT/'ios/MotoNav/MapEdgeGeometry.swift'),str(TESTS/'fresh/main.swift'),'-o',str(tmp/'replay')],check=True)
        subprocess.run(['c++','-std=c++11','-O2','-Wall','-Wextra','-Werror',str(TESTS/'render.cpp'),'-lz','-o',str(tmp/'render')],check=True)
        for source in scenes:
            output=args.output/source.name;output.mkdir(exist_ok=True)
            # New isolated outputs only: reject accidental replacement of an earlier replay.
            assert not (output/'report.json').exists(),f'Use a new output directory: {output}'
            result=subprocess.run([str(tmp/'replay'),str(source),str(output)],check=True,capture_output=True,text=True)
            report=json.loads(result.stdout);report['scene']=source.name;report['sourceSHA256']={};report['tilesAnalysis']=[]
            for path in sorted(source.iterdir()):
                if path.suffix=='.png' or path.name.endswith('.argb32le'):
                    report['sourceSHA256'][path.name]=hashlib.sha256(path.read_bytes()).hexdigest()
            rendered={}
            for variant in report['variants']:
                name=variant['variant']
                edge_path=output/f'{name}.edge' if variant['tailAvailable'] else output/'nearest-preview-only.edge'
                proc=subprocess.run([str(tmp/'render'),str(output/f'{name}.raw'),str(edge_path),'1200','1200','1','0','2','0',str(tmp/f'{name}-nearest.ppm'),str(tmp/f'{name}-edge.ppm')],check=True,capture_output=True,text=True)
                variant['decoderStats' if variant['tailAvailable'] else 'nearestPreviewDecoderStats']=proc.stdout.strip()
                variant['previewMode']='EDGE retained' if variant['tailAvailable'] else 'nearest fallback; rejected EDGE not emitted'
                for mode in (('nearest','edge') if variant['tailAvailable'] else ('nearest',)):
                    png_from_ppm(tmp/f'{name}-{mode}.ppm',output/f'{name}-{mode}.png')
                    rendered[name,mode]=Image.open(output/f'{name}-{mode}.png').copy()
            current_bytes=(output/'current.raw').read_bytes();candidate_bytes=(output/'candidate.raw').read_bytes() if (output/'candidate.raw').exists() else bytes(1440000)
            for mask_path in sorted(output.glob('tile-*-original.mask')):
                q=int(mask_path.name.split('-')[1]);ox=q%2*600;oy=q//2*600
                original=mask_path.read_bytes();accepted=(output/f'tile-{q}-4m.mask').exists();small=Image.frombytes('L',(300,300),(output/f'tile-{q}-4m.mask').read_bytes() if accepted else bytes(90000))
                coarse=small.resize((600,600),Image.Resampling.NEAREST).tobytes()
                projection=json.loads((source/f'building-{q}-on.json').read_text())
                on=Image.open(source/f'building-{q}-on.png').convert('RGB');off=Image.open(source/f'building-{q}-off.png').convert('RGB')
                camera=json.loads((source/f'building-{q}-camera.json').read_text());before=Counter();after=Counter();delta_hist=Counter()
                cols=projection['columns'];rows=projection['rows'];assert len(cols)==len(rows)==600
                sampled=bytearray();sampled_on=Image.new('RGB',(600,600));sampled_off=sampled_on.copy()
                for y,row in enumerate(rows):
                    for x,col in enumerate(cols):
                        a=off.getpixel((col,row));b=on.getpixel((col,row));sampled.append(int(max(abs(a[k]-b[k]) for k in range(3))>=4));sampled_on.putpixel((x,y),b);sampled_off.putpixel((x,y),a)
                        diff=max(abs(a[k]-b[k]) for k in range(3));delta_hist[diff]+=1
                        if diff>=4:before[a]+=1;after[b]+=1
                mismatch=sum(a!=b for a,b in zip(sampled,original))
                assert mismatch==0, f'PNG/sample mismatch in {source.name} tile {q}: {mismatch}'
                original_im=mask_image(original);coarse_im=mask_image(coarse)
                delta=bytes(a!=b for a,b in zip(original,coarse));loss=sum(a and not b for a,b in zip(original,coarse));extra=sum(b and not a for a,b in zip(original,coarse))
                # Find a large, reproducible crop without using absolute location metadata.
                scores=[]
                for y in range(0,505,24):
                    for x in range(0,505,24):scores.append((sum(sum(delta[yy*600+x:yy*600+x+96]) for yy in range(y,y+96)),x,y))
                _,x,y=max(scores);box=(x,y,x+96,y+96)
                current=bytes(current_bytes[(oy+yy)*1200+ox+xx]>=4 for yy in range(600) for xx in range(600))
                candidate=bytes(candidate_bytes[(oy+yy)*1200+ox+xx]>=4 for yy in range(600) for xx in range(600))
                assert all(not b or a for a,b in zip(original,candidate))
                tile=dict(quadrant=q,productionAccepted=accepted,sourcePairMatchesSample=True,original=topology(original),current4mBeforePriority=topology(coarse),currentAfterPriority=topology(current),candidateAfterPriority=topology(candidate),lostOriginalCells=loss,addedOutsideOriginalCells=extra,changedCells=sum(delta),relativeCrop=list(box),roadWaterRemovedOriginalCells=sum(original)-sum(candidate))
                original_l=original_im.convert('L');outer=original_l.filter(ImageFilter.MaxFilter(3));inner=original_l.filter(ImageFilter.MinFilter(3));boundary=bytes(a!=b for a,b in zip(outer.tobytes(),inner.tobytes()))
                band=Image.frombytes('L',(600,600),bytes(v*255 for v in boundary)).filter(ImageFilter.MaxFilter(5)).tobytes()
                tile['changedCellsFartherThanTwoCellsFromSourceBoundary']=sum(d and not near for d,near in zip(delta,band))
                if not report['candidateBoundaryValid']:
                    tile['candidateAfterPriority']=None
                    tile['roadWaterRemovedOriginalCells']=None
                tile['sourceDiagnostics']={'maxOnOffProjectionDeltaPx':max(abs(a-b) for a,b in zip(camera['offProjection'],camera['onProjection'])),'unchangedSampleCells':delta_hist[0],'delta1to3Cells':sum(delta_hist[d] for d in (1,2,3)),'deltaGE4Cells':sum(n for d,n in delta_hist.items() if d>=4),'mostCommonChangedOFFColors':before.most_common(8),'mostCommonChangedONColors':after.most_common(8)}
                if not accepted:
                    for key in ['lostOriginalCells','addedOutsideOriginalCells','changedCells','roadWaterRemovedOriginalCells','changedCellsFartherThanTwoCellsFromSourceBoundary']:tile[key]=None
                    tile['excludedReason']='Production simplify rejected coverage; absent patch is not a quality comparison.'
                report['tilesAnalysis'].append(tile)
                images=[sampled_on,original_im,coarse_im]
                labels=['Source ON sampled at 2m','Original 2m silhouette','Production 4m silhouette']
                if ('candidate','edge') in rendered:
                    images.append(rendered['candidate','edge'].crop((ox*2,oy*2,(ox+600)*2,(oy+600)*2)).resize((600,600),Image.Resampling.LANCZOS));labels.append('Candidate / real palette + EDGE')
                panel(images,labels,output/f'tile-{q}-overview.png')
                zoom=lambda im:im.crop(box).resize((384,384),Image.Resampling.NEAREST)
                crop_images=[zoom(sampled_off),zoom(sampled_on),zoom(original_im),zoom(coarse_im)];crop_labels=['Source OFF','Source ON','Original 2m mask','Production 4m mask']
                for name in ('current','candidate'):
                    mode='edge' if (name,'edge') in rendered else 'nearest'
                    if (name,mode) in rendered:
                        b=(ox*2+x*2,oy*2+y*2,ox*2+(x+96)*2,oy*2+(y+96)*2)
                        crop_images.append(rendered[name,mode].crop(b).resize((384,384),Image.Resampling.NEAREST));crop_labels.append(name+' / real palette '+mode)
                panel(crop_images,crop_labels,output/f'tile-{q}-detail.png')
                # Native screenshot crop, without a resampling detour.
                native_box=(cols[x],rows[y],cols[x+95]+1,rows[y+95]+1)
                panel([off.crop(native_box),on.crop(native_box)],['Original screenshot OFF','Original screenshot ON'],output/f'tile-{q}-native-source.png')
            comparison_keys=[key for key in [('current','nearest'),('current','edge'),('candidate','nearest'),('candidate','edge')] if key in rendered]
            panel([rendered[key].resize((900,900),Image.Resampling.LANCZOS) for key in comparison_keys],[f'{name} / actual C++ {mode}' for name,mode in comparison_keys],output/'full-current-candidate.png')
            (output/'report.json').write_text(json.dumps(report,indent=2)+'\n');reports.append(report)
    reports=[json.loads(path.read_text()) for path in sorted(args.output.glob('*/report.json'))]
    (args.output/'report.json').write_text(json.dumps(reports,indent=2)+'\n')
    print(json.dumps(reports,indent=2))

if __name__=='__main__':main()
