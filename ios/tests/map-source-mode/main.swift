import Foundation

func check(_ value: @autoclosure () -> Bool, _ message: String) {
    if !value() { fatalError(message) }
}
func pump(_ seconds: Double = 0.12) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

// Stub AmapSdkRaster.build references this helper for its unused success path.
func testPacket(_ f: MapGeo.Frame, _ x: Double, _ y: Double) -> Data {
    var grid = [UInt8](repeating: MapGeo.PX_BLOCK, count: 1200 * 1200)
    for i in 500..<700 { grid[600 * 1200 + i] = MapGeo.PX_ROAD }
    return RoadPalette.encode(frameId: f.id, x0: Int(x) - 1200, y0: Int(y) + 1200,
                              w: 1200, h: 1200, indices: grid)
}

let n = RasterPacket.size
func makePacket(extraBranch: Bool, x0: Int = -1200, y0: Int = 1200, frameId: Int = 77) -> Data {
    var grid = [UInt8](repeating: MapGeo.PX_BLOCK, count: n * n)
    for x in 50..<750 { grid[600 * n + x] = MapGeo.PX_ROAD }
    for y in 50..<750 { grid[y * n + 610] = MapGeo.PX_ROAD }
    if extraBranch { for y in 601..<700 { grid[y * n + 612] = MapGeo.PX_ROAD } }
    return RoadPalette.encode(frameId: frameId, x0: x0, y0: y0, w: n, h: n, indices: grid)
}
let base = makePacket(extraBranch: false)
let fine = makePacket(extraBranch: true)
check(base != fine && RasterPacket.valid(base) && RasterPacket.valid(fine), "sample packets invalid")
check(RasterPacket.valid(base, frame: 77, x: -1200, y: 1200), "base frame/origin mismatch")
check(RasterPacket.hasMapContent(base) && RasterPacket.hasMapContent(fine), "sample packets have no content")
check(MapStyleTransfer.matches(base, style: 1) && MapStyleTransfer.matches(fine, style: 1), "sample style mismatch")

// 0. 锁屏零截图；回前台仍在同一块时只补一次。
let lockFeed = MapFeeder()
Settings.shared.mapOn = true
Settings.shared.buildings = false
Settings.shared.theme = 1
Settings.shared.mapSource = MapSourceMode.amap
let lockFrame = MapGeo.Frame(refLat: 25.6, refLng: 103.2, id: 77)
let lockNode = RouteMapPlan.Node(x: 0, y: 0, distance: 0)
try RouteMapCache.shared.store(base, frame: lockFrame, source: MapSourceMode.amap, node: lockNode, style: 1)
lockFeed.frame = lockFrame
lockFeed.pose = (x: 0, y: 0, kmh: 30)
BleLink.shared.packets = []
BleLink.shared.mapBytesPerSecond = 1_000_000
lockFeed.acceptChunk(base, cx: 0, cy: 0, sat: false, type: MapFeeder.TYPE_RASTER, info: "base", src: MapSourceMode.amap)
lockFeed.onAck(type: lockFeed.chunkType, id: lockFeed.chunkId)
pump()
UIApplication.shared.applicationState = .background
lockFeed.setRenderingAvailable(false)
AmapSdkRaster.captures = 0; AmapSdkRaster.lastFineRoads = nil
lockFeed.onLocation(lat: 25.6, lng: 103.2, bearing: 0, kmh: 30)
pump()
check(AmapSdkRaster.captures == 0, "lock screen must not spend a near capture")
UIApplication.shared.applicationState = .active
lockFeed.setRenderingAvailable(true)
lockFeed.onLocation(lat: 25.6, lng: 103.2, bearing: 0, kmh: 30)
pump()
check(AmapSdkRaster.captures == 1, "foreground same block should capture once")
check(AmapSdkRaster.lastFineRoads == true, "foreground same block should request fine roads")
lockFeed.onLocation(lat: 25.6, lng: 103.2, bearing: 0, kmh: 30)
pump()
check(AmapSdkRaster.captures <= 4, "foreground repeated location must not exceed four quadrant captures")

// 1. 纯图源策略。
for theme in 1...9 {
    check(MapSourceMode.source(theme: theme, navigating: false) == MapSourceMode.vector, "theme \(theme) cruise")
    check(MapSourceMode.source(theme: theme, navigating: true) == MapSourceMode.amap, "theme \(theme) navigation")
}
for theme in [0, 10, 11] {
    check(MapSourceMode.source(theme: theme, navigating: false) == MapSourceMode.amap, "theme \(theme) cruise high德")
    check(MapSourceMode.source(theme: theme, navigating: true) == MapSourceMode.amap, "theme \(theme) navigation high德")
}

// 2. 生产 MapFeeder 的巡航/导航入口切换图源。
let feed = MapFeeder.shared
Settings.shared.mapOn = true
Settings.shared.buildings = false
Settings.shared.theme = 1
Settings.shared.mapSource = MapSourceMode.vector
Settings.shared.navigationActive = false
feed.beginCruise()
check(Settings.shared.mapSource == MapSourceMode.vector, "cruise should use vector")
feed.beginNavigation()
check(Settings.shared.mapSource == MapSourceMode.amap, "navigation should use AMap")
feed.endSession()
check(Settings.shared.mapSource == MapSourceMode.vector, "ending navigation should return to vector cruise")
Settings.shared.theme = 0
feed.beginCruise()
check(Settings.shared.mapSource == MapSourceMode.amap, "native style keeps AMap")
Settings.shared.theme = 1

// 3. 旧图源迟到回调不得覆盖新模式。
feed.resetChunk(); BleLink.shared.packets = []; MapPipelineTrace.names = []
Settings.shared.mapSource = MapSourceMode.vector
feed.acceptChunk(base, cx: 0, cy: 0, sat: false, type: MapFeeder.TYPE_RASTER, info: "stale", src: MapSourceMode.amap)
check(BleLink.shared.packets.isEmpty, "stale AMap callback must be rejected while cruising")
check(MapPipelineTrace.names.contains("map-source-stale"), "stale-source trace missing")

// 4. 缓存按图源隔离。
let frame = MapGeo.Frame(refLat: 25.02, refLng: 102.67, id: 77)
let node = RouteMapPlan.Node(x: 0, y: 0, distance: 0)
let cache = RouteMapCache.shared
try cache.store(base, frame: frame, source: MapSourceMode.amap, node: node, style: 1)
try cache.store(fine, frame: frame, source: MapSourceMode.vector, node: node, style: 1)
check(cache.read(frame: frame, source: MapSourceMode.amap, buildings: false, node: node, style: 1) == base,
      "AMap cache leaked vector packet")
check(cache.read(frame: frame, source: MapSourceMode.vector, buildings: false, node: node, style: 1) == fine,
      "vector cache leaked AMap packet")

// 5. 宽底图在途：增强包暂存，ACK 后只发送一次。
feed.resetChunk(); BleLink.shared.packets = []; MapPipelineTrace.names = []
Settings.shared.mapSource = MapSourceMode.amap
Settings.shared.theme = 1
feed.acceptChunk(base, cx: 0, cy: 0, sat: false, type: MapFeeder.TYPE_RASTER, info: "base", src: MapSourceMode.amap)
let baseCount = BleLink.shared.packets.count
check(baseCount == 1, "base should be sent once")
feed.acceptChunk(fine, cx: 0, cy: 0, sat: false, type: MapFeeder.TYPE_RASTER, info: "fine", src: MapSourceMode.amap,
                 coverage: nil, fineRoads: true)
check(BleLink.shared.packets.count == baseCount, "fine packet must wait while base is in flight")
check(feed.deferredFine != nil, "fine packet should be staged")
feed.onAck(type: feed.chunkType, id: feed.chunkId)
pump()
check(BleLink.shared.packets.count == baseCount + 1, "fine packet should be sent once after ACK")
check(BleLink.shared.packets.last!.bytes == fine, "ACK flush sent the wrong packet")
let fineId = feed.chunkId
feed.onAck(type: feed.chunkType, id: fineId)
pump()
check(BleLink.shared.packets.count == baseCount + 1, "fine packet must not be sent twice")

// 6. 前方道路抢占：手头有道路包时丢弃增强包。
feed.resetChunk(); BleLink.shared.packets = []; MapPipelineTrace.names = []
feed.acceptChunk(base, cx: 0, cy: 0, sat: false, type: MapFeeder.TYPE_RASTER, info: "base", src: MapSourceMode.amap)
feed.acceptChunk(fine, cx: 0, cy: 0, sat: false, type: MapFeeder.TYPE_RASTER, info: "fine", src: MapSourceMode.amap,
                 coverage: nil, fineRoads: true)
feed.handoff.stage(.init(bytes: fine, cx: 1200, cy: 0, sat: false, type: MapFeeder.TYPE_RASTER,
                         info: "ahead", source: MapSourceMode.amap, style: 1))
feed.onAck(type: feed.chunkType, id: feed.chunkId)
pump()
check(!BleLink.shared.packets.contains { $0.bytes == fine }, "road-first must not send the deferred fine packet")
check(MapPipelineTrace.names.contains("fine-dropped"), "road-first drop trace missing")

// 7. 模式切换后丢弃旧增强包。
feed.resetChunk(); BleLink.shared.packets = []; MapPipelineTrace.names = []
Settings.shared.mapSource = MapSourceMode.amap
feed.acceptChunk(base, cx: 0, cy: 0, sat: false, type: MapFeeder.TYPE_RASTER, info: "base", src: MapSourceMode.amap)
feed.acceptChunk(fine, cx: 0, cy: 0, sat: false, type: MapFeeder.TYPE_RASTER, info: "fine", src: MapSourceMode.amap,
                 coverage: nil, fineRoads: true)
check(feed.deferredFine != nil, "fine should be staged before mode switch")
feed.beginCruise()
check(Settings.shared.mapSource == MapSourceMode.vector, "cruise source not restored")
check(feed.deferredFine == nil, "mode switch must drop the stale fine packet")
feed.onAck(type: feed.chunkType, id: feed.chunkId)
pump()
check(!BleLink.shared.packets.contains { $0.bytes == fine }, "stale fine must not be sent after mode switch")

// 8. 正常导航取图入口确实把 fineRoads 传给高德；高速/巡航不补。
feed.resetChunk(); BleLink.shared.packets = []
Settings.shared.mapOn = true
Settings.shared.buildings = false
Settings.shared.theme = 1
Settings.shared.mapSource = MapSourceMode.amap
feed.beginNavigation()
let navFrame = MapGeo.Frame(refLat: 25.11, refLng: 102.81, id: 78)
feed.frame = navFrame
feed.pose = (x: 0, y: 0, kmh: 30)
AmapSdkRaster.captures = 0
AmapSdkRaster.lastFineRoads = nil
AmapSdkRaster.lastIncludeBuildings = nil
feed.fetchChunk(navFrame, 0, 0)
pump()
check(AmapSdkRaster.captures == 1, "navigation fetch should call AMap once")
check(AmapSdkRaster.lastFineRoads == true, "low-speed navigation should request fine roads")
check(AmapSdkRaster.lastIncludeBuildings == false, "buildings-off navigation should not use the building pass")

let fastFrame = MapGeo.Frame(refLat: 25.12, refLng: 102.82, id: 79)
feed.frame = fastFrame
feed.pose = (x: 0, y: 0, kmh: 80)
AmapSdkRaster.captures = 0
AmapSdkRaster.lastFineRoads = nil
feed.fetchChunk(fastFrame, 0, 0)
pump()
check(AmapSdkRaster.captures == 1, "fast navigation fetch should call AMap once")
check(AmapSdkRaster.lastFineRoads == false, "fast navigation must not spend a near capture on fine roads")

// 9. 当前显示块即使带路线节点也补路；前方准备不补。
let displayFeed = MapFeeder()
Settings.shared.mapOn = true
Settings.shared.buildings = false
Settings.shared.theme = 1
Settings.shared.mapSource = MapSourceMode.amap
let displayFrame = MapGeo.Frame(refLat: 25.21, refLng: 102.91, id: 77)
displayFeed.frame = displayFrame
displayFeed.pose = (x: 0, y: 0, kmh: 30)
AmapSdkRaster.captures = 0; AmapSdkRaster.lastFineRoads = nil; AmapSdkRaster.lastPreparedBase = nil
displayFeed.fetchChunk(displayFrame, 0, 0, node: RouteMapPlan.Node(x: 0, y: 0, distance: 0), purpose: .display)
pump()
check(AmapSdkRaster.lastFineRoads == true, "display route block should request fine roads")

let prepareFeed = MapFeeder()
Settings.shared.mapSource = MapSourceMode.amap
let prepareFrame = MapGeo.Frame(refLat: 25.22, refLng: 102.92, id: 77)
prepareFeed.frame = prepareFrame
prepareFeed.pose = (x: 0, y: 0, kmh: 30)
AmapSdkRaster.captures = 0; AmapSdkRaster.lastFineRoads = nil
prepareFeed.fetchChunk(prepareFrame, 0, 0, node: RouteMapPlan.Node(x: 0, y: 0, distance: 0), purpose: .prepare)
pump()
check(AmapSdkRaster.lastFineRoads == false, "ahead preparation must only fetch the wide base")

// 9b. 建筑开启时也跳过细路近景。
Settings.shared.buildings = true
let buildingFeed = MapFeeder()
Settings.shared.mapSource = MapSourceMode.amap
let buildingFrame = MapGeo.Frame(refLat: 25.225, refLng: 102.925, id: 77)
buildingFeed.frame = buildingFrame
buildingFeed.pose = (x: 0, y: 0, kmh: 30)
AmapSdkRaster.captures = 0; AmapSdkRaster.lastFineRoads = nil; AmapSdkRaster.lastIncludeBuildings = nil
buildingFeed.fetchChunk(buildingFrame, 0, 0, node: RouteMapPlan.Node(x: 0, y: 0, distance: 0), purpose: .display)
pump()
check(AmapSdkRaster.lastFineRoads == false, "buildings-on display must not spend a near fine-road capture")
check(AmapSdkRaster.lastIncludeBuildings == true, "buildings-on display should keep the building pass")
Settings.shared.buildings = false

// 10. 只有宽图缓存：先复用宽图作为 preparedBase，再补近景。
let wideFrame = MapGeo.Frame(refLat: 25.23, refLng: 102.93, id: 77)
let wideNode = RouteMapPlan.Node(x: 0, y: 0, distance: 0)
try RouteMapCache.shared.store(base, frame: wideFrame, source: MapSourceMode.amap, node: wideNode, style: 1)
let wideFeed = MapFeeder()
Settings.shared.mapSource = MapSourceMode.amap
wideFeed.frame = wideFrame
wideFeed.pose = (x: 0, y: 0, kmh: 30)
AmapSdkRaster.captures = 0; AmapSdkRaster.lastFineRoads = nil; AmapSdkRaster.lastPreparedBase = nil
wideFeed.fetchChunk(wideFrame, 0, 0, node: wideNode, purpose: .display)
pump()
check(AmapSdkRaster.captures == 1, "wide-cache reuse should still run one AMap build")
check(AmapSdkRaster.lastFineRoads == true, "wide-cache reuse should request the near patch")
check(AmapSdkRaster.lastPreparedBase == base, "wide cache must be reused as preparedBase, not recaptured")

// 11. 已有增强缓存：直接复用，不再取近景。
let fineFrame = MapGeo.Frame(refLat: 25.24, refLng: 102.94, id: 77)
let fineBase = base
try RouteMapCache.shared.store(fineBase, frame: fineFrame, source: MapSourceMode.amap, node: wideNode, style: 1)
try RouteMapCache.shared.store(fine, frame: fineFrame, source: MapSourceMode.amap, node: wideNode, style: 1,
                              fine: RouteMapCache.fineVersion)
try RouteMapCache.shared.storeFineState(RouteMapCache.FineState(
    qualityVersion: FineRoads.version, checkedMask: 0b1111, masks: [:], revision: 1,
    baseDigest: FineRoads.baseDigest(fineBase)), frame: fineFrame, source: MapSourceMode.amap,
    node: wideNode, style: 1)
let fineFeed = MapFeeder()
Settings.shared.mapSource = MapSourceMode.amap
fineFeed.frame = fineFrame
fineFeed.pose = (x: 0, y: 0, kmh: 30)
AmapSdkRaster.captures = 0; AmapSdkRaster.lastFineRoads = nil
fineFeed.fetchChunk(fineFrame, 0, 0, node: wideNode, purpose: .display)
pump()
check(AmapSdkRaster.captures == 0, "existing fine cache must not spend a near capture")

// 11b. 沿线预下载 readPacket 保留缓存类型，供 onReady 走统一准入。
let offlineFrame = MapGeo.Frame(refLat: 25.7, refLng: 103.3, id: 77)
let offlinePlan = try RouteMapPlan([(x: 0, y: 0), (x: 100, y: 100)])
try RouteMapCache.shared.store(fine, frame: offlineFrame, source: MapSourceMode.amap, node: offlinePlan.nodes[0], style: 1,
                              fine: RouteMapCache.fineVersion)
let offlineMaps = RouteOfflineMaps(frame: offlineFrame, plan: offlinePlan, source: MapSourceMode.amap, buildings: false,
                                   foregroundBusy: { false }, onReady: { _ in }, onStatus: { _ in })
check(offlineMaps.readPacket(offlinePlan.nodes[0])?.isFine == true,
      "offline cache read must preserve the fine packet type")

// 12. 宽图 ACK 先到、增强后到：立即走同一准入入口并只发一次。
let ackFeed = MapFeeder()
Settings.shared.mapSource = MapSourceMode.amap
ackFeed.pose = (x: 0, y: 0, kmh: 30)
BleLink.shared.packets = []
ackFeed.acceptChunk(base, cx: 0, cy: 0, sat: false, type: MapFeeder.TYPE_RASTER, info: "base", src: MapSourceMode.amap)
let baseSent = BleLink.shared.packets.count
ackFeed.onAck(type: ackFeed.chunkType, id: ackFeed.chunkId)
pump()
ackFeed.acceptChunk(fine, cx: 0, cy: 0, sat: false, type: MapFeeder.TYPE_RASTER, info: "fine", src: MapSourceMode.amap,
                    coverage: nil, fineRoads: true)
pump()
check(BleLink.shared.packets.count == baseSent + 1, "fine after ACK should send once")
check(BleLink.shared.packets.last!.bytes == fine, "fine after ACK sent wrong packet")
check(ackFeed.deferredFine == nil, "fine after ACK must not remain staged")

// 12b. 宽图已 ACK 后才到增强包，1 B/s 链路必须拒绝。
let ackedSlowFeed = MapFeeder()
Settings.shared.mapSource = MapSourceMode.amap
ackedSlowFeed.pose = (x: 0, y: 0, kmh: 30)
BleLink.shared.packets = []
ackedSlowFeed.acceptChunk(base, cx: 0, cy: 0, sat: false, type: MapFeeder.TYPE_RASTER, info: "base", src: MapSourceMode.amap)
ackedSlowFeed.onAck(type: ackedSlowFeed.chunkType, id: ackedSlowFeed.chunkId)
pump()
let ackedSlowBase = BleLink.shared.packets.count
BleLink.shared.mapBytesPerSecond = 1.0
MapPipelineTrace.names = []
ackedSlowFeed.acceptChunk(fine, cx: 0, cy: 0, sat: false, type: MapFeeder.TYPE_RASTER, info: "fine", src: MapSourceMode.amap,
                          coverage: nil, fineRoads: true)
pump()
check(BleLink.shared.packets.count == ackedSlowBase, "fine after ACK must respect a 1 B/s budget")
check(MapPipelineTrace.names.contains("fine-budget-deferred"), "ACK-after fine budget rejection trace missing")

// 13. 增强先到、慢链路拒绝；独立的充足预算场景发送一次。
let slowFeed = MapFeeder()
Settings.shared.mapSource = MapSourceMode.amap
slowFeed.pose = (x: 0, y: 0, kmh: 30)
BleLink.shared.packets = []
BleLink.shared.mapBytesPerSecond = 1.0
slowFeed.acceptChunk(base, cx: 0, cy: 0, sat: false, type: MapFeeder.TYPE_RASTER, info: "base", src: MapSourceMode.amap)
let slowBase = BleLink.shared.packets.count
slowFeed.acceptChunk(fine, cx: 0, cy: 0, sat: false, type: MapFeeder.TYPE_RASTER, info: "fine", src: MapSourceMode.amap,
                     coverage: nil, fineRoads: true)
slowFeed.onAck(type: slowFeed.chunkType, id: slowFeed.chunkId)
pump()
check(BleLink.shared.packets.count == slowBase, "slow link must defer the fine packet")
check(MapPipelineTrace.names.contains("fine-budget-deferred"), "slow-link defer trace missing")

let fastBudgetFeed = MapFeeder()
Settings.shared.mapSource = MapSourceMode.amap
fastBudgetFeed.pose = (x: 0, y: 0, kmh: 30)
BleLink.shared.packets = []
BleLink.shared.mapBytesPerSecond = 1_000_000
fastBudgetFeed.acceptChunk(base, cx: 0, cy: 0, sat: false, type: MapFeeder.TYPE_RASTER, info: "base", src: MapSourceMode.amap)
fastBudgetFeed.onAck(type: fastBudgetFeed.chunkType, id: fastBudgetFeed.chunkId)
pump()
let fastBase = BleLink.shared.packets.count
fastBudgetFeed.acceptChunk(fine, cx: 0, cy: 0, sat: false, type: MapFeeder.TYPE_RASTER, info: "fine", src: MapSourceMode.amap,
                           coverage: nil, fineRoads: true)
pump()
check(BleLink.shared.packets.count == fastBase + 1, "independent sufficient budget should send exactly once")

// 14. 路线身份替换：旧宽图 ACK 不得触发旧增强包。
let routeFeed = MapFeeder()
Settings.shared.mapSource = MapSourceMode.amap
routeFeed.pose = (x: 0, y: 0, kmh: 30)
BleLink.shared.packets = []
routeFeed.acceptChunk(base, cx: 0, cy: 0, sat: false, type: MapFeeder.TYPE_RASTER, info: "base", src: MapSourceMode.amap)
routeFeed.acceptChunk(fine, cx: 0, cy: 0, sat: false, type: MapFeeder.TYPE_RASTER, info: "fine", src: MapSourceMode.amap,
                      coverage: nil, fineRoads: true)
check(routeFeed.deferredFine != nil, "fine should be staged before route replacement")
routeFeed.prepareRoute(key: "new-route", coords: [(lat: 25.31, lng: 102.95), (lat: 25.32, lng: 102.96)])
check(routeFeed.deferredFine == nil, "route replacement must clear the old fine wait")
routeFeed.onAck(type: routeFeed.chunkType, id: routeFeed.chunkId)
pump()
check(!BleLink.shared.packets.contains { $0.bytes == fine }, "old route ACK must not send the old fine packet")

// 15. 生产 onLocation 沿已规划路线进入当前块也要触发补路。
let locationFeed = MapFeeder()
Settings.shared.mapOn = true
Settings.shared.buildings = false
Settings.shared.theme = 1
Settings.shared.mapSource = MapSourceMode.amap
locationFeed.prepareRoute(key: "onlocation-route", coords: [(lat: 25.41, lng: 103.01), (lat: 25.42, lng: 103.02)])
AmapSdkRaster.captures = 0; AmapSdkRaster.lastFineRoads = nil
locationFeed.onLocation(lat: 25.41, lng: 103.01, bearing: 0, kmh: 30)
pump()
check(AmapSdkRaster.lastFineRoads == true, "onLocation route entry should request fine roads")

// 16. 预存当前路线块的宽图：onLocation 首包用缓存宽图，随后只补一次近景。
let cachedRouteFeed = MapFeeder()
Settings.shared.mapOn = true
Settings.shared.buildings = false
Settings.shared.theme = 1
Settings.shared.mapSource = MapSourceMode.amap
let cachedRouteFrame = MapGeo.Frame(refLat: 25.5, refLng: 103.1, id: 77)
let cachedRouteNode = RouteMapPlan.Node(x: 0, y: 0, distance: 0)
try RouteMapCache.shared.store(base, frame: cachedRouteFrame, source: MapSourceMode.amap, node: cachedRouteNode, style: 1)
cachedRouteFeed.frame = cachedRouteFrame
BleLink.shared.packets = []
AmapSdkRaster.captures = 0; AmapSdkRaster.fineCaptures = 0; AmapSdkRaster.lastFineRoads = nil; AmapSdkRaster.lastPreparedBase = nil
cachedRouteFeed.prepareRoute(key: "cached-route", coords: [(lat: 25.5, lng: 103.1), (lat: 25.51, lng: 103.11)])
cachedRouteFeed.onLocation(lat: 25.5, lng: 103.1, bearing: 0, kmh: 30)
pump()
for _ in 0..<20 { pump(0.05); if !cachedRouteFeed.fetching { break } }
check(BleLink.shared.packets.first?.bytes == base, "first packet should be the cached wide base")
check(AmapSdkRaster.captures == 1, "cached wide display should start exactly one fine capture")
check(AmapSdkRaster.lastFineRoads == true, "cached wide display should request fine roads")
check(AmapSdkRaster.lastPreparedBase == base, "cached wide base should be reused as preparedBase")
cachedRouteFeed.onLocation(lat: 25.5, lng: 103.1, bearing: 0, kmh: 30)
pump()
check(AmapSdkRaster.fineCaptures <= 4, "repeated location must not exceed four fine captures")

// 16b. 沿线 onReady 读到同块增强包：1 B/s 零发送，充足预算只发一次。
let readyFrame = MapGeo.Frame(refLat: 25.8, refLng: 103.4, id: 77)
let readyNode = RouteMapPlan.Node(x: 0, y: 0, distance: 0)
try RouteMapCache.shared.store(base, frame: readyFrame, source: MapSourceMode.amap, node: readyNode, style: 1)
try RouteMapCache.shared.store(fine, frame: readyFrame, source: MapSourceMode.amap, node: readyNode, style: 1,
                               fine: RouteMapCache.fineVersion)
let readyFeed = MapFeeder()
readyFeed.frame = readyFrame
readyFeed.pose = (x: 0, y: 0, kmh: 30)
BleLink.shared.packets = []
BleLink.shared.mapBytesPerSecond = 1_000_000
readyFeed.acceptChunk(base, cx: 0, cy: 0, sat: false, type: MapFeeder.TYPE_RASTER, info: "base", src: MapSourceMode.amap)
readyFeed.onAck(type: readyFeed.chunkType, id: readyFeed.chunkId)
pump()
BleLink.shared.packets = []
BleLink.shared.mapBytesPerSecond = 1.0
MapPipelineTrace.names = []
readyFeed.prepareRoute(key: "ready-fine-route", coords: [(lat: 25.8, lng: 103.4), (lat: 25.81, lng: 103.41)])
pump(0.4)
check(BleLink.shared.packets.filter { $0.bytes == fine }.isEmpty, "onReady fine must respect 1 B/s budget")
check(MapPipelineTrace.names.contains("fine-budget-deferred"), "onReady fine budget rejection trace missing")

let readyFastFrame = MapGeo.Frame(refLat: 25.82, refLng: 103.42, id: 77)
let readyFastNode = RouteMapPlan.Node(x: 0, y: 0, distance: 0)
try RouteMapCache.shared.store(base, frame: readyFastFrame, source: MapSourceMode.amap, node: readyFastNode, style: 1)
try RouteMapCache.shared.store(fine, frame: readyFastFrame, source: MapSourceMode.amap, node: readyFastNode, style: 1,
                               fine: RouteMapCache.fineVersion)
let readyFastFeed = MapFeeder()
readyFastFeed.frame = readyFastFrame
readyFastFeed.pose = (x: 0, y: 0, kmh: 30)
BleLink.shared.packets = []
BleLink.shared.mapBytesPerSecond = 1_000_000
readyFastFeed.acceptChunk(base, cx: 0, cy: 0, sat: false, type: MapFeeder.TYPE_RASTER, info: "base", src: MapSourceMode.amap)
readyFastFeed.onAck(type: readyFastFeed.chunkType, id: readyFastFeed.chunkId)
pump()
BleLink.shared.packets = []
readyFastFeed.prepareRoute(key: "ready-fast-route", coords: [(lat: 25.82, lng: 103.42), (lat: 25.83, lng: 103.43)])
pump(0.4)
check(BleLink.shared.packets.filter { $0.bytes == fine }.count == 1, "onReady cached fine should send exactly once with budget")

// 16c. 预取块未成为当前块时不补路；成为当前块后只补一次。
let prefetchFrame = MapGeo.Frame(refLat: 25.9, refLng: 103.5, id: 77)
let prefetchNode = RouteMapPlan.Node(x: 1200, y: 0, distance: 0)
let prefetchBase = makePacket(extraBranch: false, x0: 0, y0: 1200)
let prefetchFeed = MapFeeder()
prefetchFeed.frame = prefetchFrame
BleLink.shared.packets = []
BleLink.shared.mapBytesPerSecond = 1_000_000
AmapSdkRaster.captures = 0; AmapSdkRaster.fineCaptures = 0; AmapSdkRaster.lastFineRoads = nil; AmapSdkRaster.lastPreparedBase = nil
try RouteMapCache.shared.store(prefetchBase, frame: prefetchFrame, source: MapSourceMode.amap, node: prefetchNode, style: 1)
prefetchFeed.fetchChunk(prefetchFrame, 1200, 0, node: prefetchNode, purpose: .prepare)
for _ in 0..<20 { pump(0.05); if !prefetchFeed.fetching { break } }
check(AmapSdkRaster.fineCaptures == 0, "prefetch block must not spend a near capture")
prefetchFeed.acceptChunk(prefetchBase, cx: 1200, cy: 0, sat: false, type: MapFeeder.TYPE_RASTER, info: "prefetch becomes display", src: MapSourceMode.amap)
prefetchFeed.onAck(type: prefetchFeed.chunkType, id: prefetchFeed.chunkId)
pump()
AmapSdkRaster.captures = 0; AmapSdkRaster.fineCaptures = 0; AmapSdkRaster.lastFineRoads = nil; AmapSdkRaster.lastPreparedBase = nil
MapPipelineTrace.names = []
prefetchFeed.onLocation(lat: prefetchFrame.lat(0), lng: prefetchFrame.lng(1200), bearing: 0, kmh: 30)
pump()
check(AmapSdkRaster.fineCaptures == 1, "prefetch block should request fine after becoming current")
check(AmapSdkRaster.fineCaptures == 1, "prefetch block should capture fine exactly once")
check(AmapSdkRaster.lastFinePreparedBase == prefetchBase, "prefetch block should reuse its wide base")
prefetchFeed.onLocation(lat: prefetchFrame.lat(0), lng: prefetchFrame.lng(1200), bearing: 0, kmh: 30)
pump()
check(AmapSdkRaster.fineCaptures <= 4, "prefetch block must not exceed four fine captures")

// 17. 重连能力窗口：MPAL 确定前不提交 v0；v2 到达后只发一次。
let reconnectFeed = MapFeeder()
Settings.shared.mapOn = true
Settings.shared.buildings = false
Settings.shared.theme = 1
Settings.shared.mapSource = MapSourceMode.amap
let reconnectFrame = MapGeo.Frame(refLat: 26.0, refLng: 104.0, id: 77)
let reconnectNode = RouteMapPlan.Node(x: 0, y: 0, distance: 0)
try RouteMapCache.shared.store(base, frame: reconnectFrame, source: MapSourceMode.amap, node: reconnectNode, style: 1)
reconnectFeed.frame = reconnectFrame
reconnectFeed.pose = (x: 0, y: 0, kmh: 20)
BleLink.shared.packets = []
BleLink.shared.roadPaletteVersion = 0
reconnectFeed.acceptChunk(base, cx: 0, cy: 0, sat: false, type: MapFeeder.TYPE_RASTER, info: "base", src: MapSourceMode.amap)
BleLink.shared.packets = []
reconnectFeed.onLinkReady()
check(reconnectFeed.reconnectMapPending, "reconnect should hold the map for capability negotiation")
check(BleLink.shared.packets.filter { $0.type == MapFeeder.TYPE_RASTER }.isEmpty, "no map before MPAL settles")
BleLink.shared.roadPaletteVersion = 2
reconnectFeed.onRoadPaletteCapability()
let heldMaps = BleLink.shared.packets.filter { $0.type == MapFeeder.TYPE_RASTER }
check(heldMaps.count == 1, "v2 capability should send the held map exactly once")
check(RoadPalette.packetVersion(heldMaps[0].bytes) == 2, "held map should use v2")
reconnectFeed.onRoadPaletteCapability()
check(BleLink.shared.packets.filter { $0.type == MapFeeder.TYPE_RASTER }.count == 1, "repeated v2 must not resend")

// 17b. 无 MPAL 的旧固件：能力窗口到期后按 v0 发送。
let legacyFeed = MapFeeder()
Settings.shared.mapOn = true
Settings.shared.buildings = false
Settings.shared.theme = 1
Settings.shared.mapSource = MapSourceMode.amap
let legacyFrame = MapGeo.Frame(refLat: 26.2, refLng: 104.2, id: 77)
try RouteMapCache.shared.store(base, frame: legacyFrame, source: MapSourceMode.amap, node: RouteMapPlan.Node(x: 0, y: 0, distance: 0), style: 1)
legacyFeed.frame = legacyFrame
legacyFeed.pose = (x: 0, y: 0, kmh: 20)
BleLink.shared.roadPaletteVersion = 0
BleLink.shared.packets = []
legacyFeed.acceptChunk(base, cx: 0, cy: 0, sat: false, type: MapFeeder.TYPE_RASTER, info: "base", src: MapSourceMode.amap)
BleLink.shared.packets = []
legacyFeed.onLinkReady()
check(BleLink.shared.packets.filter { $0.type == MapFeeder.TYPE_RASTER }.isEmpty, "legacy firmware should wait for the capability window")
RunLoop.main.run(until: Date().addingTimeInterval(1.1))
let legacyMaps = BleLink.shared.packets.filter { $0.type == MapFeeder.TYPE_RASTER }
check(legacyMaps.count == 1 && RoadPalette.packetVersion(legacyMaps[0].bytes) == 0, "legacy firmware should fall back to v0 once after one second")

// 18. 迟到 v2：取消旧包、换新 ID，只重发一次。
let lateFeed = MapFeeder()
Settings.shared.mapOn = true
Settings.shared.buildings = false
Settings.shared.theme = 1
Settings.shared.mapSource = MapSourceMode.amap
let lateFrame = MapGeo.Frame(refLat: 26.1, refLng: 104.1, id: 77)
let lateNode = RouteMapPlan.Node(x: 0, y: 0, distance: 0)
try RouteMapCache.shared.store(base, frame: lateFrame, source: MapSourceMode.amap, node: lateNode, style: 1)
lateFeed.frame = lateFrame
lateFeed.pose = (x: 0, y: 0, kmh: 20)
BleLink.shared.packets = []
BleLink.shared.cancels = 0
BleLink.shared.roadPaletteVersion = 0
lateFeed.acceptChunk(base, cx: 0, cy: 0, sat: false, type: MapFeeder.TYPE_RASTER, info: "base", src: MapSourceMode.amap)
BleLink.shared.packets = []
lateFeed.onLinkReady()
lateFeed.flushReconnectMap()
let v0Maps = BleLink.shared.packets.filter { $0.type == MapFeeder.TYPE_RASTER }
check(v0Maps.count == 1 && RoadPalette.packetVersion(v0Maps[0].bytes) == 0, "old capability should send v0 once")
let oldMapId = v0Maps[0].id
BleLink.shared.roadPaletteVersion = 2
lateFeed.onRoadPaletteCapability()
let lateMaps = BleLink.shared.packets.filter { $0.type == MapFeeder.TYPE_RASTER }
check(lateMaps.count == 2, "late v2 should resend once")
check(RoadPalette.packetVersion(lateMaps[1].bytes) == 2 && lateMaps[1].id != oldMapId, "late v2 should use a new id and v2")
check(BleLink.shared.cancels == 1, "late v2 should cancel the old map transfer")
lateFeed.onRoadPaletteCapability()
check(BleLink.shared.packets.filter { $0.type == MapFeeder.TYPE_RASTER }.count == 2, "late v2 repeated must not resend")

// 19. N,3,id 或回执最终超时：同一负载最多完整重试一次。
BleLink.shared.packets = []
lateFeed.onReject(type: MapFeeder.TYPE_RASTER, id: lateFeed.chunkId)
let rejectedMaps = BleLink.shared.packets.filter { $0.type == MapFeeder.TYPE_RASTER }
check(rejectedMaps.count == 1, "first rejection should retry the current map once")
lateFeed.onReject(type: MapFeeder.TYPE_RASTER, id: lateFeed.chunkId)
check(BleLink.shared.packets.filter { $0.type == MapFeeder.TYPE_RASTER }.count == 1, "second rejection must not reopen the retry budget")
lateFeed.onReceiptTimeout(id: lateFeed.chunkId)
check(BleLink.shared.packets.filter { $0.type == MapFeeder.TYPE_RASTER }.count == 1, "timeout after rejection must not reopen the retry budget")

// 20. 未认证时地图重置/新块不得入队；认证后窗口放行。
let gateFeed = MapFeeder()
Settings.shared.mapOn = true
Settings.shared.buildings = false
Settings.shared.theme = 1
Settings.shared.mapSource = MapSourceMode.amap
gateFeed.frame = MapGeo.Frame(refLat: 26.3, refLng: 104.3, id: 77)
gateFeed.pose = (x: 0, y: 0, kmh: 20)
BleLink.shared.packets = []
BleLink.shared.verified = false
BleLink.shared.roadPaletteVersion = 0
BleLink.shared.bulkActive = false
gateFeed.onLinkReady()
gateFeed.resetChunk()
gateFeed.acceptChunk(base, cx: 0, cy: 0, sat: false, type: MapFeeder.TYPE_RASTER, info: "base", src: MapSourceMode.amap)
check(BleLink.shared.packets.filter { $0.type == MapFeeder.TYPE_RASTER }.isEmpty, "unauthenticated reset/new block must not enqueue a map")
check(gateFeed.reconnectMapPending, "authentication should hold the map in the capability window")
BleLink.shared.verified = true
gateFeed.onAuthenticated()
gateFeed.flushReconnectMap()
check(BleLink.shared.packets.filter { $0.type == MapFeeder.TYPE_RASTER }.count == 1, "authenticated window should release the held map once")

// 21. 普通 v0 在途时收到 v2：撤旧余片、换新 ID、只发一次 v2。
let inflightFeed = MapFeeder()
Settings.shared.mapOn = true
Settings.shared.buildings = false
Settings.shared.theme = 1
Settings.shared.mapSource = MapSourceMode.amap
inflightFeed.frame = MapGeo.Frame(refLat: 26.4, refLng: 104.4, id: 77)
inflightFeed.pose = (x: 0, y: 0, kmh: 20)
BleLink.shared.packets = []
BleLink.shared.cancels = 0
BleLink.shared.verified = true
BleLink.shared.refuseBulk = false
BleLink.shared.roadPaletteVersion = 0
inflightFeed.acceptChunk(base, cx: 0, cy: 0, sat: false, type: MapFeeder.TYPE_RASTER, info: "base", src: MapSourceMode.amap)
BleLink.shared.bulkActive = true
let oldInflightId = inflightFeed.chunkId
BleLink.shared.roadPaletteVersion = 2
inflightFeed.onRoadPaletteCapability()
let inflightMaps = BleLink.shared.packets.filter { $0.type == MapFeeder.TYPE_RASTER }
check(inflightMaps.count == 2, "late v2 should take over the in-flight ordinary map")
check(BleLink.shared.cancels == 1 && inflightFeed.chunkId != oldInflightId, "late v2 keeps the ATT slot but uses a new id")
check(RoadPalette.packetVersion(inflightMaps.last!.bytes) == 2, "late v2 takeover should enqueue v2")
BleLink.shared.bulkActive = false
inflightFeed.onRoadPaletteCapability()
check(BleLink.shared.packets.filter { $0.type == MapFeeder.TYPE_RASTER }.count == 2, "repeated v2 after takeover must not resend")

// 22. 首次重试未能入队时不扣预算；实际入队后才允许一次完整重试。
let retryGateFeed = MapFeeder()
Settings.shared.mapOn = true
Settings.shared.buildings = false
Settings.shared.theme = 1
Settings.shared.mapSource = MapSourceMode.amap
retryGateFeed.frame = MapGeo.Frame(refLat: 26.5, refLng: 104.5, id: 77)
retryGateFeed.pose = (x: 0, y: 0, kmh: 20)
BleLink.shared.packets = []
BleLink.shared.bulkActive = false
BleLink.shared.verified = true
BleLink.shared.roadPaletteVersion = 2
BleLink.shared.refuseBulk = false
retryGateFeed.acceptChunk(base, cx: 0, cy: 0, sat: false, type: MapFeeder.TYPE_RASTER, info: "base", src: MapSourceMode.amap)
BleLink.shared.refuseBulk = true
retryGateFeed.onReject(type: MapFeeder.TYPE_RASTER, id: retryGateFeed.chunkId)
check(BleLink.shared.packets.filter { $0.type == MapFeeder.TYPE_RASTER }.count == 1 && retryGateFeed.mapRetryPending && !retryGateFeed.mapRetryUsed, "failed retry enqueue must preserve the budget")
BleLink.shared.refuseBulk = false
retryGateFeed.checkResend()
check(BleLink.shared.packets.filter { $0.type == MapFeeder.TYPE_RASTER }.count == 2 && retryGateFeed.mapRetryUsed && !retryGateFeed.mapRetryPending, "successful retry enqueue consumes the budget once")
retryGateFeed.onReject(type: MapFeeder.TYPE_RASTER, id: retryGateFeed.chunkId)
check(BleLink.shared.packets.filter { $0.type == MapFeeder.TYPE_RASTER }.count == 2, "second failure after an enqueued retry must stay bounded")

// 23. 建筑 v0 重试成功后，ACK 仍要补发一次 v2（按实际 wire 版本而不是当前能力）。
let buildingPkt = FastBuildings.packet(base: base, patches: [0: Data(repeating: 1, count: 90000)])
check(RasterPacket.isBuilding(buildingPkt), "building fixture carries the roof flag")
let upgradeBuildingFeed = MapFeeder()
Settings.shared.mapOn = true
Settings.shared.buildings = false
Settings.shared.theme = 1
Settings.shared.mapSource = MapSourceMode.amap
upgradeBuildingFeed.frame = MapGeo.Frame(refLat: 26.6, refLng: 104.6, id: 77)
upgradeBuildingFeed.pose = (x: 0, y: 0, kmh: 20)
BleLink.shared.packets = []
BleLink.shared.cancels = 0
BleLink.shared.verified = true
BleLink.shared.refuseBulk = false
BleLink.shared.bulkActive = false
BleLink.shared.roadPaletteVersion = 0
upgradeBuildingFeed.acceptChunk(buildingPkt, cx: 0, cy: 0, sat: false, type: MapFeeder.TYPE_RASTER, info: "building", src: MapSourceMode.amap, coverage: BuildingCoverage(checkedMask: 1))
let firstBuilding = BleLink.shared.packets.filter { $0.type == MapFeeder.TYPE_RASTER }
check(firstBuilding.count == 1 && RoadPalette.packetVersion(firstBuilding[0].bytes) == 0, "building starts in v0")
let firstBuildingId = upgradeBuildingFeed.chunkId
BleLink.shared.roadPaletteVersion = 2
upgradeBuildingFeed.onRoadPaletteCapability()
check(BleLink.shared.packets.filter { $0.type == MapFeeder.TYPE_RASTER }.count == 1, "building first packet stays protected from capability cancellation")
upgradeBuildingFeed.onReject(type: MapFeeder.TYPE_RASTER, id: firstBuildingId)
let buildingRetry = BleLink.shared.packets.filter { $0.type == MapFeeder.TYPE_RASTER }
check(buildingRetry.count == 2 && RoadPalette.packetVersion(buildingRetry[1].bytes) == 0, "building retry reuses the v0 wire bytes")
check(upgradeBuildingFeed.lastMapPaletteVersion == 0, "retry records the actually enqueued v0 version")
upgradeBuildingFeed.onAck(type: MapFeeder.TYPE_RASTER, id: upgradeBuildingFeed.chunkId)
pump()
let buildingAfterAck = BleLink.shared.packets.filter { $0.type == MapFeeder.TYPE_RASTER }
check(buildingAfterAck.count == 3 && RoadPalette.packetVersion(buildingAfterAck[2].bytes) == 2, "ACK after building v0 retry sends v2 exactly once")
upgradeBuildingFeed.onRoadPaletteCapability()
check(BleLink.shared.packets.filter { $0.type == MapFeeder.TYPE_RASTER }.count == 3, "repeated v2 after building upgrade stays deduplicated")

// 24. 建筑重试最终失败、旧槽释放且无新定位时，仍补发一次 v2。
let failedBuildingFeed = MapFeeder()
Settings.shared.mapOn = true
Settings.shared.buildings = false
Settings.shared.theme = 1
Settings.shared.mapSource = MapSourceMode.amap
failedBuildingFeed.frame = MapGeo.Frame(refLat: 26.7, refLng: 104.7, id: 77)
failedBuildingFeed.pose = (x: 0, y: 0, kmh: 20)
BleLink.shared.packets = []
BleLink.shared.verified = true
BleLink.shared.refuseBulk = false
BleLink.shared.bulkActive = false
BleLink.shared.roadPaletteVersion = 0
failedBuildingFeed.acceptChunk(buildingPkt, cx: 0, cy: 0, sat: false, type: MapFeeder.TYPE_RASTER, info: "building", src: MapSourceMode.amap, coverage: BuildingCoverage(checkedMask: 1))
let failedFirstId = failedBuildingFeed.chunkId
BleLink.shared.roadPaletteVersion = 2
failedBuildingFeed.onRoadPaletteCapability()
failedBuildingFeed.onReject(type: MapFeeder.TYPE_RASTER, id: failedFirstId)
check(BleLink.shared.packets.filter { $0.type == MapFeeder.TYPE_RASTER }.count == 2, "first building retry enqueues v0")
failedBuildingFeed.onReject(type: MapFeeder.TYPE_RASTER, id: failedBuildingFeed.chunkId)
let failedBuildingPackets = BleLink.shared.packets.filter { $0.type == MapFeeder.TYPE_RASTER }
check(failedBuildingPackets.count == 3 && RoadPalette.packetVersion(failedBuildingPackets[2].bytes) == 2, "final building failure still releases one v2 upgrade")
failedBuildingFeed.onReject(type: MapFeeder.TYPE_RASTER, id: failedFirstId)
check(BleLink.shared.packets.filter { $0.type == MapFeeder.TYPE_RASTER }.count == 3, "final building failure upgrade must not repeat")

// 25. ACK ownership follows successful enqueue and the current wire ID.
let ackOwner = MapFeeder()
ackOwner.beginNavigation()
ackOwner.pose = (x: 0, y: 0, kmh: 30)
let ackLink = BleLink.shared
ackLink.packets = []
ackLink.mapBytesPerSecond = 1_000_000
var receiptLink = TestReceiptLink()
ackOwner.acceptChunk(base, cx: 0, cy: 0, sat: false, type: 3, info: "old wide", src: MapSourceMode.amap)
let previousId = ackOwner.chunkId
receiptLink.mapReceipt.begin(id: previousId, tail: Data())
let nextWide = makePacket(extraBranch: false, x0: -600)
let nextFine = makePacket(extraBranch: true, x0: -600)
ackLink.refuseBulk = true
ackOwner.pose = (x: 600, y: 0, kmh: 30)
ackOwner.acceptChunk(nextWide, cx: 600, cy: 0, sat: false, type: 3, info: "new wide", src: MapSourceMode.amap)
ackOwner.acceptChunk(nextFine, cx: 600, cy: 0, sat: false, type: 3, info: "new fine", src: MapSourceMode.amap, fineRoads: true)
check(ackOwner.pendingChunkId != nil && ackLink.packets.count == 1, "new wide must remain pending after refused enqueue")
ackLink.refuseBulk = false
receiptLink.notify("K,3,\(previousId)", target: ackOwner)
check(receiptLink.mapReceipt.current == nil && !ackOwner.chunkAcked,
      "an old receipt still tracked by BLE must not confirm the selected block")
receiptLink.notify("K,3,\(previousId)", target: ackOwner)
ackOwner.onAck(type: 3, id: previousId)
pump()
check(!ackOwner.chunkAcked && ackOwner.confirmedCenter == nil && ackLink.packets.count == 1,
      "old ACK must not confirm the new unqueued block or release its fine packet")
ackOwner.checkResend()
let wideId = ackOwner.chunkId
check(wideId != previousId && ackLink.packets.last?.bytes == nextWide, "recovery must enqueue the wide packet first")
ackOwner.onReject(type: 3, id: wideId)
let retryId = ackOwner.chunkId
check(retryId != wideId && ackLink.packets.last?.bytes == nextWide && ackOwner.mapRetryUsed,
      "retry must enqueue the same wide packet with a new ID")
receiptLink.mapReceipt.begin(id: retryId, tail: Data())
receiptLink.notify("K,3,\(wideId)", target: ackOwner)
ackOwner.onAck(type: 3, id: wideId)
check(!ackOwner.chunkAcked && receiptLink.mapReceipt.current?.id == retryId, "old ACK must preserve the retry receipt")
receiptLink.notify("K,3,\(retryId)", target: ackOwner)
pump()
ackOwner.onAck(type: 3, id: retryId)
pump()
check(ackLink.packets.filter { $0.bytes == nextFine }.count == 1, "retry ACK must release fine exactly once")
let disconnectedId = ackOwner.chunkId
ackLink.verified = false
ackLink.connectionGeneration += 1
ackOwner.onLinkReady()
ackOwner.onAck(type: 3, id: disconnectedId)
check(!ackOwner.chunkAcked, "old connection ACK must not confirm the map during reconnect")
ackLink.verified = true
ackOwner.onAuthenticated()
check(ackOwner.chunkId != disconnectedId, "reconnect must enqueue under a fresh ID")
ackOwner.onAck(type: 3, id: ackOwner.chunkId)
check(ackOwner.chunkAcked, "new connection ACK must confirm the resent map")
ackOwner.endSession()
pump()

// 26. Offline building capture must preserve the independent wide and fine files.
let splitFrame = MapGeo.Frame(refLat: 27.0, refLng: 104.9, id: 77)
let splitPlan = try RouteMapPlan([(x: 0.0, y: 0.0), (x: 0.0, y: 0.0)])
let splitNode = splitPlan.nodes[0]
let splitCache = RouteMapCache.shared
try splitCache.store(base, frame: splitFrame, source: MapSourceMode.amap, node: splitNode, style: 1)
try splitCache.store(fine, frame: splitFrame, source: MapSourceMode.amap, node: splitNode, style: 1,
                     fine: RouteMapCache.fineVersion)
let splitOffline = RouteOfflineMaps(frame: splitFrame, plan: splitPlan, source: MapSourceMode.amap, buildings: true,
                                    foregroundBusy: { false }, onReady: { _ in }, onStatus: { _ in })
AmapSdkRaster.lastPreparedBase = nil
splitOffline.start()
pump(0.3)
splitOffline.close()
check(AmapSdkRaster.lastPreparedBase == base, "building prefetch must use the original wide packet")
check(splitCache.readWide(frame: splitFrame, source: MapSourceMode.amap, node: splitNode) == base,
      "building prefetch must preserve the wide file")
check(splitCache.readFine(frame: splitFrame, source: MapSourceMode.amap, node: splitNode) == fine,
      "building prefetch must preserve the enhancement file")
let fineOnlyFrame = MapGeo.Frame(refLat: 27.05, refLng: 104.95, id: 77)
try splitCache.store(fine, frame: fineOnlyFrame, source: MapSourceMode.amap, node: splitNode, style: 1,
                     fine: RouteMapCache.fineVersion)
let fineOnlyOffline = RouteOfflineMaps(frame: fineOnlyFrame, plan: splitPlan, source: MapSourceMode.amap, buildings: true,
                                       foregroundBusy: { false }, onReady: { _ in }, onStatus: { _ in })
AmapSdkRaster.lastPreparedBase = fine
fineOnlyOffline.start()
pump(0.3)
fineOnlyOffline.close()
check(AmapSdkRaster.lastPreparedBase == nil && splitCache.readFine(frame: fineOnlyFrame, source: MapSourceMode.amap,
                                                                  node: splitNode) == fine,
      "fine-only cache must request a wide capture while preserving its fine packet")

// 27. A busy road job postpones the fine check. Stable fixes after the attempt use memory only.
enum CacheReadProbe {
    static var reads = 0
    static func record(_ id: Int) { if id == 177 { reads += 1 } }
}
let stableFeed = MapFeeder()
stableFeed.beginNavigation()
let stableFrame = MapGeo.Frame(refLat: 27.1, refLng: 105.0, id: 177)
stableFeed.frame = stableFrame
let stableWide = makePacket(extraBranch: false, frameId: stableFrame.id)
try splitCache.store(stableWide, frame: stableFrame, source: MapSourceMode.amap, node: splitNode, style: 1)
stableFeed.acceptChunk(stableWide, cx: 0, cy: 0, sat: false, type: 3, info: "wide", src: MapSourceMode.amap)
stableFeed.onAck(type: 3, id: stableFeed.chunkId)
pump()
stableFeed.fetching = true
let captureBaseline = AmapSdkRaster.fineCaptures
stableFeed.onLocation(lat: 27.1, lng: 105.0, bearing: 0, kmh: 0)
check(AmapSdkRaster.fineCaptures == captureBaseline, "busy road preparation must defer optional capture")
stableFeed.fetching = false
stableFeed.onLocation(lat: 27.1, lng: 105.0, bearing: 0, kmh: 0)
pump()
check(AmapSdkRaster.fineCaptures == captureBaseline + 1, "current block can capture once when roads yield")
// The current view overlaps all four quadrants; drive them to completion,
// then verify stable fixes are memory-only.
for _ in 0..<12 { stableFeed.onLocation(lat: 27.1, lng: 105.0, bearing: 0, kmh: 0); pump() }
check(AmapSdkRaster.fineCaptures == captureBaseline + 4,
      "one capture per covered quadrant, no more than four")
CacheReadProbe.reads = 0
for _ in 0..<10 { stableFeed.onLocation(lat: 27.1, lng: 105.0, bearing: 0, kmh: 0) }
check(CacheReadProbe.reads == 0 && AmapSdkRaster.fineCaptures == captureBaseline + 4,
      "stable fixes after all quadrants are complete must not reread the cache or capture again")

// 28. An acknowledged fine display must not be replaced by the same wide base.
let rollbackFeed = MapFeeder()
Settings.shared.mapOn = true
Settings.shared.buildings = false
Settings.shared.theme = 1
Settings.shared.mapSource = MapSourceMode.amap
rollbackFeed.pose = (x: 0, y: 0, kmh: 30)
BleLink.shared.packets = []
BleLink.shared.mapBytesPerSecond = 1_000_000
rollbackFeed.acceptChunk(base, cx: 0, cy: 0, sat: false, type: MapFeeder.TYPE_RASTER, info: "base", src: MapSourceMode.amap)
rollbackFeed.onAck(type: MapFeeder.TYPE_RASTER, id: rollbackFeed.chunkId)
pump()
rollbackFeed.acceptChunk(fine, cx: 0, cy: 0, sat: false, type: MapFeeder.TYPE_RASTER, info: "fine", src: MapSourceMode.amap,
                         coverage: nil, fineRoads: true)
pump()
rollbackFeed.onAck(type: MapFeeder.TYPE_RASTER, id: rollbackFeed.chunkId)
pump()
check(rollbackFeed.chunkBytes == fine, "fine display should be active before rollback probe")
let rollbackPackets = BleLink.shared.packets.count
MapPipelineTrace.names = []
rollbackFeed.acceptChunk(base, cx: 0, cy: 0, sat: false, type: MapFeeder.TYPE_RASTER, info: "wide echo", src: MapSourceMode.amap)
check(rollbackFeed.chunkBytes == fine && BleLink.shared.packets.count == rollbackPackets,
      "wide base echo must not replace an active fine display")
check(MapPipelineTrace.names.contains("fine-wide-rollback-blocked"), "rollback rejection trace missing")

print("PASS map source mode, cache isolation, stale callback and fine ACK staging")
