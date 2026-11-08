import Foundation
import UIKit

/// 版本：跟随 App 版本（见 Config.swift，iOS v0.2 新增；和安卓版 MapFeeder.kt 一样）
///
/// 小地图数据：
/// - 导航时下载当前位置附近约 2.4 公里见方的地图（高德 SDK 截图底图），
///   快开出这一块时自动下载下一块（向前方偏移，前面的路多下载一些）。
/// - 选了“卫星图”风格时改下高德卫星照片（范围小一些：半边 700 米）。
/// - 导航路线（连同路上的红绿灯位置）单独打包发给圆屏。
/// - iOS v0.3 原路线（导入的高德分享路线）：大块数据类型 4，圆屏画成橙色细线；"#o" 不显示
/// - 每次定位把当前位置、朝向、车速发给圆屏："#p,坐标系,x分米,y分米,朝向,车速"。
/// - 圆屏收齐一份地图/路线后回 "K,类型,编号"；没确认的 8 秒后重发，重连后也全部重发。
/// 状态都在主线程里读写，下载和计算在后台队列里做。
final class MapFeeder: ObservableObject {
    static let shared = MapFeeder()

    private let HALF = 1200.0            // 地图块半边长（米）
    private let REFRESH = 650.0          // 离地图块中心超过这个距离就准备下一块
    private let AHEAD = 450.0            // 新地图块中心往前方偏移
    private let SAT_HALF = 700.0         // 卫星图地图块半边长（米）
    private let SAT_REFRESH = 330.0
    private let SAT_AHEAD = 260.0
    static let MAX_BYTES = 190_000       // 圆屏线条地图缓冲 200KB，留余量
    static let MAX_FEAT = 7000
    private let RESEND = 8.0             // 秒

    static let TYPE_CHUNK = 1
    static let TYPE_ROUTE = 2
    static let TYPE_RASTER = 3
    static let TYPE_GHOST = 4

    static let SRC_AMAP = MapSourceMode.amap
    static let SRC_VECTOR = MapSourceMode.vector
    static let THEME_SAT = 10

    @Published var status = "（导航时自动下载附近地图）"
    @Published var offlineStatus = "选择路线后，在前台自动准备沿线离线底图"
    @Published var chunkInfo = ""
    @Published var buildingInfo = ""
    @Published var routeInfo = ""
    @Published var chunkAcked = false
    @Published var routeAcked = false

    private let worker = DispatchQueue(label: "motonav.map", qos: .userInitiated)
    private(set) var frame: MapGeo.Frame?

    // 当前地图块
    private var chunkCx = 0.0, chunkCy = 0.0
    private var haveChunk = false
    private var fetching = false
    private var fetchingCenter: (x: Double, y: Double)?
    private var fetchingBaseReady = false
    private var lastFetchFail = Date.distantPast
    private var lastBuildingTry = Date.distantPast
    private var chunkId = 0
    private var nextChunkId = 0
    private var chunkType = TYPE_CHUNK
    private var chunkBytes: Data?
    private var chunkRoadBytes=0
    private var chunkStyle:Int?
    private var handoff=MapHandoffBuffer()
    private var chunkSat = false
    private var chunkSentAt = Date.distantPast
    /// 重连/认证后的能力协商窗口：先不提交底图，避免在 MPAL 未知时先发 v0。
    private var reconnectMapPending = false
    private var reconnectMapAt: Date?
    private var lastMapPaletteVersion = -1
    private var mapRetryUsed = false
    private var mapSendPending = false
    private var mapRetryPending = false
    private var mapFinalFailure = false
    private var capabilityUpgradePending = false
    private var pendingChunkId: Int?
    private var awaitingMapAck: (id: Int, connection: Int)?

    // 当前路线
    private var routeKey = ""
    private var routeBuildSerial = 0
    private var routeId = 0
    private var routeBytes: Data?
    private var routeSentAt = Date.distantPast

    // 原路线
    private var ghostCoords: [(lat: Double, lng: Double)]?   // 还没有坐标系时先存着
    private var ghostId = 0
    private var ghostBytes: Data?
    private var ghostAcked = false
    private var ghostSentAt = Date.distantPast

    private var lastBearing: Double?
    private var requestSerial = 0
    private var workToken = MapWorkToken()
    private var offlineMaps: RouteOfflineMaps?
    private var preparedKey = ""
    private var preparedCoords: [(lat: Double, lng: Double)] = []
    private var offlineKey = ""
    private var routeProgress = -1.0
    private var pose: (x: Double, y: Double, kmh: Int)?
    private var chunkBuildingsComplete = false
    private var chunkBuildingPacket = false
    private var paletteResendPending = false
    private var lastWire:Data?
    private var chunkCoverage: BuildingCoverage?
    private var captureStyle: Int?
    private var captureSource: Int?
    private var captureBuildings = false
    private var lastRoofUpgradeProbe=Date.distantPast
    private var deferredRoofs:MapHandoffBuffer.Packet?
    /// 宽底图在途时收到的同块细路增强包；带宽底图传输 ID、请求序号和路线代次。
    private struct DeferredFine {
        let packet: MapHandoffBuffer.Packet
        var chunkId: Int?
        let requestSerial: Int
        let epoch: Int
        let revision: Int
    }
    private var deferredFine: DeferredFine?
    private var fineEpoch = 0
    private var fineAttempted = Set<String>()
    private var fineSubmitted = Set<String>()
    private var fineFailures: [String: (count: Int, next: Date)] = [:]
    private var chunkIsFine = false
    private var chunkBaseDigest = ""
    private var fineCacheChecked = false
    enum FetchPurpose { case display, prepare }
    private var upgradeBase:(packet:MapHandoffBuffer.Packet,id:Int)?
    private var confirmedCenter: (x: Double, y: Double)?
    private var lastCoverageTrace = Date.distantPast
    private var lastLocationAt: Date?
    private var renderingAvailable=true
    /// 允许 SDK 渲染：高德截图流水线需要前台 + 图形可用（矢量图源不受此限）。
    private var canCapture:Bool {renderingAvailable && UIApplication.shared.applicationState == .active}
    /// 允许准备地图：矢量图源只需 CPU + 网络，后台也允许；高德仍走 canCapture。
    private var mayPrepareMaps:Bool {Settings.shared.mapSource == Self.SRC_VECTOR || canCapture}
    /// 会产出普通 RASTER 块（覆盖/预取/取消判定对两种图源同样适用；卫星图由 !satMode 排除）。
    private var liveRaster:Bool {let s=Settings.shared.mapSource;return s == Self.SRC_AMAP || s == Self.SRC_VECTOR}
    private var paletteMode:Bool {[Self.SRC_AMAP, Self.SRC_VECTOR].contains(Settings.shared.mapSource) && AmapCapturePolicy.supportsBuildings(Settings.shared.theme)}
    private var chunkCurrent:Bool {chunkBytes.map {RouteMapCache.isCurrent($0,source:Settings.shared.mapSource,style:Settings.shared.theme)} ?? false}
    private var buildingMode: Bool { AmapCapturePolicy.supportsBuildings(Settings.shared.theme) && [Self.SRC_AMAP, Self.SRC_VECTOR].contains(Settings.shared.mapSource) && Settings.shared.buildings && BleLink.shared.buildingsSupported }

    // MARK: - 矢量图源（OpenFreeMap，阶段二接入）    /// 共享矢量瓦片客户端（TileJSON 模板 + 数据代次 + 瓦片内存 LRU + 磁盘引导）。
    /// 引导记录落在 Application Support/OpenFreeMap（原子写、排除备份、首次解锁后可读）；
    /// 客户端诊断事件（瓦片来源/字节/失败原因，均匿名散列）直接进地图诊断管道。
    static let vectorTiles: VectorTileClient = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("OpenFreeMap", isDirectory: true)
        let client = VectorTileClient(bootstrapDirectory: base,
                                      tileDiskDirectory: base?.appendingPathComponent("tiles", isDirectory: true))
        client.onEvent = { name, fields in MapPipelineTrace.event(name, fields) }
        return client
    }()
    private static let vectorBootstrapLock = NSLock()
    /// 首次矢量取图前引导；已就绪直接返回。距上次验证超 24 小时联网重验，
    /// 刷新失败保留最后有效模板（客户端内部处理），此处只负责并发首调串行化。
    static func ensureVectorTiles() throws {
        vectorBootstrapLock.lock(); defer { vectorBootstrapLock.unlock() }
        vectorTiles.ensureReady()
    }
    /// 矢量生成入口：默认实现先拉 TileJSON 再调 VectorMapRaster.build；
    /// 宿主测试替换此闭包注入离线假结果，验证调度门控而不触网。
    static var vectorBuilder: (_ client: VectorTileClient, _ frame: MapGeo.Frame, _ centerLat: Double, _ centerLng: Double, _ style: Int, _ includeBuildings: Bool, _ isCancelled: @escaping () -> Bool, _ onRoadsReady: @escaping (Data) -> Void) throws -> VectorMapRaster.Result = { client, frame, centerLat, centerLng, style, includeBuildings, isCancelled, onRoadsReady in
        try ensureVectorTiles()
        return try VectorMapRaster.build(client: client, frame: frame, centerLat: centerLat, centerLng: centerLng,
            style: style, includeBuildings: includeBuildings, isCancelled: isCancelled, onRoadsReady: onRoadsReady)
    }
    /// 矢量源缓存读：巡航滚动缓存（64 MiB 块级 LRU）优先，未命中回退旧 512MB 层；
    /// 旧层命中即校验后按需导入巡航缓存（不批量迁移）。内存索引先判 miss，连续定位零磁盘。
    static func cruiseOrLegacyPacket(_ f: MapGeo.Frame, source: Int, node: RouteMapPlan.Node, style: Int) -> RouteMapCache.CachedPacket? {
        guard source == SRC_VECTOR else { return nil }
        let gen = vectorTiles.dataGeneration
        if !gen.isEmpty,
           let base = CruiseMapCache.shared.read(kind: "base", source: source, generation: gen,
                                                 frame: f, style: style, quality: CruiseMapCache.qualityVersion,
                                                 cx: node.x, cy: node.y) {
            return RouteMapCache.CachedPacket(bytes: base, isFine: false)
        }
        guard let legacy = RouteMapCache.shared.readPacket(frame: f, source: source, buildings: false,
                                                           node: node, style: style) else { return nil }
        if !gen.isEmpty, RouteMapCache.isCurrent(legacy.bytes, source: source, style: style) {
            let frame = f, n = node, st = style
            DispatchQueue.global(qos: .utility).async {
                CruiseMapCache.shared.store(legacy.bytes, kind: "base", source: source, generation: gen,
                                            frame: frame, style: st, quality: CruiseMapCache.qualityVersion,
                                            cx: n.x, cy: n.y)
            }
        }
        return legacy
    }


    private var enabled: Bool { Settings.shared.mapOn }
    private var satMode: Bool { Settings.shared.theme == MapFeeder.THEME_SAT }

    /// Preserve prepared offline packets when navigation starts.
    func onNaviStart() { routeKey = ""; clearFineSession() }
    /// 巡航模式：普通主题 1-9 用 OpenFreeMap（亮屏/锁屏同一链路）。
    func beginCruise() {
        Settings.shared.setNavigationActive(false)
        onNaviStart()
    }
    /// 导航模式：圆屏底图和沿线预下载使用高德；图源切换会取消旧任务并重建预下载。
    func beginNavigation() {
        Settings.shared.setNavigationActive(true)
        onNaviStart()
    }
    /// 导航/巡航结束：先停旧预下载，再回到巡航图源（普通主题 1-9 → OpenFreeMap）。
    func endSession() {
        onNaviEnd()
        Settings.shared.setNavigationActive(false)
    }
    /// 路线/会话/主题/图源变化时废弃细路等待项；旧 ACK 不得触发旧路线增强。
    private func clearFineSession() {
        deferredFine = nil
        fineEpoch &+= 1
        fineAttempted.removeAll()
        fineSubmitted.removeAll()
        fineFailures.removeAll()
        chunkIsFine = false; chunkBaseDigest = ""
        fineCacheChecked = false
    }
    private func fineKey(_ f: MapGeo.Frame, _ node: RouteMapPlan.Node, source: Int, style: Int, quadrant: Int = -1) -> String {
        "\(f.id)|\(f.refLat)|\(f.refLng)|\(source)|\(style)|\(Int(node.x.rounded()))|\(Int(node.y.rounded()))|\(quadrant)"
    }
    private func fineSubmitKey(_ cx: Double, _ cy: Double, source: Int, style: Int, revision: Int = 0) -> String {
        "\(pendingChunkId ?? chunkId)|\(source)|\(style)|\(Int(cx.rounded()))|\(Int(cy.rounded()))|\(revision)"
    }
    /// 宽图缓存已经上屏后，当前显示块只差近景时再启动一次 display 取图。
    /// 先通过缓存类型判断已有增强包；前方道路忙或已有缓存时不动。
    private func triggerFineForDisplay(_ f: MapGeo.Frame, node: RouteMapPlan.Node) {
        guard enabled, Settings.shared.mapSource == Self.SRC_AMAP, !Settings.shared.buildings,
              (1...3).contains(Settings.shared.theme), canCapture,
              let pose, pose.kmh < 60, handoff.pending == nil, !fetching, haveChunk,
              MapCoveragePolicy.covers(x: pose.x, y: pose.y, cx: node.x, cy: node.y,
                                       kmh: max(120, pose.kmh), margin: 50) else { return }
        let src = Settings.shared.mapSource, style = Settings.shared.theme
        guard abs(chunkCx-node.x) < 1, abs(chunkCy-node.y) < 1 else { return }
        let cache = RouteMapCache.shared
        let digest = cache.readWide(frame: f, source: src, node: node, style: style)
            .map(FineRoads.baseDigest)
        let state = digest.flatMap {
            cache.readFineState(frame: f, source: src, node: node, style: style, baseDigest: $0)
        }
        let coverage = state.map {
            FineRoads.FineRoadCoverage(qualityVersion: $0.qualityVersion, checkedMask: $0.checkedMask)
        } ?? FineRoads.FineRoadCoverage()
        guard !coverage.isComplete else { return }
        let view = BuildingView(x: pose.x, y: pose.y, bearing: lastBearing,
                                radius: MapCoveragePolicy.radius(kmh: pose.kmh))
        let order = FineRoads.quadrantOrder(view: view, cx: node.x, cy: node.y,
                                            bearing: pose.kmh >= 4 ? lastBearing : nil, kmh: pose.kmh)
        var selected: Int?
        for q in order where !coverage.contains(q) {
            let key = fineKey(f, node, source: src, style: style, quadrant: q)
            if fineAttempted.contains(key) { continue }
            if let failure = fineFailures[key], failure.count >= 2 || Date() < failure.next { continue }
            selected = q
            break
        }
        guard let q = selected else { return }
        fetchChunk(f, node.x, node.y, node: node, purpose: .display, fineQuadrant: q)
    }
    /// Cache reads and BLE keep running while UIKit/SDK graphics are unavailable.
    /// 矢量图源不需要图形栈：进后台不打断在途取图与沿线预下载（锁屏巡航补图的关键差异）。
    func setRenderingAvailable(_ active:Bool) {
        renderingAvailable=active
        if !active {
            if Settings.shared.mapSource != Self.SRC_VECTOR {
                workToken.cancel();requestSerial += 1;fetching=false
                offlineMaps?.suspendCapture()
            }
            AmapCaptureHost.shared.cancel()
            MapPipelineTrace.event("rendering-paused")
        } else {
            lastFetchFail = .distantPast;lastBuildingTry = .distantPast
            fineAttempted.removeAll()
            offlineMaps?.resumeCapture()
            MapPipelineTrace.event("rendering-resumed")
        }
    }
    func onNaviEnd() {
        offlineMaps?.close(); offlineMaps = nil; offlineKey = ""
        handoff.clear()
        deferredRoofs=nil;upgradeBase=nil;clearFineSession()
        preparedCoords = []; preparedKey = ""; offlineStatus = "沿线下载已暂停，重新选择路线后继续"
        workToken.cancel(); requestSerial += 1; routeBuildSerial += 1; fetching = false
    }
    func resetChunk() {
        Settings.shared.syncBuildingContinuity()
        let reuseCapture = fetching && captureStyle.map { [1,2,3].contains($0) } == true && [1,2,3].contains(Settings.shared.theme) && captureSource == Settings.shared.mapSource && captureBuildings == buildingMode && enabled
        handoff.clear();confirmedCenter=nil;deferredRoofs=nil;upgradeBase=nil;lastRoofUpgradeProbe = .distantPast
        clearFineSession()
        buildingInfo = ""; lastBuildingTry = .distantPast
        if !reuseCapture { workToken.cancel(); requestSerial += 1; fetching = false }
        haveChunk = false; lastFetchFail = .distantPast
        chunkBytes=nil;chunkStyle=nil;chunkAcked=false;chunkCoverage=nil;chunkBuildingsComplete=false;chunkBuildingPacket=false;paletteResendPending=false;lastWire=nil
        mapSendPending=true; mapRetryPending=false; mapRetryUsed=false; mapFinalFailure=false; capabilityUpgradePending=false;pendingChunkId=nil;lastMapPaletteVersion = -1
        awaitingMapAck = nil
        BleLink.shared.cancelMapTransfers()
        let reuseOffline = enabled && offlineMaps?.reuseStyle(Settings.shared.theme, source:Settings.shared.mapSource, buildings:buildingMode) == true
        if !reuseOffline { offlineMaps?.close(); offlineMaps = nil; offlineKey = ""; routeProgress = -1 }
        if preparedCoords.count >= 2 { prepareRoute(key: preparedKey, coords: preparedCoords) }
        // A style change must fetch new data even while simulation/location is paused.
        let requestedStyle=Settings.shared.theme
        DispatchQueue.main.async { [weak self] in
            guard let self=self,Settings.shared.theme==requestedStyle,self.enabled,requestedStyle != 11,
                  !self.fetching,let f=self.frame,let p=self.pose else {return}
            self.fetchChunk(f,p.x,p.y,purpose:.display)
        }
    }
    func requestMapSample() {
        guard [0,1,5].contains(Settings.shared.theme),frame != nil,pose != nil else {
            MapSampleReport.shared.fail("请先开始一次导航或模拟，再生成地图对照图。");return
        }
        let f=frame!,p=pose!
        resetChunk()
        // No cache node: the report must come from a new capture of the current area.
        fetchChunk(f,p.x,p.y,purpose:.display)
    }
    func onBuildingCapability() {
        guard [Self.SRC_AMAP, Self.SRC_VECTOR].contains(Settings.shared.mapSource), BleLink.shared.buildingsSupported else {return}
        lastBuildingTry = .distantPast
        if offlineMaps != nil, preparedCoords.count >= 2 { prepareRoute(key:preparedKey,coords:preparedCoords) }
        guard chunkBytes != nil else {return}
        paletteResendPending=true
        flushPaletteCapability()
    }
    /// 重连/认证后的地图补发入口：路线和幽灵立即发，底图等认证后的能力窗口。
    func onLinkReady() {
        routeAcked=false; ghostAcked=false
        reconnectMapPending=true
        reconnectMapAt=nil
        queueCurrentMapForSend()
        mapRetryPending=false; mapRetryUsed=false; mapFinalFailure=false; capabilityUpgradePending=false
        deferredFine = nil; fineSubmitted.removeAll(); fineCacheChecked = false
        sendRoute(); sendGhost()
        if BleLink.shared.verified { scheduleReconnectMap() }
    }
    /// 认证回执到达后开始 1 秒能力协商；旧固件无 MPAL 时到期按 v0 发送。
    func onAuthenticated() { scheduleReconnectMap() }
    private func scheduleReconnectMap() {
        if !reconnectMapPending { reconnectMapPending=true }
        guard reconnectMapAt == nil else { return }
        let deadline=Date().addingTimeInterval(1)
        let generation=BleLink.shared.connectionGeneration
        reconnectMapAt=deadline
        DispatchQueue.main.asyncAfter(deadline:.now()+1) { [weak self] in
            guard let self=self, self.reconnectMapAt == deadline,
                  BleLink.shared.connectionGeneration == generation else { return }
            self.flushReconnectMap()
        }
        if chunkBytes != nil, BleLink.shared.roadPaletteVersion >= 2 { flushReconnectMap() }
    }
    func flushReconnectMap() {
        guard reconnectMapPending else { return }
        reconnectMapPending=false
        reconnectMapAt=nil
        guard chunkBytes != nil else { return }
        mapSendPending=true
        _ = sendChunk()
    }
    func onRoadPaletteCapability() {
        guard let bytes=chunkBytes,RoadPalette.isPacket(bytes) else {return}
        let version=BleLink.shared.roadPaletteVersion
        if reconnectMapPending {
            if version >= 2 {
                if BleLink.shared.bulkPending {
                    BleLink.shared.cancelMapTransfers()
                    nextChunkId=(nextChunkId+1)&0xFF
                    pendingChunkId=nextChunkId
                    chunkAcked=false
                }
                flushReconnectMap()
            }
            return
        }
        guard version > lastMapPaletteVersion else { return }
        capabilityUpgradePending=true
        // A building packet's first transfer must finish before the format upgrade.
        if chunkBuildingPacket { return }
        applyCapabilityUpgrade()
    }
    private func applyCapabilityUpgrade() {
        guard capabilityUpgradePending, !reconnectMapPending,
              let b=chunkBytes, RoadPalette.isPacket(b) else { return }
        let version=BleLink.shared.roadPaletteVersion
        guard version > lastMapPaletteVersion else {
            capabilityUpgradePending=false
            return
        }
        if chunkBuildingPacket {
            guard chunkAcked || mapFinalFailure else { return }
        }
        // Keep the in-flight ATT callback slot; retire old map fragments and the receipt.
        BleLink.shared.cancelMapTransfers()
        awaitingMapAck = nil
        let newId=(nextChunkId+1)&0xFF
        let wire=RoadPalette.forWire(b,paletteVersion:version,buildingsSupported:BleLink.shared.buildingsSupported)
        if sendChunk(newId:newId, wire:wire) {
            capabilityUpgradePending=false
            mapRetryUsed=false; mapRetryPending=false; mapFinalFailure=false
        }
    }
    /// 圆屏拒绝（N,3,id）或回执最终超时：同一负载最多完整重试一次。
    func onReject(type:Int,id:Int) {
        guard type == chunkType, awaitingMapAck?.id == id,
              awaitingMapAck?.connection == BleLink.shared.connectionGeneration else { return }
        awaitingMapAck = nil
        if !mapRetryUsed, !mapRetryPending {
            mapRetryPending=true
            retryCurrentMap()
        } else {
            mapFinalFailure=true
        }
        if capabilityUpgradePending { applyCapabilityUpgrade() }
    }
    func onReceiptTimeout(id:Int) { onReject(type:3,id:id) }
    private func retryCurrentMap() {
        guard mapRetryPending, !mapRetryUsed, !reconnectMapPending,
              let wire=lastWire, chunkBytes != nil, !chunkAcked else { return }
        let newId=(nextChunkId+1)&0xFF
        if sendChunk(newId:newId, wire:wire) {
            mapRetryUsed=true; mapRetryPending=false
        }
    }
    private func flushPaletteCapability() {
        guard paletteResendPending,BleLink.shared.isReady,BleLink.shared.verified,!BleLink.shared.bulkPending else {return}
        guard let bytes=chunkBytes else {return}
        let wire=RoadPalette.forWire(bytes,paletteVersion:BleLink.shared.roadPaletteVersion,buildingsSupported:BleLink.shared.buildingsSupported)
        guard wire != lastWire else { paletteResendPending=false; return }
        let newId=(nextChunkId+1)&0xFF
        if sendChunk(newId:newId, wire:wire) { paletteResendPending=false }
    }
    private func ensureFrame(lat: Double, lng: Double) -> MapGeo.Frame {
        if let f = frame { return f }
        let la = (lat * 10).rounded() / 10, lo = (lng * 10).rounded() / 10
        let id = ((Int((la * 10).rounded()) * 7919 + Int((lo * 10).rounded()) * 104729) & 0x7FFF) | 1
        let f = MapGeo.Frame(refLat: la, refLng: lo, id: id); frame = f; return f
    }
    /// Called when selecting a route, before departure, and after a reroute.
    func prepareRoute(key: String, coords: [(lat: Double, lng: Double)]) {
        guard coords.count >= 2 else { return }
        preparedKey = key; preparedCoords = coords
        let f = ensureFrame(lat: coords[0].lat, lng: coords[0].lng), src = Settings.shared.mapSource
        guard enabled, !satMode, Settings.shared.theme != 11 else { return }
        var hasher = Hasher()
        for c in coords { hasher.combine(c.lat); hasher.combine(c.lng) }
        let identity = "\(key)|\(hasher.finalize())|\(src)|\(buildingMode)"
        if identity == offlineKey, offlineMaps != nil { return }
        clearFineSession()
        handoff.clear()
        offlineMaps?.close(); offlineKey = identity; routeProgress = -1
        workToken.cancel(); requestSerial += 1; fetching = false
        do {
            let plan = try RouteMapPlan(coords.map { (x: f.x($0.lng), y: f.y($0.lat)) })
            let maps = RouteOfflineMaps(frame: f, plan: plan, source: src, buildings: buildingMode,
                foregroundBusy: { [weak self] in self?.fetching ?? true },
                currentSpeed: { [weak self] in self?.pose?.kmh ?? 0 },
                currentView: { [weak self] in
                    guard let self=self,let p=self.pose else {return nil}
                    return BuildingView(x:p.x,y:p.y,bearing:self.lastBearing,radius:MapCoveragePolicy.radius(kmh:p.kmh))
                },
                onReady: { [weak self] node in
                    guard let self = self, self.offlineKey == identity, self.enabled, !self.fetching else { return }
                    if self.haveChunk,abs(self.chunkCx-node.x)<1,abs(self.chunkCy-node.y)<1 {
                        if let packet=self.offlineMaps?.readPacket(node) {
                            let same=abs(self.chunkCx-node.x)<1 && abs(self.chunkCy-node.y)<1
                            self.acceptChunk(packet.bytes,cx:node.x,cy:node.y,sat:false,type:Self.TYPE_RASTER,info:"沿线更新底图",src:src,coverage:self.offlineMaps?.readUpdate(node)?.coverage,
                                            fineRoads: packet.isFine && same && self.chunkBytes != packet.bytes)
                        }
                        self.triggerFineForDisplay(f, node: node)
                        self.tryUpgradeBuildings();return
                    }
                    let progress = self.pose.map { plan.progress(x: $0.x, y: $0.y, previous: self.routeProgress) } ?? 0
                    let onRoute = plan.at(progress)
                    if let p = self.pose, hypot(p.x - onRoute.x, p.y - onRoute.y) >= 400 { return }
                    let wantedIndex = self.pose.map { plan.displayTarget(progress: progress, x: $0.x, y: $0.y, kmh: $0.kmh) }
                        ?? plan.target(progress: progress, initial: true)
                    let wanted = plan.nodes[wantedIndex]
                    guard wanted == node else { return }
                    self.fetchChunk(f, node.x, node.y, node: node, purpose: .display)
                }, onStatus: { [weak self] status in
                    if self?.offlineKey == identity { self?.offlineStatus = status }
                })
            offlineMaps = maps; maps.start()
        } catch { offlineStatus = "沿线离线地图：\(error.localizedDescription)" }
    }
    func onLocation(lat: Double, lng: Double, bearing: Double, kmh: Int) {
        let f = ensureFrame(lat: lat, lng: lng), x = f.x(lng), y = f.y(lat)
        pose = (x, y, kmh)
        let locationIntervalMs: Int? = lastLocationAt.map { Int(-$0.timeIntervalSinceNow * 1000) }
        lastLocationAt = Date()
        if !mayPrepareMaps,fetching {
            workToken.cancel();requestSerial += 1;fetching=false;offlineMaps?.suspendCapture()
        }
        protectBaseDuringRoofTransfer()
        flushPreparedMap()
        if enabled, liveRaster, Date().timeIntervalSince(lastCoverageTrace) >= 2 {
            lastCoverageTrace = Date()
            MapPipelineTrace.event("view-coverage", ["kmh": kmh, "ready": BleLink.shared.isReady,
                "locIntervalMs": locationIntervalMs ?? -1,
                "sentCovered": haveChunk && MapCoveragePolicy.covers(x: x, y: y, cx: chunkCx, cy: chunkCy, kmh: max(120, kmh)),
                "bytes":chunkBytes?.count ?? 0,"awaitAck":!chunkAcked,
                "transferPending":BleLink.shared.bulkPending(type:chunkType,id:chunkId),
                "preparedOffsetM":handoff.pending.map{max(abs(x-$0.cx),abs(y-$0.cy))} ?? -1,
                "viewportOffsetM":confirmedCenter.map{max(abs(x-$0.x),abs(y-$0.y))} ?? -1,
                "confirmedCovered": confirmedCenter.map { MapCoveragePolicy.covers(x: x, y: y, cx: $0.x, cy: $0.y, kmh: max(120, kmh)) } ?? false])
        }
        var hdg = bearing
        if kmh >= 4 || lastBearing == nil { if kmh >= 4 { lastBearing = bearing } } else { hdg = lastBearing! }
        BleLink.shared.send("#p,\(f.id),\(Int((x * 10).rounded())),\(Int((y * 10).rounded())),\(Int(hdg.rounded())),\(kmh)")
        if ghostCoords != nil && ghostBytes == nil { encodeGhost() }
        if !enabled { return }
        if Settings.shared.theme == 11 { status = "龙珠雷达（无需底图）"; checkResend(); return }
        var node: RouteMapPlan.Node?
        var futureNode:RouteMapPlan.Node?
        if let maps = offlineMaps {
            routeProgress = maps.plan.progress(x: x, y: y, previous: routeProgress)
            let projected = maps.plan.at(routeProgress), index = maps.plan.displayTarget(progress: routeProgress, x: x, y: y, kmh: kmh)
            let preparationIndex=maps.plan.preparationTarget(progress:routeProgress,kmh:kmh)
            maps.update(preparationIndex,display:index)
            let candidate = maps.plan.nodes[index]
            if hypot(x - projected.x, y - projected.y) < 400,
               MapCoveragePolicy.covers(x: x, y: y, cx: candidate.x, cy: candidate.y, kmh: max(120, kmh), margin: 50) {
                node = candidate
                futureNode=maps.plan.nodes[preparationIndex]
            }
        }
        if let current=node {
            var relevant=[(x:current.x,y:current.y)]
            if let future=futureNode {relevant.append((x:future.x,y:future.y))}
            if handoff.discardObsolete(x:x,y:y,kmh:kmh,allowed:relevant) {
                MapPipelineTrace.event("staged-map-expired",["kmh":kmh])
            }
        }
        let confirmedCovered=confirmedCenter.map{MapCoveragePolicy.covers(x:x,y:y,cx:$0.x,cy:$0.y,kmh:max(120,kmh),margin:50)} ?? false
        let recovering=haveChunk && !confirmedCovered
        let distance = hypot(x - chunkCx, y - chunkCy)
        let refresh = chunkSat ? SAT_REFRESH : REFRESH
        let changedNode = node.map { abs($0.x - chunkCx) >= 1 || abs($0.y - chunkCy) >= 1 } ?? false
        let needsCoverage = !satMode && liveRaster && !MapCoveragePolicy.covers(x: x, y: y, cx: chunkCx, cy: chunkCy, kmh: max(120, kmh), margin: 50)
        let prepareEarly = !satMode && liveRaster &&
            MapCoveragePolicy.needsRefresh(x: x, y: y, cx: chunkCx, cy: chunkCy, bearing: bearing, kmh: kmh)
        // A building pass must yield before movement leaves its base map. Cached bases can switch immediately.
        if fetching, !satMode, liveRaster, let center = fetchingCenter,
           (fetchingBaseReady && (needsCoverage || changedNode) || !MapHandoffBuffer.mayPrepare(x:x,y:y,cx:center.x,cy:center.y)) {
            MapPipelineTrace.event("movement-cancel", ["serial": requestSerial, "baseReady": fetchingBaseReady, "needsCoverage": needsCoverage, "nextBlock": changedNode, "kmh": kmh])
            workToken.cancel(); requestSerial += 1; fetching = false
        }
        let retryBuildings = offlineMaps == nil && buildingMode && MapCoveragePolicy.mayCaptureBuildings(kmh:kmh) && (!chunkBuildingsComplete || !chunkCurrent) && mayPrepareMaps && Date().timeIntervalSince(lastBuildingTry) >= 60
        // Preparation and display targets differ: a future block may be captured now,
        // then held until it covers the viewport and the previous ATT transfer finishes.
        let wanted = haveChunk && prepareEarly && !recovering ? (futureNode ?? node) : node
        let a = bearing * .pi / 180, ahead = kmh > 5 ? (satMode ? SAT_AHEAD : MapCoveragePolicy.lookahead(kmh: kmh, preferred: AHEAD)) : 0
        let targetX=wanted?.x ?? (x+sin(a)*ahead), targetY=wanted?.y ?? (y+cos(a)*ahead)
        let sameCurrent=haveChunk && abs(targetX-chunkCx)<1 && abs(targetY-chunkCy)<1
        let alreadyPrepared=handoff.contains(cx:targetX,cy:targetY,style:Settings.shared.theme)
        let needsMap = !haveChunk || distance > refresh || needsCoverage || changedNode || (prepareEarly && !sameCurrent) || retryBuildings || (paletteMode && !chunkCurrent && mayPrepareMaps)
        var servedCache=false
        if needsMap,!alreadyPrepared {
            let cacheNode=wanted ?? RouteMapPlan.Node(x:(targetX/2).rounded(.toNearestOrEven)*2,y:(targetY/2).rounded(.toNearestOrEven)*2,distance:0)
            servedCache=useCachedMap(f,node:cacheNode)
            if servedCache { triggerFineForDisplay(f, node: cacheNode) }
            if !servedCache,!canCapture,!satMode,!confirmedCovered,
               let nearby=RouteMapCache.shared.covering(frame:f,source:Settings.shared.mapSource,style:Settings.shared.theme,x:x,y:y,kmh:kmh) {
                let nearbyNode=RouteMapPlan.Node(x:nearby.node.x,y:nearby.node.y,distance:0)
                let sameNearby=haveChunk && abs(chunkCx-nearbyNode.x)<1 && abs(chunkCy-nearbyNode.y)<1
                acceptChunk(nearby.bytes,cx:nearby.node.x,cy:nearby.node.y,sat:false,type:Self.TYPE_RASTER,info:"复用附近已缓存底图",src:Settings.shared.mapSource,coverage:nearby.coverage,
                            fineRoads: nearby.isFine && sameNearby && chunkBytes != nearby.bytes)
                servedCache=true
                triggerFineForDisplay(f, node: nearbyNode)
            }
        }
        if mayPrepareMaps,!servedCache,!fetching && handoff.pending == nil && !alreadyPrepared && needsMap && Date().timeIntervalSince(lastFetchFail) > 15 {
            let purpose: FetchPurpose
            if let wanted, let node, abs(wanted.x-node.x) >= 1 || abs(wanted.y-node.y) >= 1 {
                purpose = .prepare
            } else {
                purpose = .display
            }
            fetchChunk(f,targetX,targetY,node:wanted,purpose:purpose)
        }
        if !mayPrepareMaps,needsMap,!servedCache,!confirmedCovered {
            status="此处底图尚未缓存，保留已有地图；回前台补充"
        }
        evaluateFineForCurrentBlock(f, displayNode: node)
        tryUpgradeBuildings();checkResend()
    }
    /// 当前块稳定后独立评估可选补路，不依赖 needsMap/servedCache。
    /// 只在当前块是显示目标、仍覆盖视野、没有前方道路/预取任务时启动。
    private func evaluateFineForCurrentBlock(_ f: MapGeo.Frame, displayNode: RouteMapPlan.Node?) {
        guard haveChunk, let bytes=chunkBytes, chunkType==Self.TYPE_RASTER,
              chunkStyle==Settings.shared.theme,
              RouteMapCache.isCurrent(bytes,source:Settings.shared.mapSource,style:Settings.shared.theme),
              displayNode == nil || (abs(displayNode!.x-chunkCx)<1 && abs(displayNode!.y-chunkCy)<1) else { return }
        triggerFineForDisplay(f, node: RouteMapPlan.Node(x:chunkCx,y:chunkCy,distance:0))
    }
    private func roofDeliveryAllowed(_ bytes:Data,cx:Double,cy:Double)->Bool {
        guard haveChunk,chunkAcked,let p=pose,let center=confirmedCenter,
              abs(center.x-chunkCx)<1,abs(center.y-chunkCy)<1 else {return false}
        let seconds=MapCoveragePolicy.remainingSeconds(x:p.x,y:p.y,cx:center.x,cy:center.y,
            kmh:p.kmh,bearing:lastBearing,plan:offlineMaps?.plan,progress:routeProgress)
        let candidateSeconds=MapCoveragePolicy.remainingSeconds(x:p.x,y:p.y,cx:cx,cy:cy,
            kmh:p.kmh,bearing:lastBearing,plan:offlineMaps?.plan,progress:routeProgress)
        guard seconds>0,candidateSeconds>0 else {return false}
        let reserve=max(chunkRoadBytes,handoff.pending?.roadBytes ?? 0)
        return MapDeliveryPolicy.roofsFit(kmh:p.kmh,bytes:bytes.count,rate:BleLink.shared.mapBytesPerSecond,
            coverageSeconds:min(seconds,candidateSeconds),nextBaseBytes:reserve)
    }
    /// A detail transfer begun while stopped must yield if departure makes its
    /// remaining bytes unsafe. Restore the genuinely acknowledged base state;
    /// do not claim the abandoned building packet was received.
    private func protectBaseDuringRoofTransfer() {
        guard !chunkAcked,let saved=upgradeBase,let p=pose else {return}
        let remaining=BleLink.shared.mapPayloadRemaining(id:chunkId)
        guard remaining>0 else {return} // Already awaiting K: let bounded receipt recovery finish.
        let old=saved.packet
        let seconds=MapCoveragePolicy.remainingSeconds(x:p.x,y:p.y,cx:old.cx,cy:old.cy,
            kmh:p.kmh,bearing:lastBearing,plan:offlineMaps?.plan,progress:routeProgress)
        let candidateSeconds=MapCoveragePolicy.remainingSeconds(x:p.x,y:p.y,cx:chunkCx,cy:chunkCy,
            kmh:p.kmh,bearing:lastBearing,plan:offlineMaps?.plan,progress:routeProgress)
        let reserve=max(old.roadBytes,handoff.pending?.roadBytes ?? 0)
        guard min(seconds,candidateSeconds)<=0 || !MapDeliveryPolicy.roofsFit(kmh:p.kmh,bytes:remaining,
            rate:BleLink.shared.mapBytesPerSecond,coverageSeconds:min(seconds,candidateSeconds),nextBaseBytes:reserve) else {return}
        MapPipelineTrace.event("roof-yield",["id":chunkId,"bytes":remaining,"kmh":p.kmh])
        if let bytes=chunkBytes,RasterPacket.isBuilding(bytes) {
            deferredRoofs = .init(bytes:bytes,cx:chunkCx,cy:chunkCy,sat:chunkSat,type:chunkType,info:"暂缓建筑包",source:Settings.shared.mapSource,style:chunkStyle ?? Settings.shared.theme,coverage:chunkCoverage)
        }
        BleLink.shared.cancelMapTransfers()
        awaitingMapAck = nil
        deferredFine = nil; fineSubmitted.removeAll(); fineCacheChecked = false
        chunkBytes=old.bytes;chunkRoadBytes=old.roadBytes;chunkCx=old.cx;chunkCy=old.cy;chunkId=saved.id
        chunkType=old.type;chunkSat=old.sat;chunkStyle=old.style
        chunkAcked=true;chunkCoverage=old.coverage;chunkBuildingsComplete=old.coverage?.isComplete ?? false
        confirmedCenter=(old.cx,old.cy);upgradeBase=nil;lastRoofUpgradeProbe=Date()
        status="保留已确认底图，优先准备前方道路";chunkInfo="地图块 #\(chunkId)：已确认底图"
    }
    private func tryUpgradeBuildings() {
        guard enabled,buildingMode,haveChunk,chunkAcked,(!chunkBuildingsComplete || !chunkCurrent),
              BleLink.shared.isReady,!BleLink.shared.bulkPending,
              Date().timeIntervalSince(lastRoofUpgradeProbe)>=2 else {return}
        lastRoofUpgradeProbe=Date()
        let saved=deferredRoofs.flatMap{p -> MapHandoffBuffer.Packet? in
            p.style==Settings.shared.theme && abs(p.cx-chunkCx)<1 && abs(p.cy-chunkCy)<1 ? p:nil
        }
        let candidate:MapHandoffBuffer.Packet?
        if let saved=saved {candidate=saved}
        else if let maps=offlineMaps,let node=maps.plan.nodes.first(where:{abs($0.x-chunkCx)<1 && abs($0.y-chunkCy)<1}),
                let update=maps.readUpdate(node) {
            candidate = .init(bytes:update.bytes,cx:node.x,cy:node.y,sat:false,type:Self.TYPE_RASTER,info:"沿线建筑包",source:Settings.shared.mapSource,style:Settings.shared.theme,coverage:update.coverage)
        } else {candidate=nil}
        guard let candidate=candidate else {return}
        guard roofDeliveryAllowed(candidate.bytes,cx:candidate.cx,cy:candidate.cy) else {
            MapPipelineTrace.event("roof-deferred",["bytes":candidate.bytes.count,"kmh":pose?.kmh ?? 0,"rate":BleLink.shared.mapBytesPerSecond ?? 0]);return
        }
        MapPipelineTrace.event("roof-upgrade",["bytes":candidate.bytes.count,"kmh":pose?.kmh ?? 0,"rate":BleLink.shared.mapBytesPerSecond ?? 0])
        acceptChunk(candidate.bytes,cx:candidate.cx,cy:candidate.cy,sat:candidate.sat,type:candidate.type,info:candidate.info,src:candidate.source,coverage:candidate.coverage)
    }
    private func useCachedMap(_ f:MapGeo.Frame,node:RouteMapPlan.Node)->Bool {
        guard !satMode,Settings.shared.theme != 11 else {return false}
        if haveChunk,chunkStyle==Settings.shared.theme,chunkBuildingsComplete,chunkCurrent,abs(chunkCx-node.x)<1,abs(chunkCy-node.y)<1 {return true}
        let cache=RouteMapCache.shared,src=Settings.shared.mapSource,style=Settings.shared.theme
        let sameBlock=haveChunk && abs(chunkCx-node.x)<1 && abs(chunkCy-node.y)<1
        let currentPacket=cache.readPacket(frame:f,source:src,buildings:false,node:node,style:style,allowLegacy:false)
        let fallbackPacket=currentPacket == nil ? cache.readPacket(frame:f,source:src,buildings:false,node:node,style:style):nil
        // 矢量源：巡航滚动缓存优先，旧 512MB 层回退（命中即按需导入）
        let packet = src == Self.SRC_VECTOR
            ? (Self.cruiseOrLegacyPacket(f, source: src, node: node, style: style) ?? currentPacket ?? fallbackPacket)
            : (currentPacket ?? fallbackPacket)
        let currentUpdate=buildingMode ? cache.buildingUpdate(frame:f,source:src,node:node,style:style,currentOnly:true):nil
        let update=currentUpdate ?? (currentPacket == nil && buildingMode ? cache.buildingUpdate(frame:f,source:src,node:node,style:style):nil)
        guard let bytes=update?.bytes ?? packet?.bytes else {return false}
        let cachedFine = update == nil && packet?.isFine == true
        acceptChunk(bytes,cx:node.x,cy:node.y,sat:false,type:Self.TYPE_RASTER,info:"沿线缓存底图",src:src,coverage:update?.coverage,
                    fineRoads: cachedFine && sameBlock && chunkBytes != bytes)
        MapPipelineTrace.event("cache-map-selected",["buildings":RasterPacket.isBuilding(bytes),"bytes":bytes.count])
        if buildingMode,(!MapCoveragePolicy.mayCaptureBuildings(kmh:pose?.kmh ?? 0) || Date().timeIntervalSince(lastBuildingTry)<60),
           cache.read(frame:f,source:src,buildings:false,node:node,style:style,allowLegacy:false) != nil {return true}
        return !mayPrepareMaps || offlineMaps != nil || (RouteMapCache.isCurrent(bytes,source:src,style:style) && (!buildingMode || (update?.coverage.isComplete == true && update?.coverage.qualityVersion == FastBuildings.qualityVersion)))
    }
    private func acceptChunk(_ incoming: Data, cx: Double, cy: Double, sat: Bool, type: Int, info: String, src: Int, coverage: BuildingCoverage? = nil, fineRoads: Bool = false, fineRevision: Int = 0, fineContent: Bool = false) {
        guard enabled, Settings.shared.theme != 11 else { return }
        // 模式/主题切换后，旧图源的迟到回调不得覆盖新模式的地图。
        guard src == Settings.shared.mapSource else {
            MapPipelineTrace.event("map-source-stale", ["src": src, "current": Settings.shared.mapSource])
            return
        }
        let current=RouteMapCache.isCurrent(incoming,source:src,style:Settings.shared.theme)
        let same=haveChunk && chunkType==type && chunkSat==sat && abs(cx-chunkCx)<1 && abs(cy-chunkCy)<1
        if fineRoads {
            guard same, chunkBytes != incoming else { return }
            let submitKey = fineSubmitKey(cx, cy, source: src, style: Settings.shared.theme, revision: fineRevision)
            guard fineSubmitted.insert(submitKey).inserted else {
                MapPipelineTrace.event("fine-already-submitted", ["id": chunkId])
                return
            }
            deferredFine = DeferredFine(
                packet: .init(bytes: incoming, cx: cx, cy: cy, sat: sat, type: type,
                              info: info, source: src, style: Settings.shared.theme, coverage: nil),
                chunkId: chunkAcked ? chunkId : awaitingMapAck?.id,
                requestSerial: requestSerial, epoch: fineEpoch, revision: fineRevision)
            MapPipelineTrace.event("fine-staged", ["id": chunkId, "bytes": incoming.count,
                "acked": chunkAcked])
            if chunkAcked { flushFineRoads() }
            return
        }
        if !same { deferredFine=nil; fineSubmitted.removeAll() }
        let newer=same && current && !chunkCurrent
        if same && !current && chunkCurrent {return}
        if !current,let pending=handoff.pending,pending.source==src,pending.style==Settings.shared.theme,pending.type==type,
           abs(pending.cx-cx)<1,abs(pending.cy-cy)<1,RouteMapCache.isCurrent(pending.bytes,source:src,style:pending.style) {return}
        if same, !newer, let previous=chunkCoverage {
            guard let incomingCoverage=coverage else {return}
            if previous.qualityVersion > incomingCoverage.qualityVersion {return}
            if previous.qualityVersion == incomingCoverage.qualityVersion,
               incomingCoverage.checkedMask | previous.checkedMask != incomingCoverage.checkedMask {return}
        }
        if let old=deferredRoofs,old.source==src,old.style==Settings.shared.theme,old.type==type,
           abs(old.cx-cx)<1,abs(old.cy-cy)<1,
           RouteMapCache.isCurrent(old.bytes,source:src,style:old.style),!current {return}
        if let old=deferredRoofs,old.source==src,old.style==Settings.shared.theme,old.type==type,
           abs(old.cx-cx)<1,abs(old.cy-cy)<1,
           RouteMapCache.isCurrent(old.bytes,source:src,style:old.style) == current,
           let previous=old.coverage,let incoming=coverage {
            if previous.qualityVersion>incoming.qualityVersion {return}
            if previous.qualityVersion==incoming.qualityVersion,
               incoming.checkedMask | previous.checkedMask != incoming.checkedMask {return}
        }
        let kmh=pose?.kmh ?? 0
        if buildingMode,RasterPacket.isBuilding(incoming) {
            deferredRoofs = .init(bytes:incoming,cx:cx,cy:cy,sat:sat,type:type,info:info,source:src,style:Settings.shared.theme,coverage:coverage)
        }
        let allowRoofs=buildingMode && !newer && roofDeliveryAllowed(incoming,cx:cx,cy:cy)
        let b=allowRoofs ? incoming:MapDeliveryPolicy.compactBase(incoming)
        if b.count<incoming.count {
            MapPipelineTrace.event("map-base-priority",["beforeBytes":incoming.count,"bytes":b.count,"kmh":kmh])
            if kmh>=60 {buildingInfo="高速行驶优先保证底图，稍后补充建筑"}
        }
        guard sat || MapStyleTransfer.matches(b,style:Settings.shared.theme) else {return}
        guard ![Self.SRC_AMAP, Self.SRC_VECTOR].contains(src) || !AmapCapturePolicy.supportsBuildings(Settings.shared.theme) || RasterPacket.hasMapContent(b) else {
            status="底图尚未准备完整，保留已有地图";return
        }
        if current,let old=deferredRoofs,old.source==src,old.style==Settings.shared.theme,old.type==type,
           abs(old.cx-cx)<1,abs(old.cy-cy)<1,!RouteMapCache.isCurrent(old.bytes,source:src,style:old.style) {deferredRoofs=nil}
        let complete = coverage?.isComplete == true && (b == incoming)
        if haveChunk,chunkType==type,chunkSat==sat,chunkBuildingsComplete,!complete,!newer,
           abs(cx-chunkCx)<1,abs(cy-chunkCy)<1 {
            // A repeated base callback is not a newer building observation.
            // Preserve already-delivered or in-flight detail at the same location.
            MapPipelineTrace.event("roof-downgrade-blocked",["id":chunkId]);return
        }
        if haveChunk, chunkType == type, chunkSat == sat, abs(cx - chunkCx) < 1, abs(cy - chunkCy) < 1,
           coverage == nil, !chunkAcked, !newer {
            MapPipelineTrace.event("base-kept-inflight", ["id": chunkId])
            return
        }
        // The complete incoming detail packet was budgeted; do not inflate it
        // by carrying extra roofs from an older map after that decision.
        let displayBytes = b
        if haveChunk, chunkType == type, chunkSat == sat, abs(cx - chunkCx) < 1, abs(cy - chunkCy) < 1,
           displayBytes == chunkBytes {
            // Cached base then screenshot base often encode the exact same map.
            // Keep the transfer ID so the second callback cannot invalidate fragments already received.
            if b == incoming {chunkCoverage = coverage ?? chunkCoverage}
            chunkBuildingsComplete = chunkBuildingsComplete || complete
            return
        }
        let transferPending = haveChunk && !chunkAcked && BleLink.shared.bulkPending(type:chunkType,id:chunkId)
        let outsideView = pose.map { !sat && [Self.SRC_AMAP, Self.SRC_VECTOR].contains(src) && !MapCoveragePolicy.covers(x:$0.x,y:$0.y,cx:cx,cy:cy,kmh:max(120,$0.kmh),margin:50) } ?? false
        if transferPending || outsideView {
            if pose.map({MapHandoffBuffer.mayPrepare(x:$0.x,y:$0.y,cx:cx,cy:cy)}) ?? true {
                handoff.stage(.init(bytes:incoming,cx:cx,cy:cy,sat:sat,type:type,info:info,source:src,style:Settings.shared.theme,coverage:coverage))
                MapPipelineTrace.event("map-staged",["transferPending":transferPending,"outsideView":outsideView])
            }
            return
        }
        if haveChunk,chunkType==type,chunkSat==sat,abs(cx-chunkCx)<1,abs(cy-chunkCy)<1,
           chunkCoverage != nil,b != incoming,!newer {return}
        if handoff.contains(cx:cx,cy:cy,style:Settings.shared.theme) {handoff.clear()}
        if RasterPacket.isBuilding(b),haveChunk,chunkAcked,let previous=chunkBytes {
            upgradeBase=(.init(bytes:previous,cx:chunkCx,cy:chunkCy,sat:chunkSat,type:chunkType,info:"已确认底图",source:src,style:chunkStyle ?? Settings.shared.theme,coverage:chunkCoverage),chunkId)
        } else {upgradeBase=nil}
        let incomingDigest = FineRoads.baseDigest(incoming)
        if same, coverage == nil, chunkIsFine, !fineRoads, !fineContent,
           chunkBaseDigest == incomingDigest {
            MapPipelineTrace.event("fine-wide-rollback-blocked", ["id": chunkId])
            return
        }
        chunkRoadBytes=MapDeliveryPolicy.compactBase(displayBytes).count
        chunkBytes = displayBytes
        let displayIsFine = fineRoads || fineContent
        if displayIsFine { chunkIsFine = true }
        else { chunkIsFine = false; chunkBaseDigest = incomingDigest }
        chunkStyle=Settings.shared.theme
        chunkCoverage = b == incoming ? coverage : nil
        chunkBuildingsComplete = complete
        chunkBuildingPacket = RasterPacket.isBuilding(incoming) || coverage != nil
        if complete,deferredRoofs?.cx==cx,deferredRoofs?.cy==cy {deferredRoofs=nil}
        haveChunk = true; chunkSat = sat; chunkCx = cx; chunkCy = cy
        chunkType = type
        deferredFine = nil; fineSubmitted.removeAll(); fineCacheChecked = false
        refreshCruisePins()
        queueCurrentMapForSend()
        mapRetryPending=false; mapRetryUsed=false; mapFinalFailure=false; capabilityUpgradePending=false; lastMapPaletteVersion = -1
        status = complete ? "高德建筑底图已就绪" : "地图已就绪"
        chunkInfo = "地图块 #\(chunkId)：\(info)，\(b.count / 1024) KB" + (buildingMode && !complete ? "（建筑尚未完成，显示普通底图）" : "")
        sendChunk()
    }
    private func fetchChunk(_ f: MapGeo.Frame, _ requestedX: Double, _ requestedY: Double, node: RouteMapPlan.Node? = nil, purpose: FetchPurpose = .display, fineQuadrant: Int? = nil) {
        let cacheNode=node ?? RouteMapPlan.Node(x:(requestedX/2).rounded(.toNearestOrEven)*2,y:(requestedY/2).rounded(.toNearestOrEven)*2,distance:0)
        let cx=cacheNode.x,cy=cacheNode.y
        if !mayPrepareMaps { _=useCachedMap(f,node:cacheNode);return }
        fetching = true; status = "正在准备附近地图…"; requestSerial += 1
        fetchingCenter = (cx, cy); fetchingBaseReady = false
        let serial = requestSerial
        MapPipelineTrace.event("fetch-start", ["serial": serial, "buildings": buildingMode, "source": Settings.shared.mapSource, "display": purpose == .display])
        workToken.cancel(); let token = MapWorkToken(); workToken = token
        let src = Settings.shared.mapSource, sat = satMode, style = Settings.shared.theme
        // 当前显示块可以补路；沿线预下载和前方准备只取宽图。
        let buildings = purpose == .display && buildingMode && MapCoveragePolicy.mayCaptureBuildings(kmh:pose?.kmh ?? 0)
        let fineAllowed = purpose == .display && !Settings.shared.buildings
            && (1...3).contains(style) && canCapture && (pose?.kmh ?? 0) < 60
        captureStyle=style;captureSource=src;captureBuildings=buildings
        let buildingView = pose.map { BuildingView(x:$0.x,y:$0.y,bearing:lastBearing,radius:MapCoveragePolicy.radius(kmh:$0.kmh)) }
        let requestedQuadrant = fineQuadrant ?? (purpose == .display
            ? FineRoads.quadrant(view: buildingView, cx: cx, cy: cy) : nil)
        let cache=RouteMapCache.shared
        let attemptKey = fineKey(f, cacheNode, source: src, style: style, quadrant: requestedQuadrant ?? -1)
        let cachedPacket = src == Self.SRC_VECTOR
            ? (Self.cruiseOrLegacyPacket(f, source: src, node: cacheNode, style: style)
                ?? cache.readPacket(frame:f,source:src,buildings:false,node:cacheNode,style:style,allowLegacy:false))
            : cache.readPacket(frame:f,source:src,buildings:false,node:cacheNode,style:style)
        let fineState = requestedQuadrant.flatMap { q -> RouteMapCache.FineState? in
            guard let wide = cache.readWide(frame: f, source: src, node: cacheNode, style: style) else { return nil }
            return cache.readFineState(frame: f, source: src, node: cacheNode, style: style,
                                       baseDigest: FineRoads.baseDigest(wide))
        }
        let fineCached = requestedQuadrant.map { q in
            fineState.map { $0.checkedMask & (1 << UInt8(q)) != 0 } ?? false
        } ?? false
        let fineRetry = fineAllowed && requestedQuadrant != nil && !fineCached && !fineAttempted.contains(attemptKey)
        let currentUpdate=buildingMode ? cache.buildingUpdate(frame:f,source:src,node:cacheNode,style:style,currentOnly:true):nil
        let update=currentUpdate ?? (cachedPacket == nil && buildingMode ? cache.buildingUpdate(frame:f,source:src,node:cacheNode,style:style):nil)
        let cached=update?.bytes ?? (purpose == .display ? cachedPacket?.bytes : cache.readWide(frame:f,source:src,node:cacheNode,style:style))
        if let cached=cached,!sat {
            let sameBlock = haveChunk && abs(chunkCx-cx)<1 && abs(chunkCy-cy)<1
            let cachedFine = purpose == .display && update == nil && cachedPacket?.isFine == true
            acceptChunk(cached,cx:cx,cy:cy,sat:false,type:Self.TYPE_RASTER,info:"沿线离线包",src:src,coverage:update?.coverage,
                        fineRoads: cachedFine && sameBlock && chunkBytes != cached)
            fetchingBaseReady=true
            if RouteMapCache.isCurrent(cached,source:src,style:style), !buildings || (update?.coverage.isComplete == true && update?.coverage.qualityVersion == FastBuildings.qualityVersion), !fineRetry {fetching=false;return}
        }
        if buildings {lastBuildingTry=Date()}
        if fineRetry { fineAttempted.insert(attemptKey) }
        worker.async {
            var coverage: BuildingCoverage?
            var bytes: Data?, type = Self.TYPE_RASTER, gotSat = false, errorText = "", info = ""
            var fineRoads = false
            var fineUpdate: FineRoads.Update?
            var deliveredBase: Data?
            do {
                if token.isCancelled { throw MapProcessingError.cancelled }
                if sat {
                    bytes = try AmapSdkRaster.build(f,cx: cx,cy: cy,includeBuildings: false,shouldCancel: { token.isCancelled },satellite: true, style: style).bytes
                    gotSat = true; info = "高德卫星图"
                } else if src == Self.SRC_VECTOR {
                    // 矢量图源：下载 + CPU 栅格化，不需要前台/SDK 图形栈。
                    // 底图先上屏（onRoadsReady），建筑包随后经 deferredRoofs 在底图确认后升级。
                    let vStart = Date()
                    MapPipelineTrace.event("vector-fetch-start", ["serial": serial, "style": style,
                        "buildings": buildings, "generation": Self.vectorTiles.dataGeneration])
                    let result = try Self.vectorBuilder(Self.vectorTiles, f, f.lat(cy), f.lng(cx), style, buildings, { token.isCancelled }) { base in
                        if !token.isCancelled {
                            try? RouteMapCache.shared.store(base, frame: f, source: src, node: cacheNode, style: style)
                            // 巡航滚动缓存（64 MiB 块级 LRU）：不受旧 512MB 满额路径限制
                            let gen = Self.vectorTiles.dataGeneration
                            CruiseMapCache.shared.store(base, kind: "base", source: src, generation: gen,
                                                       frame: f, style: style, quality: CruiseMapCache.qualityVersion,
                                                       cx: cx, cy: cy)
                        }
                        MapPipelineTrace.event("vector-roads-ready", ["serial": serial, "bytes": base.count])
                        DispatchQueue.main.async {
                            if serial == self.requestSerial && !token.isCancelled {
                                self.fetchingBaseReady = true
                                self.acceptChunk(base, cx: cx, cy: cy, sat: false, type: Self.TYPE_RASTER, info: "矢量底图（OpenFreeMap），2 米/像素", src: src)
                            }
                        }
                    }
                    if let bld = result.buildings, !token.isCancelled {
                        try? RouteMapCache.shared.store(bld, frame: f, source: src, node: cacheNode, style: style)
                        let gen = Self.vectorTiles.dataGeneration
                        CruiseMapCache.shared.store(bld, kind: "bld", source: src, generation: gen,
                                                   frame: f, style: style, quality: CruiseMapCache.qualityVersion,
                                                   cx: cx, cy: cy)
                    }
                    bytes = result.buildings ?? result.base
                    info = result.buildings != nil ? "矢量建筑（OpenFreeMap）" : "矢量底图（OpenFreeMap），2 米/像素"
                    // 建筑状态单列：ok 有包 / none 无建筑数据 / dropped 超限丢弃 / off 未开启
                    let buildingStatus: String
                    if !buildings || !AmapCapturePolicy.supportsBuildings(style) { buildingStatus = "off" }
                    else if result.buildings != nil { buildingStatus = "ok" }
                    else if result.droppedBuildings { buildingStatus = "dropped" }
                    else { buildingStatus = "none" }
                    MapPipelineTrace.event("vector-fetch-end", ["serial": serial,
                        "ms": Int(-vStart.timeIntervalSinceNow * 1000), "tiles": result.tiles,
                        "tileBytes": result.bytesIn, "roadBytes": result.base.count,
                        "buildingBytes": result.buildings?.count ?? 0, "buildingStatus": buildingStatus,
                        "degraded": result.degradedRoads, "roadPixels": result.roadPixels,
                        "buildingPixels": result.buildingPixels])
                } else if src == Self.SRC_AMAP {
                    let result = try AmapSdkRaster.build(f, cx: cx, cy: cy, includeBuildings: buildings, shouldCancel: { token.isCancelled }, onBaseReady: { base in
                        deliveredBase = base
                        if !token.isCancelled { try? RouteMapCache.shared.store(base, frame: f, source: src, node: cacheNode, style: style) }
                        DispatchQueue.main.async {
                            if serial == self.requestSerial && !token.isCancelled {
                                self.fetchingBaseReady = true
                                self.acceptChunk(base, cx: cx, cy: cy, sat: false, type: Self.TYPE_RASTER, info: "高德无字底图，2 米/像素", src: src)
                            }
                        }
                    }, onBuildingStatus: { message in
                        DispatchQueue.main.async {
                            if serial == self.requestSerial && !token.isCancelled { self.buildingInfo = message }
                        }
                    }, style: style, preparedBase: RouteMapCache.shared.readWide(frame:f,source:src,node:cacheNode,style:style), buildingView: buildingView, onBuildingReady: { update in
                        DispatchQueue.main.async {
                            guard serial == self.requestSerial, !token.isCancelled else { return }
                            self.acceptChunk(update.bytes,cx:cx,cy:cy,sat:false,type:Self.TYPE_RASTER,info:"高德建筑",src:src,coverage:update.coverage)
                        }
                    }, fineRoads: fineRetry, fineQuadrant: requestedQuadrant)
                    bytes = result.bytes; coverage = result.coverage
                    fineRoads = result.fineRoads; fineUpdate = result.fineUpdate
                    info = "高德无字底图，2 米/像素"
                }
                if let packet = bytes, !sat, !token.isCancelled {
                    if let coverage=coverage {
                        try? RouteMapCache.shared.storeBuildingUpdate(BuildingUpdate(bytes:packet,coverage:coverage),frame:f,source:src,node:cacheNode)
                    } else {
                        try? RouteMapCache.shared.store(packet, frame: f, source: src, node: cacheNode, style: style,
                                                        fine: fineRoads ? RouteMapCache.fineVersion : 0)
                    }
                }
            } catch { errorText = error.localizedDescription }
            // Capture the worker's final values before hopping to main; the
            // main closure must not read mutable worker state after the hop.
            let delivered = deliveredBase
            let fine = fineRoads
            let fineRevision = fineUpdate?.revision ?? 0
            DispatchQueue.main.async {
                guard serial == self.requestSerial, !token.isCancelled else { return }
                self.fetching = false
                guard let packet = bytes else {
                    self.lastFetchFail = Date();self.status = "地图准备失败，保留已有地图：\(errorText)"
                    MapSampleReport.shared.failIfWaiting("本次取图未完成，请保持 App 前台后重试。");return
                }
                // 宽图已在 onBaseReady 上屏；补路失败/关闭建筑时不要重复发送同一包。
                if packet == delivered { return }
                self.acceptChunk(packet, cx: cx, cy: cy, sat: gotSat, type: type, info: info, src: src, coverage: coverage,
                                 fineRoads: fine, fineRevision: fineRevision)
            }
        }
    }

    private func flushPreparedMap() {
        guard enabled,let p=pose else {return}
        let blocked=haveChunk && !chunkAcked && BleLink.shared.bulkPending(type:chunkType,id:chunkId)
        if let next=handoff.take(x:p.x,y:p.y,kmh:p.kmh,style:Settings.shared.theme,transferPending:blocked) {
            acceptChunk(next.bytes,cx:next.cx,cy:next.cy,sat:next.sat,type:next.type,info:next.info,src:next.source,coverage:next.coverage)
        }
    }
    /// 宽底图 ACK 后发送在途期间暂存的同块细路增强包。
    /// 前方道路、模式/主题/图源/地图块变化或预算不足时只丢弃这一次。
    private func flushFineRoads() {
        guard let wait = deferredFine else { return }
        deferredFine = nil
        let fine = wait.packet
        guard enabled, Settings.shared.theme != 11,
              wait.chunkId == chunkId, wait.epoch == fineEpoch,
              fine.source == Settings.shared.mapSource,
              fine.style == Settings.shared.theme,
              fine.type == chunkType,
              abs(fine.cx - chunkCx) < 1, abs(fine.cy - chunkCy) < 1,
              chunkAcked,
              handoff.pending == nil,
              BleLink.shared.isReady,
              !BleLink.shared.bulkPending,
              RasterPacket.valid(fine.bytes),
              RasterPacket.hasMapContent(fine.bytes),
              MapStyleTransfer.matches(fine.bytes, style: Settings.shared.theme) else {
            MapPipelineTrace.event("fine-dropped", ["reason": "stale-or-busy"])
            return
        }
        if let p = pose {
            let seconds = MapCoveragePolicy.remainingSeconds(x: p.x, y: p.y, cx: chunkCx, cy: chunkCy,
                kmh: p.kmh, bearing: lastBearing, plan: offlineMaps?.plan, progress: routeProgress)
            // Reserve the current wide base (not the enhancement) for the next road packet.
            guard MapDeliveryPolicy.roofsFit(kmh: p.kmh, bytes: fine.bytes.count,
                rate: BleLink.shared.mapBytesPerSecond, coverageSeconds: seconds,
                nextBaseBytes: chunkRoadBytes) else {
                MapPipelineTrace.event("fine-budget-deferred", ["bytes": fine.bytes.count, "kmh": p.kmh,
                    "wide": chunkRoadBytes])
                return
            }
        }
        MapPipelineTrace.event("fine-sent-after-ack", ["bytes": fine.bytes.count, "id": chunkId])
        // Admission already completed; use the normal send path, not the fine staging branch.
        acceptChunk(fine.bytes, cx: fine.cx, cy: fine.cy, sat: fine.sat, type: fine.type,
                    info: "细路增强包", src: fine.source, coverage: nil, fineRoads: false,
                    fineContent: true)
    }
    /// 巡航滚动缓存固定块保护：当前显示块、待交接块、细路延迟块不被淘汰（主线程，内存状态）。
    private func refreshCruisePins() {
        guard let f = frame else { return }
        let gen = Self.vectorTiles.dataGeneration
        guard !gen.isEmpty else { return }
        let style = Settings.shared.theme
        var keys = Set<String>()
        if haveChunk {
            keys.insert(CruiseMapCache.blockKey(source: Settings.shared.mapSource, generation: gen,
                                                frame: f, style: style, quality: CruiseMapCache.qualityVersion,
                                                cx: chunkCx, cy: chunkCy))
        }
        if let p = handoff.pending {
            keys.insert(CruiseMapCache.blockKey(source: p.source, generation: gen,
                                                frame: f, style: p.style, quality: CruiseMapCache.qualityVersion,
                                                cx: p.cx, cy: p.cy))
        }
        CruiseMapCache.shared.setPins(keys)
    }
    private func queueCurrentMapForSend() {
        awaitingMapAck = nil
        chunkAcked = false
        mapSendPending = true
        pendingChunkId = nil
        if chunkBytes != nil {
            nextChunkId = (nextChunkId + 1) & 0xFF
            pendingChunkId = nextChunkId
        }
    }
    @discardableResult
    private func sendChunk(newId:Int? = nil, wire:Data? = nil) -> Bool {
        guard BleLink.shared.isReady, BleLink.shared.verified, !reconnectMapPending else { return false }
        guard let b = chunkBytes, enabled, Settings.shared.theme != 11,chunkStyle==Settings.shared.theme else { return false }
        let version = BleLink.shared.roadPaletteVersion
        let data = wire ?? RoadPalette.forWire(b,paletteVersion:version,buildingsSupported:BleLink.shared.buildingsSupported)
        let id = newId ?? pendingChunkId ?? chunkId
        guard BleLink.shared.sendBulk(type: chunkType, id: id, data: data) else { return false }
        if let newId { nextChunkId = newId }
        pendingChunkId=nil
        chunkId=id
        awaitingMapAck = (id, BleLink.shared.connectionGeneration)
        deferredFine?.chunkId = id
        chunkSentAt=Date()
        lastMapPaletteVersion = RoadPalette.packetVersion(data)
        lastWire=data
        chunkAcked=false
        mapSendPending=false
        if let coverage=chunkCoverage {
            MapPipelineTrace.event(coverage.isComplete ? "full-send" : "first-send",["type":chunkType,"id":chunkId,"mask":coverage.checkedMask,"bytes":data.count,"buildings":RasterPacket.isBuilding(data)])
        }
        MapPipelineTrace.packet(data, type: chunkType, id: chunkId, ready: BleLink.shared.isReady)
        return true
    }

    // MARK: - 路线

    /// 每次收到导航信息时调用，路线变了（新规划 / 偏航重算）就重新发送。
    /// coords、lights 都是高德坐标（纬度, 经度）。还没有坐标系（没定位）时返回 false，稍后再试。
    func onRoute(key: String, coords: [(lat: Double, lng: Double)], lights: [(lat: Double, lng: Double)]) -> Bool {
        guard let f = frame else { return false }
        if key == routeKey { return true }
        if coords.count < 2 { return false }
        routeKey = key
        prepareRoute(key: key, coords: coords)
        routeBuildSerial += 1; let serial = routeBuildSerial
        worker.async {
            var pts = [Double](repeating: 0, count: coords.count * 2)
            for (i, c) in coords.enumerated() { pts[2 * i] = f.x(c.lng); pts[2 * i + 1] = f.y(c.lat) }
            var lp = [Double](repeating: 0, count: lights.count * 2)
            for (i, c) in lights.enumerated() { lp[2 * i] = f.x(c.lng); lp[2 * i + 1] = f.y(c.lat) }
            let b = MapGeo.encodeRoute(frameId: f.id, pts: pts, maxPts: 20000, lights: lp)
            DispatchQueue.main.async {
                guard serial == self.routeBuildSerial else { return }
                self.routeId = (self.routeId + 1) & 0xFF
                self.routeBytes = b
                self.routeAcked = false
                self.routeInfo = "路线 #\(self.routeId)：\(coords.count) 个点、\(lights.count) 个红绿灯 → \(max(1, b.count / 1024)) KB"
                self.sendRoute()
            }
        }
        return true
    }

    private func sendRoute() {
        guard let b = routeBytes, enabled else { return }
        routeSentAt = Date()
        BleLink.shared.sendBulk(type: MapFeeder.TYPE_ROUTE, id: routeId, data: b)
    }

    // MARK: - 原路线

    /// 开始导航时调用：把导入的分享路线发给圆屏画成细线；nil = 不显示
    func setGhost(_ coords: [(lat: Double, lng: Double)]?) {
        ghostCoords = coords
        ghostBytes = nil; ghostAcked = false
        if coords == nil { BleLink.shared.send("#o"); return }
        encodeGhost()
    }

    private func encodeGhost() {
        guard let f = frame, let c = ghostCoords, c.count >= 2 else { return }
        var pts = [Double](repeating: 0, count: c.count * 2)
        for (i, p) in c.enumerated() { pts[2 * i] = f.x(p.lng); pts[2 * i + 1] = f.y(p.lat) }
        ghostBytes = MapGeo.encodeRoute(frameId: f.id, pts: pts, maxPts: 5000)
        ghostId = (ghostId + 1) & 0xFF
        ghostAcked = false
        sendGhost()
    }

    private func sendGhost() {
        guard let b = ghostBytes, enabled else { return }
        ghostSentAt = Date()
        BleLink.shared.sendBulk(type: MapFeeder.TYPE_GHOST, id: ghostId, data: b)
    }

    // MARK: - 确认与重发

    /// 圆屏回复 "K,类型,编号"：这一份收齐了
    func onAck(type: Int, id: Int) {
        if type == chunkType, let waiting = awaitingMapAck, waiting.id == id,
           waiting.connection == BleLink.shared.connectionGeneration {
            awaitingMapAck = nil
            chunkAcked = true; status = "圆屏已收到地图"
            upgradeBase=nil
            confirmedCenter = (chunkCx, chunkCy);lastRoofUpgradeProbe = .distantPast
            DispatchQueue.main.async { [weak self] in
                guard let self, self.chunkAcked, self.chunkId == id,
                      BleLink.shared.connectionGeneration == waiting.connection else { return }
                self.flushPreparedMap();self.flushFineRoads();self.tryUpgradeBuildings();self.applyCapabilityUpgrade()
            }
            if let coverage=chunkCoverage {
                MapPipelineTrace.event(coverage.isComplete ? "full-ack" : "first-ack",["type":type,"id":id,"mask":coverage.checkedMask,"bytes":chunkBytes?.count ?? 0,"buildings":chunkBytes.map(RasterPacket.isBuilding) ?? false])
            }
            MapPipelineTrace.event("map-ack", ["type": type, "id": id, "buildings": chunkBytes.map(RasterPacket.isBuilding) ?? false])
        }
        if type == MapFeeder.TYPE_ROUTE && id == routeId { routeAcked = true }
        if type == MapFeeder.TYPE_GHOST && id == ghostId { ghostAcked = true }
    }

    /// 蓝牙重新连上 / 小地图重新打开：圆屏可能重启过，全部重发
    func resendAll() {
        routeAcked = false; ghostAcked = false
        queueCurrentMapForSend()
        mapRetryPending = false; mapRetryUsed = false
        _ = sendChunk(); sendRoute(); sendGhost()
    }

    private func checkResend() {
        if reconnectMapPending, let at=reconnectMapAt, Date() >= at { flushReconnectMap() }
        if capabilityUpgradePending, !reconnectMapPending { applyCapabilityUpgrade() }
        if mapRetryPending, !reconnectMapPending { retryCurrentMap() }
        flushPaletteCapability()
        let b = BleLink.shared
        if !b.isReady || b.bulkPending { return }
        if mapSendPending, !reconnectMapPending { _ = sendChunk() }
        if routeBytes != nil && !routeAcked && Date().timeIntervalSince(routeSentAt) > RESEND { sendRoute() }
        if ghostBytes != nil && !ghostAcked && Date().timeIntervalSince(ghostSentAt) > RESEND { sendGhost() }
    }

    /// 高德坐标 → 小地图平面坐标（米）；还没有坐标系时返回 nil
    func toFrame(_ lat: Double, _ lng: Double) -> (x: Int, y: Int)? {
        guard let f = frame else { return nil }
        return (Int(f.x(lng).rounded()), Int(f.y(lat).rounded()))
    }

    /// iOS v0.6 首页用的一句话状态
    var shortStatus: String {
        if !enabled { return "已关闭" }
        if chunkAcked { return "圆屏已收到地图" }
        if status.hasPrefix("地图下载失败") { return "下载失败，15 秒后重试" }
        if status.hasPrefix("正在下载") { return "正在下载" }
        if haveChunk { return "已下载，等圆屏收" }
        return "导航时自动下载"
    }

    var infoText: String {
        if !enabled { return "小地图已关闭" }
        return "\(status)\n\(chunkInfo)\(chunkAcked ? "（圆屏已确认）" : "")\n\(routeInfo)\(routeAcked ? "（圆屏已确认）" : "")\n\(offlineStatus)"
    }
}

/// Explicitly enabled, bounded timing diagnostics; no images, payloads or coordinates.
enum MapPipelineTrace {
    private static let gate=NSLock()
    private static let queue=DispatchQueue(label:"motonav.map.trace")
    private static var enabled=false
    private static var buffer=MapTraceBuffer()
    private static var startUptime=0.0
    static func begin() {
        gate.lock();defer{gate.unlock()}
        queue.async {buffer=MapTraceBuffer();startUptime=ProcessInfo.processInfo.systemUptime}
        enabled=true
    }
    static func event(_ name:String,_ fields:[String:Any]=[:]) {
        gate.lock();defer{gate.unlock()}
        guard enabled else {return}
        let uptime=ProcessInfo.processInfo.systemUptime
        queue.async {buffer.append(name:name,fields:fields,seconds:uptime-startUptime)}
    }
    static func packet(_ bytes:Data,type:Int,id:Int,ready:Bool) {
        gate.lock();let recording=enabled;gate.unlock()
        guard recording else {return}
        event("map-send",["type":type,"id":id,"bytes":bytes.count,"ready":ready,
            "decodeValid":RasterPacket.valid(bytes),"buildings":RasterPacket.isBuilding(bytes),"packetVersion":RoadPalette.packetVersion(bytes),"paletteVersion":BleLink.shared.roadPaletteVersion])
    }
    static func finish(completion:@escaping(URL?)->Void) {
        gate.lock();defer{gate.unlock()};enabled=false
        queue.async {
            let root=FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0].appendingPathComponent("MotoNav-Diagnostics",isDirectory:true)
            let url=root.appendingPathComponent("map-timing-"+UUID().uuidString+".json")
            var report=buffer.document
            report["version"]=APP_VERSION;report["build"]=Bundle.main.object(forInfoDictionaryKey:"CFBundleVersion") ?? ""
            report["note"]="User-started timing session. No keys, cookies, raw packets, images, route names or geographic coordinates."
            do {
                try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
                try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:url,options:.atomic)
                DispatchQueue.main.async{completion(url)}
            } catch {DispatchQueue.main.async{completion(nil)}}
        }
    }
}

final class MapTraceReport:ObservableObject {
    static let shared=MapTraceReport()
    @Published private(set) var recording=false
    @Published private(set) var exporting=false
    @Published private(set) var files:[URL]=[]
    @Published private(set) var status="开始模拟前记录，出现底图空白后停止并导出。"
    private var timer:Timer?
    private init() {
        let manager=FileManager.default
        let saved=manager.urls(for:.documentDirectory,in:.userDomainMask)[0].appendingPathComponent("MotoNav-Diagnostics",isDirectory:true)
        let legacy=manager.urls(for:.cachesDirectory,in:.userDomainMask)[0].appendingPathComponent("map-pipeline",isDirectory:true)
        if let previous=MapReportFiles.latestTiming(in:[saved,legacy]) {
            files=[previous];status="已找到上次保存的衔接记录，可直接保存或分享。"
        }
    }
    func begin() {
        guard !recording && !exporting else {return}
        files=[];recording=true;status="正在记录地图衔接，最长 10 分钟。"
        MapPipelineTrace.begin()
        MapPipelineTrace.event("session-start",["maxWrite":BleLink.shared.maxWrite,"ready":BleLink.shared.isReady,"style":Settings.shared.theme])
        timer=Timer.scheduledTimer(withTimeInterval:600,repeats:false){[weak self] _ in self?.finish()}
    }
    func finish() {
        guard recording else {return}
        timer?.invalidate();timer=nil;recording=false;exporting=true;status="正在整理记录…"
        MapPipelineTrace.event("session-stop")
        MapPipelineTrace.finish{url in
            self.exporting=false
            self.files=url.map{[$0]} ?? []
            self.status=url == nil ? "记录保存失败，请重试。":"记录已保存，仅含地图准备、传输与确认的时间和状态。"
        }
    }
}
