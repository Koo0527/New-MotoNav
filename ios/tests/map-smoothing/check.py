#!/usr/bin/env python3
"""Compile and exercise the production Swift raster pipeline (no test copy)."""
import pathlib
import subprocess
import tempfile

root = pathlib.Path(__file__).resolve().parents[3]
swift = r'''
import Foundation
func check(_ ok: Bool, _ message: String) {
    if !ok { print("FAIL: \(message)"); exit(1) }
}
let n=120
func classified(_ mask:[UInt8]) -> [UInt8] {
    let palette:[UInt32]=[0xfff8f8f8,0xffffffff,0xff87c080,0xff80b0e0]
    return MapGeo.classifyAmapBase(mask.map {palette[Int($0)]},w:n,h:n)
}
var thin=[UInt8](repeating:0,count:n*n)
for x in 30..<50 {thin[40*n+x]=1}
let thinOut=classified(thin)
check((30..<50).allSatisfy {thinOut[40*n+$0]==1},"one-pixel road must survive cleanup")
var parallel=[UInt8](repeating:0,count:n*n)
for y in 10..<110 {parallel[y*n+40]=1;parallel[y*n+42]=1}
let separated=classified(parallel)
check((12..<108).allSatisfy {separated[$0*n+41]==0},"parallel roads keep their one-pixel separator")
var crossing=parallel
for x in 30..<60 {crossing[60*n+x]=1}
let crossed=classified(crossing)
check(crossing.indices.allSatisfy {crossing[$0] != 1 || crossed[$0]==1},"connected intersections and ramps must survive")
var ramp=parallel
for y in 80..<100 {ramp[y*n+40]=1;ramp[y*n+41]=1;ramp[y*n+42]=1}
let rampOut=classified(ramp)
check((12..<75).allSatisfy {rampOut[$0*n+41]==0},"parallel branches connected at ramp retain their separation")
var materials=crossing
for y in 20..<50 {for x in 43..<70 {materials[y*n+x] = x<55 ? 2:3}}
let materialOut=classified(materials)
check(materials.indices.allSatisfy {materials[$0]<2 || materialOut[$0]==materials[$0]},"roads never invade raw water/parks")
var raw=[UInt32](repeating:0xfff8f8f8,count:600*600)
func roof(_ x:Int,_ y:Int) {for dy in 0..<2 {for dx in 0..<2 {raw[(y*2+dy)*600+x*2+dx]=0xffff00ff}}}
for y in 30..<40 {for x in 30..<40 {roof(x,y)}}
roof(35,29)
let roofOut=try FastBuildings.simplify(raw)
check(roofOut[29*300+35]==0,"remove the single-cell roof spur")
check(roofOut.filter {$0==1}.count==100,"keep rectangular roof body")

func components(_ mask:[UInt8], target:UInt8, diagonal:Bool, width:Int=300) -> Int {
    var seen=[Bool](repeating:false,count:mask.count), count=0
    for start in mask.indices where mask[start]==target && !seen[start] {
        count += 1
        var queue=[start], head=0; seen[start]=true
        while head<queue.count {
            let p=queue[head]; head += 1
            for dy in -1...1 {for dx in -1...1 {
                if dx==0 && dy==0 || (!diagonal && abs(dx)+abs(dy) != 1) {continue}
                let x=p%width+dx,y=p/width+dy
                if x<0 || x>=width || y<0 || y>=mask.count/width {continue}
                let q=y*width+x
                if mask[q]==target && !seen[q] {seen[q]=true;queue.append(q)}
            }}
        }
    }
    return count
}
func topology(_ input:Data) {
    let output=FastBuildings.clean(input), a=[UInt8](input), b=[UInt8](output)
    check(FastBuildings.clean(output)==output,"cleanup is idempotent")
    check(components(a,target:1,diagonal:false)==components(b,target:1,diagonal:false),"building component count stays constant")
    check(components(a,target:0,diagonal:true)==components(b,target:0,diagonal:true),"building holes stay constant")
    check(a.indices.allSatisfy {a[$0]>=b[$0]},"cleanup never adds/merges roofs")
    for i in 0..<300 {
        check(a[i]==b[i] && a[89700+i]==b[89700+i] && a[i*300]==b[i*300] && a[i*300+299]==b[i*300+299],"tile seam retains raw border")
    }
}
var building=[UInt8](repeating:0,count:90000)
for y in 10..<30 {for x in 10..<30 {building[y*300+x]=1}}
for y in 15..<25 {for x in 15..<25 {building[y*300+x]=0}}
for x in 30..<45 {building[20*300+x]=1} // thin connection remains intact
for y in 15..<25 {for x in 45..<55 {building[y*300+x]=1}}
for y in 0..<8 {for x in 60..<70 {building[y*300+x]=1}}
building[60]=1;building[100*300+299]=1
for p in [9*300+20,30*300+20,20*300+9] {building[p]=1}
topology(Data(building))
check(FastBuildings.clean(Data([1]))==Data([1]),"bad-sized patches unchanged")
check(FastBuildings.clean(Data(repeating:2,count:90000))==Data(repeating:2,count:90000),"non-binary patches unchanged")
check(FastBuildings.qualityVersion==2 && BuildingCoverage().qualityVersion==2 && BuildingCoverage.legacyFull.qualityVersion==0,"quality migration constant")
var seed:UInt64=7
for _ in 0..<30 {
    var mask=[UInt8](repeating:0,count:90000)
    for y in 90..<112 {for x in 90..<112 {
        seed=seed &* 6364136223846793005 &+ 1
        mask[y*300+x] = seed>>61<5 ? 1:0
    }}
    topology(Data(mask))
}
var donut=[UInt8](repeating:0,count:n*n)
for y in 30..<80 {for x in 30..<80 {donut[y*n+x]=1}}
for y in 33..<77 {for x in 33..<77 {donut[y*n+x]=0}}
let donutOut=classified(donut)
check(donutOut[50*n+50]==0,"road hole is retained")
check(donut.indices.allSatisfy {donut[$0] != 1 || donutOut[$0]==1},"road hole outline remains intact")

for source in [thin,parallel,crossing,ramp,donut] {
    let result=classified(source)
    check(components(source,target:1,diagonal:false,width:n)==components(result,target:1,diagonal:false,width:n),"road topology keeps components")
    check(components(source,target:0,diagonal:true,width:n)==components(result,target:0,diagonal:true,width:n),"road topology keeps holes and gaps")
}
var dent=[UInt8](repeating:0,count:n*n)
for y in 30..<50 {for x in 30..<50 {dent[y*n+x]=1}}
dent[30*n+40]=0
check(classified(dent)[30*n+40]==1,"majority cleanup fills a road-edge dent")
let colors:[UInt32]=[0xfff8f8f8,0xffffffff,0xff87c080,0xff80b0e0]
let rawMaterial=materials.map {colors[Int($0)]}
let legacy=MapGeo.dilateRoads(MapGeo.cleanRaster(materials,w:n,h:n),w:n,h:n)
for style in [4,6,7,8,9] {
    check(MapGeo.classifyAmapBase(rawMaterial,w:n,h:n,style:style)==legacy,"other themes retain old morphology")
}
for style in [1,2,3] {
    check(MapGeo.classifyAmapBase(rawMaterial,w:n,h:n,style:style)==materialOut,"all game styles use structural smoothing")
}
var packetPixels=[UInt8](repeating:0,count:1200*1200)
packetPixels[0]=1;packetPixels[1]=3
let packet=MapGeo.encodeRaster(frameId:1,x0:0,y0:0,w:1200,h:1200,mmPerPx:2000,idx:packetPixels)
let composed=FastBuildings.packet(base:packet,patches:[0:Data(repeating:1,count:90000)])
let composedPixels=RasterPacket.decode(composed)!
check(composedPixels[0]==1 && composedPixels[1]==3 && composedPixels[2]>=4,"packet keeps roads and water ahead of roofs")
print("map smoothing production regressions passed")
'''
with tempfile.TemporaryDirectory(prefix='motonav-map-smoothing-') as temp:
    tmp=pathlib.Path(temp)
    main=tmp/'main.swift'
    main.write_text(swift)
    exe=tmp/'check'
    subprocess.run(['swiftc','-O','-module-cache-path',str(tmp/'modules'),
                    str(root/'ios/MotoNav/MapGeo.swift'),str(root/'ios/MotoNav/RasterProcessing.swift'),
                    str(main),'-o',str(exe)],check=True)
    subprocess.run([str(exe)],check=True)
