import Foundation
func check(_ ok: @autoclosure ()->Bool) {precondition(ok())}
check(!BuildingCoverage().isComplete)
check(BuildingCoverage(checkedMask:15).isComplete)
check(BuildingCoverage.legacyFull.qualityVersion == 0)
var raw=[UInt32](repeating:0xfff8f9fa,count:360000)
for y in 0..<2 {for x in 0..<2 {let p=y*1200+x*2;raw[p]=0xffff00ff;raw[p+1]=0xffff00ff}}
let simplified=try FastBuildings.simplify(raw)
check(simplified.filter{$0==1}.count==4)
raw[0]=0xfff8f9fa
let filtered=try FastBuildings.simplify(raw)
check(filtered.allSatisfy{$0==0})
check(FastBuildings.order(cx:0,cy:0,view:BuildingView(x:600,y:600,bearing:nil,radius:100)).first==1)
for (x,y,i) in [(-600.0,600.0,0),(600.0,-600.0,3),(-600.0,-600.0,2)] {
    check(FastBuildings.order(cx:0,cy:0,view:BuildingView(x:x,y:y,bearing:nil,radius:100)).first==i)
}
check([2,3].contains(FastBuildings.order(cx:0,cy:0,view:BuildingView(x:0,y:0,bearing:180,radius:600)).first!))
let frame=MapGeo.Frame(refLat:30,refLng:120,id:1)
let node=RouteMapPlan.Node(x:0,y:0,distance:0)
let root=URL(fileURLWithPath:NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
defer {try? FileManager.default.removeItem(at:root)}
let cache=RouteMapCache(root:root)
let patch=Data(repeating:0,count:90000)
try cache.storeBuildingPatch(patch,index:0,frame:frame,source:3,node:node)
check(cache.buildingCheckpoint(frame:frame,source:3,node:node).coverage.checkedMask==1)
let base=MapGeo.encodeRaster(frameId:frame.id,x0:-1200,y0:1200,w:1200,h:1200,mmPerPx:2000,idx:[UInt8](repeating:0,count:1440000))
try cache.storeBuildingUpdate(BuildingUpdate(bytes:base,coverage:BuildingCoverage(checkedMask:15)),frame:frame,source:3,node:node)
check(cache.buildingUpdate(frame:frame,source:3,node:node,style:3)?.coverage.isComplete==true)
check(cache.buildingUpdate(frame:frame,source:3,node:node,style:5)==nil)
var pixels=[UInt8](repeating:0,count:1440000)
pixels[0]=1;pixels[1]=3
let roads=MapGeo.encodeRaster(frameId:frame.id,x0:-1200,y0:1200,w:1200,h:1200,mmPerPx:2000,idx:pixels)
let roof=Data(repeating:1,count:90000)
let merged=RasterPacket.decode(FastBuildings.packet(base:roads,patches:[0:roof]))!
check(merged[0]==1 && merged[1]==3 && merged[2]>=4)
let files=FileManager.default.enumerator(at:root,includingPropertiesForKeys:nil)!
while let url=files.nextObject() as? URL {
    if url.lastPathComponent=="patch-0" {try Data(repeating:0,count:90008).write(to:url)}
    if url.lastPathComponent=="update.json" {try Data("{truncated".utf8).write(to:url)}
}
check(cache.buildingCheckpoint(frame:frame,source:3,node:node).coverage.checkedMask==0)
check(cache.buildingUpdate(frame:frame,source:3,node:node,style:1)==nil)
let job=RouteMapPreparationPolicy.next(base:[true,true,true,true],complete:[false,false,false,false],display:0,target:1,buildings:true,kmh:30,available:[true,true,true,true],partialReady:[false,false,false,false])
check(job?.index==0 && job?.buildings==true)
// Capture rounds its origin, including fractional route centers.
let fractional=RouteMapPlan.Node(x:0.75,y:0.75,distance:0)
let fractionalPacket=MapGeo.encodeRaster(frameId:frame.id,x0:-1199,y0:1201,w:1200,h:1200,mmPerPx:2000,idx:pixels)
try cache.storeBuildingUpdate(BuildingUpdate(bytes:fractionalPacket,coverage:BuildingCoverage(checkedMask:1)),frame:frame,source:3,node:fractional)
check(cache.buildingUpdate(frame:frame,source:3,node:fractional,style:2)?.bytes==fractionalPacket)
var rejected=false
do {try cache.storeBuildingUpdate(BuildingUpdate(bytes:fractionalPacket,coverage:BuildingCoverage(qualityVersion:99,checkedMask:15)),frame:frame,source:3,node:fractional)} catch {rejected=true}
check(rejected)
rejected=false
do {try cache.storeBuildingPatch(patch,index:0,frame:frame,source:3,node:RouteMapPlan.Node(x:.nan,y:0,distance:0))} catch {rejected=true}
check(rejected)
// Existing complete roof packets remain readable through the legacy path.
let legacy=MapGeo.encodeRaster(frameId:frame.id,x0:-1200,y0:1200,w:1200,h:1200,mmPerPx:2000 | RasterPacket.flag,idx:[UInt8](repeating:5,count:1440000))
try cache.store(legacy,frame:frame,source:3,node:node,style:1)
check(cache.buildingUpdate(frame:frame,source:3,node:node,style:1)?.coverage == .legacyFull)
// A sparse file exercises the existing quota without allocating 512MB of memory.
let quota=root.appendingPathComponent("quota")
_ = FileManager.default.createFile(atPath:quota.path,contents:nil)
let handle=try FileHandle(forWritingTo:quota)
try handle.truncate(atOffset:512*1024*1024)
try handle.close()
rejected=false
do {try cache.storeBuildingPatch(patch,index:1,frame:frame,source:3,node:node)} catch {rejected=true}
check(rejected)
check(cache.buildingCheckpoint(frame:frame,source:3,node:node).coverage.checkedMask==0)
var left=Data(repeating:0,count:90000),right=left
for y in 10..<14 {for x in 298..<300 {left[y*300+x]=1};for x in 0..<2 {right[y*300+x]=1}}
let seam=RasterPacket.decode(FastBuildings.packet(base:base,patches:[0:left,1:right]))!
check(seam[22*1200+599]==4 && seam[22*1200+600]==4)
check(seam[20*1200+599]==5)
rejected=false
do {_ = try FastBuildings.simplify([UInt32](repeating:0xffff00ff,count:360000))} catch {rejected=true}
check(rejected)
print("building-progress passed")
