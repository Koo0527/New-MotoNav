"""Export real production Swift packets; cross-check via production firmware host decoder/rendering."""
from pathlib import Path
import hashlib,json,subprocess,tempfile
from PIL import Image,ImageDraw
ROOT=Path(__file__).resolve().parents[3]
OUT=ROOT/'output/map-edge-bridge/road-multitone-export'
with tempfile.TemporaryDirectory(prefix='motonav-road-palette-real-') as tmp:
    tmp=Path(tmp)
    subprocess.run(['swiftc','-O','-module-cache-path',str(tmp/'modules'),*[str(ROOT/'ios/MotoNav'/p) for p in ['MapGeo.swift','RasterProcessing.swift','RoadPalette.swift']],str(Path(__file__).with_name('main.swift')),'-o',str(tmp/'export')],check=True)
    subprocess.run([str(tmp/'export'),str(ROOT)],check=True)
    subprocess.run(['c++','-std=c++17','-O2',str(ROOT/'firmware/tests/raster-road-palette/real.cpp'),'-o',str(tmp/'host')],check=True)
    with (OUT/'host.log').open('w') as log:subprocess.run([str(tmp/'host'),str(OUT)],stdout=log,check=True)
for scene in ['06-mingbo','01-dense']:
    folder=OUT/scene
    for ppm in folder.glob('*.ppm'):
        Image.open(ppm).save(ppm.with_suffix('.png'))
        ppm.unlink()
    # Six day/night rows, exact native 424px panels, before/after at 0 and 45 degrees.
    sheet=Image.new('RGB',(424*4,454*6),(24,24,24));draw=ImageDraw.Draw(sheet)
    for row,(theme,night) in enumerate((t,n) for t in range(1,4) for n in range(2)):
        for col,(angle,kind) in enumerate((a,k) for a in [0,45] for k in ['old-building','building']):
            sheet.paste(Image.open(folder/f't{theme}-n{night}-a{angle}-{kind}.png'),(col*424,row*454+30))
            draw.text((col*424+8,row*454+8),f'{["","VC","GTA5","Cyber"][theme]} {"night" if night else "day"} {angle}deg {"before" if kind.startswith("old") else "RoadPalette"}',fill='white')
    sheet.save(OUT/f'{scene}-comparison.png')
manifest={str(p.relative_to(OUT)):{'bytes':p.stat().st_size,'sha256':hashlib.sha256(p.read_bytes()).hexdigest()} for p in sorted(OUT.rglob('*')) if p.is_file() and p.suffix in {'.bin','.idx','.png'}}
(OUT/'artifact-manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
sources=['ios/MotoNav/MapGeo.swift','ios/MotoNav/RasterProcessing.swift','ios/MotoNav/RoadPalette.swift','firmware/boards/175/MotoNav/src/map/RasterDecoder.h','firmware/boards/175/MotoNav/src/map/RasterRenderer.h','firmware/boards/175/MotoNav/GameMapStyle.h','firmware/boards/175/MotoNav/RasterContinuity.h','firmware/boards/175/MotoNav/RasterBuildingCarry.h']
(OUT/'source-manifest.json').write_text(json.dumps({p:hashlib.sha256((ROOT/p).read_bytes()).hexdigest() for p in sources},indent=2)+'\n')
print('real Swift → production firmware: 12 x 1,440,000 exact semantic pixels; actual 424px render previews exported')
