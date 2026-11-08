var checks=0
func check(_ value:@autoclosure ()->Bool,_ message:String) {precondition(value(),message);checks+=1}
func testPacket(_ f:MapGeo.Frame,_ x:Double,_ y:Double)->Data {
    var colors=[UInt8](repeating:0,count:1200*1200)
    for row in 0..<1200 {for col in 580..<620 {colors[row*1200+col]=1}}
    return RoadPalette.encode(frameId:f.id,x0:Int(x-1200),y0:Int(y+1200),w:1200,h:1200,indices:colors)
}
func pump(_ seconds:Double = 0.1) {RunLoop.main.run(until:Date().addingTimeInterval(seconds))}
let f=MapGeo.Frame(refLat:30.5,refLng:104,id:789)
let plan=try RouteMapPlan([(x:0,y:0),(x:0,y:12000)])
let cache=RouteMapCache.shared,ble=BleLink.shared
defer {try? FileManager.default.removeItem(at:TestEnvironment.root)}
for y in stride(from:0.0,through:2400.0,by:600) {
    let node=RouteMapPlan.Node(x:0,y:y,distance:y)
    try cache.store(testPacket(f,0,y),frame:f,source:3,node:node,style:1)
}
let sharedNode=RouteMapPlan.Node(x:0,y:0,distance:0)
for theme in [1,2,3] {check(cache.read(frame:f,source:3,buildings:false,node:sharedNode,style:theme,allowLegacy:false) == testPacket(f,0,0),"Current game cache shared across themes")}
let feeder=MapFeeder();feeder.frame=f
feeder.offlineMaps=RouteOfflineMaps(frame:f,plan:plan,source:3,buildings:false,foregroundBusy:{false},onReady:{_ in},onStatus:{_ in})
UIApplication.shared.applicationState = .background
feeder.setRenderingAvailable(false)
feeder.onLocation(lat:f.lat(0),lng:f.lng(0),bearing:0,kmh:120)
check(ble.packets.last?.type==3,"Background starts from an existing cached road packet")
check(feeder.chunkCy==0,"Initial cache uses actual packet centre")
feeder.onAck(type:3,id:feeder.chunkId)
feeder.lastFetchFail=Date();feeder.fetching=true
feeder.onLocation(lat:f.lat(300),lng:f.lng(0),bearing:0,kmh:120)
check(feeder.chunkCy==600,"Locked cached handoff bypasses both in-flight graphics and 15-second failure backoff")
check(!feeder.fetching && AmapSdkRaster.captures==0,"Locked cache read never dispatches a new graphics capture")
feeder.onAck(type:3,id:feeder.chunkId)
let count=ble.packets.count,serial=feeder.requestSerial,lastFailure=feeder.lastFetchFail
feeder.onLocation(lat:f.lat(5000),lng:f.lng(0),bearing:0,kmh:120)
pump()
check(ble.packets.count==count,"A locked cache miss never publishes an empty replacement")
check(feeder.chunkCy==600,"Missing area preserves the old map buffer")
check(feeder.lastFetchFail==lastFailure && feeder.requestSerial==serial,"Cache miss does not poison or restart a graphics failure timer")
let missing=plan.nodes[plan.displayTarget(progress:5000,x:0,y:5000,kmh:120)]
try cache.store(testPacket(f,missing.x,missing.y),frame:f,source:3,node:missing,style:1)
feeder.onLocation(lat:f.lat(5000),lng:f.lng(0),bearing:0,kmh:120)
check(feeder.chunkCy==missing.y,"A newly available cache packet is deliverable immediately after the miss")
feeder.onAck(type:3,id:feeder.chunkId)
let shifted=try RouteMapPlan([(x:100,y:100),(x:100,y:12100)])
feeder.offlineMaps=RouteOfflineMaps(frame:f,plan:shifted,source:3,buildings:false,foregroundBusy:{false},onReady:{_ in},onStatus:{_ in})
feeder.routeProgress = -1
feeder.onLocation(lat:f.lat(1100),lng:f.lng(100),bearing:0,kmh:120)
check(feeder.chunkCx==0 && feeder.chunkCy==1200,"Background reroute reuses an overlapping map instead of requiring identical new-route nodes")
check(AmapSdkRaster.captures==0,"All locked movement and reroute cases remain graphics-free")
check(cache.covering(frame:f,source:3,style:0,x:0,y:0,kmh:120)==nil,"Cache coverage never crosses a map style")
check(cache.covering(frame:f,source:1,style:1,x:0,y:0,kmh:120)==nil,"Cache coverage never crosses a provider")
let other=MapGeo.Frame(refLat:30.5,refLng:104,id:790)
check(cache.covering(frame:other,source:3,style:1,x:0,y:0,kmh:120)==nil,"Cache coverage never crosses a frame")
feeder.offlineMaps?.close();feeder.offlineMaps=nil
feeder.lastFetchFail = .distantPast
UIApplication.shared.applicationState = .active;feeder.setRenderingAvailable(true)
feeder.onLocation(lat:f.lat(9000),lng:f.lng(0),bearing:0,kmh:0)
for _ in 0..<20 {pump();if !feeder.fetching {break}}
check(AmapSdkRaster.captures==1,"Returning to foreground resumes missing-area graphics exactly once")
check(feeder.haveChunk,"Foreground still produces a normal map")
let first=RouteMapPreparationPolicy.next(base:[true,true,true,true,false],complete:[false,false,false,false,false],display:0,target:1,buildings:true,kmh:120,available:[true,true,true,true,true])
check(first?.index==1 && first?.buildings==true,"Nearby roofs retain priority over distant road preparation")
let roofs=RouteMapPreparationPolicy.next(base:[true,true,true],complete:[false,false,false],display:0,target:1,buildings:true,kmh:120,available:[true,true,true])
check(roofs?.buildings==true,"Building preparation remains enabled once all route roads are ready")
// Reproduce the real trace: a complete future packet was compacted before it
// covered the view, forcing base + roof delivery at every later handoff.
Settings.shared.buildings=true
func roofPacket(_ y:Double)->Data {
    var colors=[UInt8](repeating:0,count:1200*1200)
    for row in 0..<1200 {for col in 580..<620 {colors[row*1200+col]=1}}
    for row in 100..<150 {for col in 100..<150 {colors[row*1200+col]=4}}
    return RoadPalette.encode(frameId:f.id,x0:-1200,y0:Int(y+1200),w:1200,h:1200,indices:colors)
}
let detailed=roofPacket(600)
check(RasterPacket.isBuilding(detailed) && !RasterPacket.isBuilding(detailed.prefix(15)),"Header-only flag probe retains short packet safety")
var wrapped=Data([7,8,9]);wrapped.append(detailed)
check(RasterPacket.isBuilding(wrapped.dropFirst(3)),"Header-only flag probe supports nonzero-index Data slices")
for fast in [true,false] {
    let staged=MapFeeder();staged.frame=f;staged.pose=(0,0,120)
    ble.mapBytesPerSecond=fast ? 1_000_000:1000
    staged.acceptChunk(testPacket(f,0,0),cx:0,cy:0,sat:false,type:3,info:"test base",src:3)
    staged.onAck(type:3,id:staged.chunkId)
    let before=ble.packets.count
    staged.acceptChunk(detailed,cx:0,cy:600,sat:false,type:3,info:"prepared complete",src:3,coverage:BuildingCoverage(checkedMask:15))
    check(ble.packets.count==before,"A future map waits until it covers the viewport")
    check(staged.handoff.pending.map{RasterPacket.isBuilding($0.bytes)} == true,"Future stage retains its complete cached roofs")
    staged.pose=(0,300,120);staged.flushPreparedMap()
    check(ble.packets.count==before+1,"Ready handoff issues one packet")
    check(RasterPacket.isBuilding(ble.packets.last!.bytes)==fast,fast ? "Measured roomy window delivers cached roads and roofs together":"Tight delivery window still compacts to roads before sending")
    if fast {
        staged.onAck(type:3,id:staged.chunkId);staged.tryUpgradeBuildings()
        check(ble.packets.count==before+1,"Complete handoff does not trigger a redundant second roof transfer")
    } else {
        check(staged.deferredRoofs != nil,"Tight-window roads keep roofs available for a later safe upgrade")
    }
}
// Admission must reserve the same road budget as protection after issue. This
// boundary passed the old check and was immediately cancelled on the next fix.
let reserved=MapFeeder();reserved.frame=f;reserved.pose=(0,0,120)
ble.mapBytesPerSecond=1_000_000
reserved.acceptChunk(testPacket(f,0,0),cx:0,cy:0,sat:false,type:3,info:"reserve base",src:3)
reserved.onAck(type:3,id:reserved.chunkId);reserved.pose=(0,300,120)
let room=MapCoveragePolicy.remainingSeconds(x:0,y:300,cx:0,cy:0,kmh:120,bearing:nil)
let oldRoadCount=MapDeliveryPolicy.compactBase(reserved.chunkBytes!).count
ble.mapBytesPerSecond=(Double(detailed.count)+Double(oldRoadCount)*0.5)/max(0.1,room-1)
check(!reserved.roofDeliveryAllowed(detailed,cx:0,cy:600),"A new-centre full map cannot omit the road reserve then cancel immediately")
ble.mapBytesPerSecond=Double(detailed.count+oldRoadCount)/max(0.1,room-1)*1.5
check(reserved.roofDeliveryAllowed(detailed,cx:0,cy:600),"A genuinely sufficient window still permits one complete map")
reserved.acceptChunk(detailed,cx:0,cy:600,sat:false,type:3,info:"complete with reserve",src:3,coverage:BuildingCoverage(checkedMask:15))
check(reserved.chunkBuildingsComplete && reserved.upgradeBase != nil,"Complete map is in flight with the real previous base saved")
ble.mapRemaining=detailed.count
let yieldBefore=MapPipelineTrace.names.filter{$0=="roof-yield"}.count
reserved.protectBaseDuringRoofTransfer()
check(reserved.chunkCy==600 && MapPipelineTrace.names.filter{$0=="roof-yield"}.count==yieldBefore,"Unchanged position/rate cannot immediately revoke an admitted transfer")
reserved.pose=(0,350,120);reserved.protectBaseDuringRoofTransfer()
check(reserved.chunkCy==0 && reserved.chunkAcked && MapPipelineTrace.names.filter{$0=="roof-yield"}.count==yieldBefore+1,"Actual loss of the delivery window still yields and restores the confirmed base")
check(reserved.chunkRoadBytes==oldRoadCount,"Yield restores the saved road reservation alongside the original map")
ble.mapRemaining=0
// Real encoded partial roofs remain partial across cache reuse and late base callbacks.
let partialNode=RouteMapPlan.Node(x:0,y:600,distance:600)
try cache.storeBuildingUpdate(BuildingUpdate(bytes:detailed,coverage:BuildingCoverage(checkedMask:1)),frame:f,source:3,node:partialNode)
for theme in [1,2,3] {
    let hit=cache.covering(frame:f,source:3,style:theme,x:0,y:600,kmh:0)
    check(hit?.coverage?.checkedMask==1,"Covering lookup retains shared game-theme partial coverage")
}
let progressive=MapFeeder();progressive.frame=f;progressive.pose=(0,600,0)
progressive.acceptChunk(testPacket(f,0,600),cx:0,cy:600,sat:false,type:3,info:"base",src:3)
progressive.onAck(type:3,id:progressive.chunkId)
UIApplication.shared.applicationState = .background;progressive.setRenderingAvailable(false)
check(progressive.useCachedMap(f,node:partialNode),"Locked partial cache is immediately usable")
check(progressive.chunkCoverage?.checkedMask==1 && !progressive.chunkBuildingsComplete,"Roof flag never implies cache completeness")
progressive.onAck(type:3,id:progressive.chunkId)
let partialId=progressive.chunkId
progressive.acceptChunk(testPacket(f,0,600),cx:0,cy:600,sat:false,type:3,info:"late base",src:3)
check(progressive.chunkCoverage?.checkedMask==1 && progressive.chunkId==partialId,"Late base cannot downgrade acknowledged partial coverage")
var pending=MapHandoffBuffer()
pending.stage(.init(bytes:detailed,cx:0,cy:600,sat:false,type:3,info:"full",source:3,style:1,coverage:BuildingCoverage(checkedMask:15)))
pending.stage(.init(bytes:detailed,cx:0,cy:600,sat:false,type:3,info:"late partial",source:3,style:1,coverage:BuildingCoverage(checkedMask:1)))
check(pending.pending?.coverage?.isComplete==true,"Late partial cannot downgrade staged complete coverage")
ble.mapBytesPerSecond=1
progressive.pose=(0,600,120)
progressive.acceptChunk(detailed,cx:0,cy:600,sat:false,type:3,info:"deferred full",src:3,coverage:BuildingCoverage(checkedMask:15))
check(progressive.chunkCoverage?.checkedMask==1 && progressive.chunkId==partialId,"Tight-budget full callback cannot replace confirmed partial roofs with compact roads")
ble.mapBytesPerSecond=1_000_000;progressive.pose=(0,600,0)
UIApplication.shared.applicationState = .active;progressive.setRenderingAvailable(true)
check(!progressive.useCachedMap(f,node:partialNode),"Foreground incomplete cache still schedules missing captures")
let future=MapFeeder();future.frame=f;future.pose=(0,0,120)
future.acceptChunk(testPacket(f,0,0),cx:0,cy:0,sat:false,type:3,info:"base",src:3)
future.onAck(type:3,id:future.chunkId)
future.acceptChunk(detailed,cx:0,cy:600,sat:false,type:3,info:"full future",src:3,coverage:BuildingCoverage(checkedMask:15))
future.acceptChunk(detailed,cx:0,cy:600,sat:false,type:3,info:"late partial",src:3,coverage:BuildingCoverage(checkedMask:1))
check(future.handoff.pending?.coverage?.isComplete==true && future.deferredRoofs?.coverage?.isComplete==true,"Deferred and staged coverage never regress after a late partial callback")
let monotonicNode=RouteMapPlan.Node(x:0,y:30000,distance:0)
let monotonicBytes=roofPacket(30000)
try cache.storeBuildingUpdate(BuildingUpdate(bytes:monotonicBytes,coverage:BuildingCoverage(checkedMask:15)),frame:f,source:3,node:monotonicNode)
try cache.storeBuildingUpdate(BuildingUpdate(bytes:monotonicBytes,coverage:BuildingCoverage(checkedMask:1)),frame:f,source:3,node:monotonicNode)
check(cache.buildingUpdate(frame:f,source:3,node:monotonicNode,style:1)?.coverage.isComplete==true,"Late partial cannot downgrade persisted complete coverage")
// Older generations prefer complete coverage when no v4 update exists.
let oldNode=RouteMapPlan.Node(x:0,y:39000,distance:0)
struct OldSaved:Codable {let bytes:Data;let coverage:BuildingCoverage;let checksum:UInt64}
for (quality,mask) in [(3,UInt8(1)),(2,UInt8(15))] {
 let bytes=roofPacket(39000),coverage=BuildingCoverage(qualityVersion:quality,checkedMask:mask)
 var material=bytes;material.append(contentsOf:"/\(quality)/\(mask)".utf8)
 let digest=material.reduce(UInt64(14695981039346656037)){($0 ^ UInt64($1)) &* 1099511628211}
 let folder=TestEnvironment.root.appendingPathComponent("fast4m-v\(quality)-3/\(f.refLat)_\(f.refLng)/-1200_40200")
 try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
 try JSONEncoder().encode(OldSaved(bytes:bytes,coverage:coverage,checksum:digest)).write(to:folder.appendingPathComponent("update.json"))
}
check(cache.buildingUpdate(frame:f,source:3,node:oldNode,style:1)?.coverage.qualityVersion==2,"old complete beats newer old partial")
let legacyNode=RouteMapPlan.Node(x:0,y:36000,distance:0)
let legacyBytes=MapGeo.encodeRaster(frameId:f.id,x0:-1200,y0:37200,w:1200,h:1200,mmPerPx:2000|RasterPacket.flag,idx:RasterPacket.decode(roofPacket(36000))!)
let legacyURL=TestEnvironment.root.appendingPathComponent("materials-v2-1/v2-3-buildings/\(f.refLat)_\(f.refLng)/0_36000.bin")
try FileManager.default.createDirectory(at:legacyURL.deletingLastPathComponent(),withIntermediateDirectories:true)
try legacyBytes.write(to:legacyURL)
try cache.storeBuildingUpdate(BuildingUpdate(bytes:roofPacket(36000),coverage:BuildingCoverage(checkedMask:1)),frame:f,source:3,node:legacyNode)
check(cache.buildingUpdate(frame:f,source:3,node:legacyNode,style:1)?.coverage.checkedMask == 1,"Current partial outranks legacy full")
// Current progress takes priority over the older complete cache.
check(cache.buildingUpdate(frame:f,source:3,node:legacyNode,style:1,currentOnly:true)?.coverage.checkedMask==1,"Processing reads current partial")
check(cache.read(frame:f,source:3,buildings:false,node:legacyNode,style:1,allowLegacy:false)==nil,"Old full is never a prepared new-generation base")
let upgrading=MapFeeder();upgrading.frame=f;upgrading.pose=(0,36000,0)
UIApplication.shared.applicationState = .active;ble.mapBytesPerSecond=1_000_000
upgrading.acceptChunk(legacyBytes,cx:0,cy:36000,sat:false,type:3,info:"legacy",src:3,coverage:.legacyFull)
upgrading.onAck(type:3,id:upgrading.chunkId)
check(!upgrading.useCachedMap(f,node:legacyNode),"Same-region legacy full permits foreground upgrade without clearing cache")
upgrading.onAck(type:3,id:upgrading.chunkId);pump()
if !upgrading.chunkAcked {upgrading.onAck(type:3,id:upgrading.chunkId);pump()}
let beforeUpgrade=AmapSdkRaster.captures
AmapSdkRaster.buildingCompletion=true
upgrading.onLocation(lat:f.lat(36000),lng:f.lng(0),bearing:0,kmh:0)
for _ in 0..<40 {pump(0.02);if !upgrading.fetching && AmapSdkRaster.captures>beforeUpgrade {break}}
check(AmapSdkRaster.captures==beforeUpgrade+1 && upgrading.chunkCurrent && upgrading.chunkCoverage?.qualityVersion==FastBuildings.qualityVersion && upgrading.chunkBuildingsComplete,"GPS at unchanged position upgrades legacy full to fresh palette full")
AmapSdkRaster.buildingCompletion=false
// A missing palette capability sends a true legacy packet; late capability waits for its ACK.
let capFeeder=MapFeeder();capFeeder.frame=f;capFeeder.pose=(0,600,0)
var tonePixels=RasterPacket.decode(detailed)!;tonePixels[0]=8;tonePixels[1]=9;tonePixels[2]=10
let tones=RoadPalette.encode(frameId:f.id,x0:-1200,y0:1800,w:1200,h:1200,indices:tonePixels)
ble.roadPaletteVersion=0
capFeeder.acceptChunk(tones,cx:0,cy:600,sat:false,type:3,info:"first",src:3,coverage:BuildingCoverage(checkedMask:1))
check(!RoadPalette.isPacket(ble.packets.last!.bytes) && RasterPacket.valid(ble.packets.last!.bytes),"Missing capability transcodes semantic tones to valid legacy RLE")
let firstToneId=capFeeder.chunkId,capCount=ble.packets.count
ble.bulkPending=true;ble.roadPaletteVersion=2
capFeeder.onRoadPaletteCapability()
check(capFeeder.chunkId==firstToneId && ble.packets.count==capCount,"Capability cannot cancel first building packet in flight")
capFeeder.onAck(type:3,id:firstToneId);ble.bulkPending=false;capFeeder.checkResend()
check(capFeeder.chunkId != firstToneId && ble.packets.count==capCount+1 && RoadPalette.isPacket(ble.packets.last!.bytes),"After ACK current packet resends in negotiated palette format")
let paletteId=capFeeder.chunkId
capFeeder.onAck(type:3,id:paletteId);capFeeder.onRoadPaletteCapability()
check(capFeeder.chunkId==paletteId && ble.packets.count==capCount+1,"Repeated unchanged capability never interrupts or duplicates identical packet")
let tail=FastBuildings.packet(base:tones,patches:[0:Data(repeating:1,count:90000),3:Data(repeating:1,count:90000)])
ble.roadPaletteVersion=0
capFeeder.acceptChunk(tail,cx:0,cy:600,sat:false,type:3,info:"tail",src:3,coverage:BuildingCoverage(checkedMask:15))
let tailId=capFeeder.chunkId,tailCount=ble.packets.count
ble.bulkPending=true;ble.roadPaletteVersion=2;capFeeder.onRoadPaletteCapability()
check(capFeeder.chunkId==tailId && capFeeder.chunkBuildingsComplete,"Late capability leaves the final building batch in flight")
capFeeder.onAck(type:3,id:tailId);ble.bulkPending=false;capFeeder.checkResend()
check(ble.packets.count==tailCount+1 && capFeeder.chunkCoverage?.isComplete==true && RoadPalette.isPacket(ble.packets.last!.bytes),"Final ACK precedes palette reissue and complete coverage survives")
// Real capability branches feed the production feeder while either transport phase is occupied.
for receipt in [false,true] {
 let cf=MapFeeder();cf.frame=f;cf.pose=(0,600,0)
 Settings.shared.buildings=true;ble.buildingsSupported=false;ble.roadPaletteVersion=0;ble.bulkPending=false
 cf.acceptChunk(tones,cx:0,cy:600,sat:false,type:3,info:"capability",src:3)
 let id=cf.chunkId,count=ble.packets.count,cancels=ble.cancels
 ble.bulkPending = !receipt;ble.receiptPending = receipt;ble.trackedMapPending = !receipt
 if receipt {ble.notify("CAP,BLD,1",target:cf);ble.notify("CAP,MPAL,1",target:cf)}
 else {ble.notify("CAP,MPAL,1",target:cf);ble.notify("CAP,BLD,1",target:cf)}
 ble.notify("CAP,MPAL,2",target:cf)
 check(cf.chunkId==id && ble.packets.count==count && ble.cancels==cancels && cf.paletteResendPending,"capabilities preserve admitted transfer and pending upgrade")
 ble.notify("CAP,BLD,1",target:cf);ble.notify("CAP,MPAL,1",target:cf)
 check(cf.chunkId==id && ble.packets.count==count,"duplicate and older capabilities do not resend")
 cf.onAck(type:3,id:id);ble.bulkPending=false;ble.receiptPending=false;ble.trackedMapPending=false;cf.checkResend()
 check(ble.packets.count==count+1 && RoadPalette.packetVersion(ble.packets.last!.bytes)==2,"combined upgrade waits for transport and sends current wire once")
}
// A building-only capability changes the actual wire when the retained packet has roofs.
let bldOnly=MapFeeder();bldOnly.frame=f;bldOnly.pose=(0,600,0)
ble.buildingsSupported=false;ble.roadPaletteVersion=0;ble.bulkPending=false
bldOnly.acceptChunk(tones,cx:0,cy:600,sat:false,type:3,info:"buildings",src:3)
bldOnly.chunkBytes=tail;bldOnly.lastWire=RoadPalette.forWire(tail,paletteVersion:0,buildingsSupported:false)
let bldID=bldOnly.chunkId,bldCount=ble.packets.count
ble.bulkPending=true;ble.notify("CAP,BLD,1",target:bldOnly)
check(bldOnly.chunkId==bldID && ble.packets.count==bldCount,"building upgrade waits for receipt")
bldOnly.onAck(type:3,id:bldID);ble.bulkPending=false;bldOnly.checkResend()
check(ble.packets.count==bldCount+1 && RasterPacket.isBuilding(ble.packets.last!.bytes),"building upgrade sends changed wire")
Settings.shared.buildings=false
// A route prepared before BLD must schedule buildings without interrupting the base receipt.
Settings.shared.buildings=true;ble.buildingsSupported=false;ble.roadPaletteVersion=2;ble.bulkPending=false;ble.receiptPending=false
let lateRoute=MapFeeder();lateRoute.frame=f;lateRoute.pose=(0,60000,0)
let routeCoords=[(lat:f.lat(60000),lng:f.lng(0)),(lat:f.lat(60600),lng:f.lng(0))]
for y in [60000.0,60600.0] {let n=RouteMapPlan.Node(x:0,y:y,distance:0);try cache.store(testPacket(f,0,y),frame:f,source:3,node:n,style:1)}
lateRoute.acceptChunk(testPacket(f,0,60000),cx:0,cy:60000,sat:false,type:3,info:"base",src:3)
lateRoute.prepareRoute(key:"late-bld",coords:routeCoords)
for _ in 0..<20 {pump(0.01)}
check(lateRoute.offlineMaps?.buildings==false,"route starts without building capability")
let routeID=lateRoute.chunkId,routeCancels=ble.cancels,routeCount=ble.packets.count,priorCaptures=AmapSdkRaster.captures
ble.receiptPending=true;ble.trackedMapPending=true;AmapSdkRaster.buildingCompletion=true
ble.notify("CAP,BLD,1",target:lateRoute)
for _ in 0..<80 {pump(0.02);if AmapSdkRaster.captures>priorCaptures {break}}
check(lateRoute.offlineMaps?.buildings==true && AmapSdkRaster.captures>priorCaptures,"late BLD schedules production route building work")
check(lateRoute.chunkId==routeID && ble.cancels==routeCancels && ble.packets.count==routeCount,"route upgrade preserves admitted base receipt")
ble.receiptPending=false;ble.trackedMapPending=false;lateRoute.onAck(type:3,id:routeID)
for _ in 0..<100 {pump(0.02);if lateRoute.chunkId != routeID && ble.packets.last.map({RasterPacket.isBuilding($0.bytes)}) == true {break}}
check(lateRoute.chunkId != routeID && ble.packets.last.map({RasterPacket.isBuilding($0.bytes)}) == true,"route buildings deliver after base ACK without movement")
lateRoute.offlineMaps?.close();AmapSdkRaster.buildingCompletion=false;Settings.shared.buildings=false
// Base-only users also upgrade old materials once, then keep their current base.
Settings.shared.buildings=false
let oldBase=RoadPalette.forWire(testPacket(f,0,42000),paletteVersion:0,buildingsSupported:false)
let oldBaseURL=TestEnvironment.root.appendingPathComponent("materials-v2-1/v1-3-base/\(f.refLat)_\(f.refLng)/0_42000.bin")
try FileManager.default.createDirectory(at:oldBaseURL.deletingLastPathComponent(),withIntermediateDirectories:true)
try oldBase.write(to:oldBaseURL)
let baseUpgrade=MapFeeder();baseUpgrade.frame=f;baseUpgrade.pose=(0,42000,0)
baseUpgrade.acceptChunk(oldBase,cx:0,cy:42000,sat:false,type:3,info:"old base",src:3)
baseUpgrade.onAck(type:3,id:baseUpgrade.chunkId)
let baseCaptures=AmapSdkRaster.captures
baseUpgrade.onLocation(lat:f.lat(42000),lng:f.lng(0),bearing:0,kmh:0)
for _ in 0..<40 {pump(0.02);if !baseUpgrade.fetching && AmapSdkRaster.captures>baseCaptures {break}}
check(baseUpgrade.chunkCurrent && AmapSdkRaster.captures>=baseCaptures+1,"Base-only mode refreshes old processing version in place")
baseUpgrade.onAck(type:3,id:baseUpgrade.chunkId)
baseUpgrade.onLocation(lat:f.lat(42000),lng:f.lng(0),bearing:0,kmh:0);pump(0.05)
check((try? Data(contentsOf:oldBaseURL))==oldBase,"old offline file remains byte-for-byte after current base settles")
Settings.shared.buildings=true
let held=MapFeeder();held.frame=f;held.pose=(0,36000,120)
// Use a separate legacy full with a current road base, but no current full result.
let heldNode=RouteMapPlan.Node(x:0,y:48000,distance:0)
let heldLegacyURL=TestEnvironment.root.appendingPathComponent("materials-v2-1/v2-3-buildings/\(f.refLat)_\(f.refLng)/0_48000.bin")
try FileManager.default.createDirectory(at:heldLegacyURL.deletingLastPathComponent(),withIntermediateDirectories:true)
try RoadPalette.forWire(roofPacket(48000),paletteVersion:0,buildingsSupported:true).write(to:heldLegacyURL)
try cache.store(testPacket(f,0,48000),frame:f,source:3,node:heldNode,style:1)
held.pose=(0,48000,120)
check(held.useCachedMap(f,node:heldNode) && held.chunkCurrent,"Highway speed delivers current cached base ahead of old full")
check(cache.covering(frame:f,source:3,style:1,x:0,y:48000,kmh:120).map{RouteMapCache.isCurrent($0.bytes,source:3,style:1)} == true,"Covering cache also prefers current roads")
held.pose=(0,48000,0)
check(!held.useCachedMap(f,node:heldNode),"Slowing down permits finishing new buildings over the prepared base")
held.lastBuildingTry=Date()
check(held.useCachedMap(f,node:heldNode),"Old full display honors existing building retry cooldown after a yielded or failed upgrade")
// Empty checked patches carry coverage even when their packet has no roofs.
let emptyChecked=MapFeeder();emptyChecked.frame=f;emptyChecked.pose=(0,600,0)
let identicalRoads=MapDeliveryPolicy.compactBase(detailed)
emptyChecked.acceptChunk(identicalRoads,cx:0,cy:600,sat:false,type:3,info:"empty checked patch",src:3,coverage:BuildingCoverage(checkedMask:1))
emptyChecked.onAck(type:3,id:emptyChecked.chunkId)
let emptyCheckedId=emptyChecked.chunkId
ble.mapBytesPerSecond=1;emptyChecked.pose=(0,600,120)
emptyChecked.acceptChunk(detailed,cx:0,cy:600,sat:false,type:3,info:"full roofs exceed budget",src:3,coverage:BuildingCoverage(checkedMask:15))
check(emptyChecked.chunkCoverage?.checkedMask==1 && emptyChecked.chunkBytes==identicalRoads && emptyChecked.chunkId==emptyCheckedId && emptyChecked.chunkAcked,"Identical compacted roads retain acknowledged empty-patch coverage")
emptyChecked.acceptChunk(identicalRoads,cx:0,cy:600,sat:false,type:3,info:"all checked empty",src:3,coverage:BuildingCoverage(checkedMask:15))
check(emptyChecked.chunkCoverage?.isComplete==true && emptyChecked.chunkBuildingsComplete,"Unmodified identical roads can advance checked coverage")
// New quality partial replaces older complete observations.
let fastPartialBytes=FastBuildings.packet(base:identicalRoads,patches:[0:Data(repeating:1,count:90000)])
var legacyPending=MapHandoffBuffer()
legacyPending.stage(.init(bytes:detailed,cx:0,cy:600,sat:false,type:3,info:"legacy full",source:3,style:1,coverage:.legacyFull))
legacyPending.stage(.init(bytes:fastPartialBytes,cx:0,cy:600,sat:false,type:3,info:"fast partial",source:3,style:1,coverage:BuildingCoverage(checkedMask:1)))
check(legacyPending.pending?.coverage?.checkedMask == 1 && legacyPending.pending?.bytes==fastPartialBytes,"Staged new-quality partial replaces old full")
let legacyDeferred=MapFeeder();legacyDeferred.frame=f;legacyDeferred.pose=(0,0,120)
ble.mapBytesPerSecond=1_000_000
legacyDeferred.acceptChunk(testPacket(f,0,0),cx:0,cy:0,sat:false,type:3,info:"base",src:3)
legacyDeferred.onAck(type:3,id:legacyDeferred.chunkId)
legacyDeferred.acceptChunk(detailed,cx:0,cy:600,sat:false,type:3,info:"legacy full",src:3,coverage:.legacyFull)
legacyDeferred.acceptChunk(fastPartialBytes,cx:0,cy:600,sat:false,type:3,info:"fast partial",src:3,coverage:BuildingCoverage(checkedMask:1))
check(legacyDeferred.deferredRoofs?.coverage?.checkedMask == 1 && legacyDeferred.deferredRoofs?.bytes==fastPartialBytes,"Deferred new-quality partial replaces old full")
// Processing generation takes precedence, while an admitted transfer retains its ID until ACK.
let generation=MapFeeder();generation.frame=f;generation.pose=(0,54000,120)
let newRoads=testPacket(f,0,54000)
let oldFull=RoadPalette.forWire(roofPacket(54000),paletteVersion:0,buildingsSupported:true)
let newFull=roofPacket(54000)
ble.mapBytesPerSecond=1_000_000;ble.trackedMapPending=false
generation.acceptChunk(oldFull,cx:0,cy:54000,sat:false,type:3,info:"old full",src:3,coverage:.legacyFull)
let oldID=generation.chunkId
ble.trackedMapPending=true
generation.acceptChunk(newRoads,cx:0,cy:54000,sat:false,type:3,info:"new roads",src:3)
check(generation.chunkId==oldID && generation.handoff.pending?.bytes==newRoads,"Current base stages behind old full in flight")
generation.acceptChunk(oldFull,cx:0,cy:54000,sat:false,type:3,info:"late old",src:3,coverage:.legacyFull)
check(generation.handoff.pending?.bytes==newRoads,"Old callback cannot displace staged current roads")
ble.trackedMapPending=false;generation.onAck(type:3,id:oldID);pump()
check(generation.chunkCurrent && generation.chunkBytes==newRoads && generation.chunkId != oldID,"Old full ACK sends current roads at highway speed")
let roadID=generation.chunkId
ble.trackedMapPending=true
generation.acceptChunk(newFull,cx:0,cy:54000,sat:false,type:3,info:"new full",src:3,coverage:BuildingCoverage(checkedMask:15))
check(generation.chunkId==roadID && !generation.chunkAcked,"New full cannot retract current roads in flight")
generation.acceptChunk(oldFull,cx:0,cy:54000,sat:false,type:3,info:"late old",src:3,coverage:.legacyFull)
check(generation.chunkId==roadID && generation.chunkCurrent,"Late legacy full cannot roll back new base")
ble.trackedMapPending=false;generation.pose=(0,54000,0);generation.onAck(type:3,id:roadID);pump()
check(generation.chunkCurrent && generation.chunkBuildingsComplete && generation.chunkId != roadID,"Road ACK permits current full delivery")
ble.trackedMapPending=false
let partialUpgrade=MapFeeder();partialUpgrade.frame=f;partialUpgrade.pose=(0,54000,0)
partialUpgrade.acceptChunk(oldFull,cx:0,cy:54000,sat:false,type:3,info:"old",src:3,coverage:.legacyFull)
partialUpgrade.onAck(type:3,id:partialUpgrade.chunkId)
partialUpgrade.acceptChunk(newFull,cx:0,cy:54000,sat:false,type:3,info:"partial",src:3,coverage:BuildingCoverage(checkedMask:1))
let partialRoadID=partialUpgrade.chunkId
check(partialUpgrade.chunkCurrent && !partialUpgrade.chunkAcked && partialUpgrade.deferredRoofs?.coverage?.checkedMask==1,"Current partial sends current roads before its roofs")
partialUpgrade.acceptChunk(oldFull,cx:0,cy:54000,sat:false,type:3,info:"late",src:3,coverage:.legacyFull)
check(partialUpgrade.chunkId==partialRoadID && partialUpgrade.chunkCurrent,"Late old full cannot replace current roads")
partialUpgrade.onAck(type:3,id:partialRoadID);pump()
check(partialUpgrade.chunkCurrent && partialUpgrade.chunkCoverage?.checkedMask==1,"Current partial follows current road ACK")
// A newer partial also wins over old complete coverage in both queue and deferred slots.
var generationQueue=MapHandoffBuffer()
generationQueue.stage(.init(bytes:oldFull,cx:0,cy:54000,sat:false,type:3,info:"old",source:3,style:1,coverage:.legacyFull))
generationQueue.stage(.init(bytes:newFull,cx:0,cy:54000,sat:false,type:3,info:"partial",source:3,style:1,coverage:BuildingCoverage(checkedMask:1)))
generationQueue.stage(.init(bytes:oldFull,cx:0,cy:54000,sat:false,type:3,info:"late",source:3,style:1,coverage:.legacyFull))
check(generationQueue.pending?.bytes==newFull && generationQueue.pending?.coverage?.checkedMask==1,"Staged partial outranks old full and cannot regress")
// A cancelled graphics job may finish late; its callbacks cannot replace cached delivery.
Settings.shared.buildings=false
let late=MapFeeder();late.frame=f;late.pose=(0,20000,0)
AmapSdkRaster.pause=true
let capturesBefore=AmapSdkRaster.captures
late.fetchChunk(f,0,20000)
for _ in 0..<40 {pump(0.01);if AmapSdkRaster.captures>capturesBefore {break}}
late.setRenderingAvailable(false)
let cancelledSerial=late.requestSerial
AmapSdkRaster.release.signal()
for _ in 0..<20 {pump(0.01)}
check(!late.haveChunk && !late.fetching && late.requestSerial==cancelledSerial,"Cancelled foreground callbacks never replace cache/BLE state")
AmapSdkRaster.pause=false
// Pausing offline graphics must also hold while UIKit still reports active.
let offlineFrame=MapGeo.Frame(refLat:31,refLng:105,id:791)
let offlinePlan=try RouteMapPlan([(x:0,y:0),(x:0,y:10)])
let offline=RouteOfflineMaps(frame:offlineFrame,plan:offlinePlan,source:3,buildings:false,foregroundBusy:{false},onReady:{_ in},onStatus:{_ in})
offline.suspendCapture()
let beforeOffline=AmapSdkRaster.captures
offline.start();pump(0.6)
check(AmapSdkRaster.captures==beforeOffline,"Suspended offline capture honors explicit rendering availability")
offline.resumeCapture()
for _ in 0..<40 {pump(0.05);if AmapSdkRaster.captures>beforeOffline {break}}
check(AmapSdkRaster.captures==beforeOffline+1,"Offline resume captures the missing map once")
offline.close()
Settings.shared.buildings=false;ble.mapBytesPerSecond=30000
print("PASS screen-off production feeder/cache: \(checks) checks; locked handoff, cache misses, recent failure, busy capture, reroute overlap, source/style/frame isolation and foreground recovery")
