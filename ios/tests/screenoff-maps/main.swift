var checks=0
func check(_ value:@autoclosure ()->Bool,_ message:String) {precondition(value(),message);checks+=1}
func testPacket(_ f:MapGeo.Frame,_ x:Double,_ y:Double)->Data {
    var colors=[UInt8](repeating:0,count:1200*1200)
    for row in 0..<1200 {for col in 580..<620 {colors[row*1200+col]=1}}
    return MapGeo.encodeRaster(frameId:f.id,x0:Int(x-1200),y0:Int(y+1200),w:1200,h:1200,mmPerPx:2000,idx:colors)
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
    return MapGeo.encodeRaster(frameId:f.id,x0:-1200,y0:Int(y+1200),w:1200,h:1200,mmPerPx:2000|RasterPacket.flag,idx:colors)
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
let legacyNode=RouteMapPlan.Node(x:0,y:36000,distance:0)
let legacyBytes=roofPacket(36000)
try cache.store(legacyBytes,frame:f,source:3,node:legacyNode,style:1)
try cache.storeBuildingUpdate(BuildingUpdate(bytes:legacyBytes,coverage:BuildingCoverage(checkedMask:1)),frame:f,source:3,node:legacyNode)
check(cache.buildingUpdate(frame:f,source:3,node:legacyNode,style:1)?.coverage == .legacyFull,"Compatible legacy complete cache outranks a new partial observation")
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
// Complete legacy packets must survive partial observations from the new quality.
let fastPartialBytes=FastBuildings.packet(base:identicalRoads,patches:[0:Data(repeating:1,count:90000)])
var legacyPending=MapHandoffBuffer()
legacyPending.stage(.init(bytes:detailed,cx:0,cy:600,sat:false,type:3,info:"legacy full",source:3,style:1,coverage:.legacyFull))
legacyPending.stage(.init(bytes:fastPartialBytes,cx:0,cy:600,sat:false,type:3,info:"fast partial",source:3,style:1,coverage:BuildingCoverage(checkedMask:1)))
check(legacyPending.pending?.coverage == .legacyFull && legacyPending.pending?.bytes==detailed,"Staged legacy full bytes and coverage survive new-quality partial")
let legacyDeferred=MapFeeder();legacyDeferred.frame=f;legacyDeferred.pose=(0,0,120)
ble.mapBytesPerSecond=1_000_000
legacyDeferred.acceptChunk(testPacket(f,0,0),cx:0,cy:0,sat:false,type:3,info:"base",src:3)
legacyDeferred.onAck(type:3,id:legacyDeferred.chunkId)
legacyDeferred.acceptChunk(detailed,cx:0,cy:600,sat:false,type:3,info:"legacy full",src:3,coverage:.legacyFull)
legacyDeferred.acceptChunk(fastPartialBytes,cx:0,cy:600,sat:false,type:3,info:"fast partial",src:3,coverage:BuildingCoverage(checkedMask:1))
check(legacyDeferred.deferredRoofs?.coverage == .legacyFull && legacyDeferred.deferredRoofs?.bytes==detailed,"Deferred legacy full bytes and coverage survive new-quality partial")
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
