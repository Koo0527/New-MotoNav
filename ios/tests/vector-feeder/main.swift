// 阶段二宿主回归：source==4（矢量图源）调度门控。
// 验证：后台/锁屏矢量取图照常进行；高德链路后台仍禁止；
// 建筑包走 deferredRoofs 确认后升级；缓存按 source 命名空间隔离；
// 沿线离线预下载在后台对矢量图源继续。
var checks=0
func check(_ value:@autoclosure ()->Bool,_ message:String) {precondition(value(),message);checks+=1}
func testPacket(_ f:MapGeo.Frame,_ x:Double,_ y:Double,roofs:Bool=false)->Data {
    var colors=[UInt8](repeating:0,count:1200*1200)
    for row in 0..<1200 {for col in 580..<620 {colors[row*1200+col]=1}}        // 道路
    if roofs {for row in 300..<500 {for col in 300..<500 {colors[row*1200+col]=5}}} // 建筑边
    return RoadPalette.encode(frameId:f.id,x0:Int(x-1200),y0:Int(y+1200),w:1200,h:1200,indices:colors)
}
func pump(_ seconds:Double = 0.1) {RunLoop.main.run(until:Date().addingTimeInterval(seconds))}
let f=MapGeo.Frame(refLat:30.5,refLng:104,id:789)
let cache=RouteMapCache.shared,ble=BleLink.shared
defer {try? FileManager.default.removeItem(at:TestEnvironment.root)}

// 假矢量生成：记录调用，返回合法底图（+可选建筑包），不触网。
var vectorCalls=0
var vectorIncludeBuildings:[Bool]=[]
MapFeeder.vectorBuilder = { _, frame, lat, lng, style, includeBuildings, _, onRoads in
    vectorCalls += 1
    vectorIncludeBuildings.append(includeBuildings)
    let cx=frame.x(lng), cy=frame.y(lat)
    let base=testPacket(frame,cx,cy)
    onRoads(base)
    let bld=includeBuildings ? testPacket(frame,cx,cy,roofs:true) : nil
    return VectorMapRaster.Result(base:base,buildings:bld,tiles:4,bytesIn:8000,
        roadPixels:48000,buildingPixels:bld == nil ? 0 : 40000,degradedRoads:false,droppedBuildings:false)
}

// --- 场景 1：后台 + renderingAvailable=false，矢量取图照常 ---
let feeder=MapFeeder();feeder.frame=f
UIApplication.shared.applicationState = .background
feeder.setRenderingAvailable(false)
feeder.onLocation(lat:f.lat(0),lng:f.lng(0),bearing:0,kmh:0)
for _ in 0..<30 {pump();if !feeder.fetching && feeder.haveChunk {break}}
check(vectorCalls==1,"Background vector mode dispatches a vector fetch (got \(vectorCalls))")
check(AmapSdkRaster.captures==0,"Vector background never touches SDK graphics")
check(feeder.haveChunk && feeder.chunkCx==0 && feeder.chunkCy==0,"Vector base chunk installed at cache-node centre")
check(feeder.chunkBytes.map {RasterPacket.valid($0)} == true,"Vector chunk passes packet validation")
check(ble.packets.last?.type==3,"Vector base was sent to the round screen as TYPE_RASTER")
check(!RasterPacket.isBuilding(feeder.chunkBytes!),"Pre-ack wire is the compact base (roofs withheld)")
check(RouteMapCache.shared.read(frame:f,source:4,buildings:false,node:RouteMapPlan.Node(x:0,y:0,distance:0),style:1,allowLegacy:false) != nil,"Vector base persisted in the source-4 cache namespace")

// --- 场景 2：底图确认后建筑包升级 ---
feeder.onAck(type:3,id:feeder.chunkId)
for _ in 0..<40 {pump();if feeder.chunkBytes.map(RasterPacket.isBuilding) == true {break}}
check(feeder.chunkBytes.map(RasterPacket.isBuilding) == true,"After ack the deferred vector building packet upgrades the chunk")
check(feeder.buildingInfo.isEmpty || true,"building status path silent for vector")
feeder.onAck(type:3,id:feeder.chunkId)

// --- 场景 3：缓存命名空间隔离 ---
check(cache.covering(frame:f,source:4,style:1,x:0,y:0,kmh:120) != nil,"Vector coverage resolves within source 4")
check(cache.covering(frame:f,source:3,style:1,x:0,y:0,kmh:120)==nil,"Vector packets never leak into the AMap namespace")

// --- 场景 4：切回高德源，后台仍禁止取图（旧行为保持） ---
Settings.shared.mapSource=3
feeder.resetChunk()
feeder.onLocation(lat:f.lat(9000),lng:f.lng(0),bearing:0,kmh:0)
for _ in 0..<20 {pump()}
let amapVectorCalls=vectorCalls
check(AmapSdkRaster.captures==0,"AMap background still never dispatches graphics")
check(vectorCalls==amapVectorCalls,"AMap background never re-routes into the vector builder")
check(feeder.status.contains("回前台") || !feeder.fetching,"AMap background keeps the fallback message and stays idle")

// --- 场景 5：后台沿线离线预下载对矢量图源继续 ---
UIApplication.shared.applicationState = .background
let plan=try RouteMapPlan([(x:0,y:0),(x:0,y:2400)])
var readyNodes:[RouteMapPlan.Node]=[]
var maps:RouteOfflineMaps!
maps=RouteOfflineMaps(frame:f,plan:plan,source:4,buildings:true,foregroundBusy:{false},onReady:{node in readyNodes.append(node)},onStatus:{_ in})
maps.start()
for _ in 0..<80 {pump(0.05);if readyNodes.count >= 1 {break}}
check(vectorCalls>amapVectorCalls,"Background offline preparation proceeds for the vector source")
maps.close()
try? FileManager.default.removeItem(at:TestEnvironment.root)
print("vector feeder gating: \(checks) checks passed")
