import Foundation
import CoreLocation
import ObjectiveC

/// 版本：跟随 App 版本（见 Config.swift）
///
/// 官方骑行桥接层（AMapNaviRideManager），结构上镜像 NaviBridge 已验证的做法：
/// - 规划用 SDK 的**无途经点独立骑行算路接口**（independentCalculateRideRoute），策略为多路线默认值；
///   保存返回的 AMapNaviRouteGroup，预览、选路和开始导航都用同一组结果。
/// - 每次规划绑定独立请求代次（planSeq + ArrivalPolicy 代次）；25 秒超时，
///   取消或过期的结果不得覆盖新输入；接受 SDK 实际返回的路线数量，不强求多条。
/// - 回调隔离沿用 NaviBridge 的会话代次代理（RideSessionCallbacks），并复用 ArrivalPolicy。
/// - 导航中由 SDK 负责偏航重算，不叠加旧引擎的偏航计数和路线跟踪；
///   重算失败时保留当前路线与导航并提供重试，不在途中切换引擎。
/// - 沿用现有语音服务（Speech）并关闭 SDK 内置播报（isUseInternalTTS = false），
///   静音、音乐压低和耳机输出由 Speech / Settings 原有逻辑负责。
/// - 算路失败明确区分权限、网络和实现错误（RidePlanFailure），不做兼容模式静默降级。
/// - Task 2：真实 / 模拟导航全链路 —— SDK 回调转换为现有导航读数和圆屏 BLE 消息
///   （转向、距离、道路文字、车速、剩余里程、ETA、GPS 状态、到达事件，协议与驾车/独立引擎一致，
///   不改 ESP32 通信协议）；路线变化更新沿线地图（MapFeeder）；真实导航记录轨迹
///   （RideRecorder，模拟不记录），结束后立即恢复真实定位来源；后台/锁屏沿用驾车做法
///   （allowsBackgroundLocationUpdates + 沿线缓存策略）；定位活动类型由 LocationService 按骑行设为 .fitness。
/// - 历史只保存规划输入（起终点），恢复时重新算路；不保存或伪造可长期复用的 SDK 路线 ID。
final class RideBridge: NSObject, ObservableObject {
    static let shared = RideBridge()

    // MARK: 给界面看的状态
    @Published var calculating = false
    @Published var routeReady = false
    @Published var navigating = false
    @Published var info = "（还没开始骑行导航）"
    @Published var routeSummary = ""
    @Published var planFailed = false              // 规划失败 / 超时（界面上给“重新规划”）
    @Published private(set) var failure: RidePlanFailure?   // 失败分类：权限 / 网络 / 实现
    @Published var routeOptions: [NaviBridge.RouteOption] = []   // 复用驾车路线卡片类型（时间/距离/坐标）
    @Published var selectedRouteID = -1
    // 导航信息（手机界面）
    @Published var uiDir = ""
    @Published var uiDist = -1
    @Published var uiRoad = ""
    @Published var uiSpeed = 0
    @Published var uiRemainM = 0
    @Published var uiRemainS = 0
    // 模拟导航：暂停 / 继续，自行车档位 10 → 20 → 30 循环（NavigationSpeed 统一策略，SDK 上限 120）
    @Published private(set) var emulating = false
    @Published private(set) var emuPaused = false
    @Published private(set) var emuSpeed = NavigationSpeed.bicycleDefault
    @Published var preferredSimulationSpeed = NavigationSpeed.bicycleDefault
    @Published var showArrived = false            // 刚到达：显示“已到达”4 秒再收尾
    @Published var rerouteFailed = false          // 导航中重算失败：保留当前路线，可重试

    /// 规划超时（需求规定 25 秒；测试里可以调短）
    static var planTimeout: TimeInterval = 25

    private var manager: AMapNaviRideManager? { NavigationCoordinator.shared.rideManagerIfActive() }
    private var attached = false
    private let arrival = ArrivalPolicy()
    private var sessionCallbacks: RideSessionCallbacks?
    private var planSeq = 0
    private var planSettled = true                // 本代次规划是否已有结果（独立算路回调块为准）
    private var routeGroup: AMapNaviRouteGroup?   // 预览、选路和开始导航共用的同一组结果
    private var destLat = Double.nan, destLng = Double.nan
    private var planOrigin: (lat: Double, lng: Double)?
    private var endName = ""                      // 规划输入的一部分（历史记录用）
    private var historyEligible = true            // 分享路线的官方重划不进历史（沿用分享不记历史）
    private var arriveSeq = 0
    // 圆屏与沿线地图（消息格式与驾车/独立引擎一致，不改 ESP32 协议）
    private let screen = RideScreenFeed()         // 圆屏消息去重状态
    private var lastRouteKey = ""                 // 已发给小地图的路线（新规划/偏航重算时重发）
    private var tripStarted = Date(), tripMeters = 0.0, tripMaxKmh = 0
    private var tripPosition: (lat: Double, lng: Double)?
    private var rerouting = false                 // 圆屏“重新规划中”提示（#y）
    private var gpsWeakSent = false               // GPS 信号弱提示（#x）只在变化时发

    // MARK: - 引擎与会话

    func acceptsCallback(_ token: UInt64) -> Bool { arrival.acceptsCallbacks(token) }
    func performCallback(_ token: UInt64, _ body: (RideBridge) -> Void) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard arrival.acceptsCallbacks(token) else { return }
        body(self)
    }

    private func installCallbacks() {
        guard let m = manager else { return }
        if let old = sessionCallbacks?.asRepresentative { m.removeDataRepresentative(old) }
        m.delegate = nil
        let callbacks = RideSessionCallbacks(bridge: self, token: arrival.generation)
        sessionCallbacks = callbacks
        m.delegate = callbacks.asDelegate
        if let r = callbacks.asRepresentative { m.addDataRepresentative(r) }
    }

    /// 认领骑行引擎（互斥单例由 NavigationCoordinator 统一销毁 / 创建）。
    /// 返回 false = 引擎没能就绪（例如驾车引擎没能销毁），本次操作不得继续。
    @discardableResult
    func attach() -> Bool {
        if attached, manager != nil { return true }
        guard NavigationCoordinator.shared.activate(.ride) == nil else {
            info = NavigationCoordinator.shared.lastFailure ?? "骑行引擎没能就绪，请重试"
            return false
        }
        guard let m = manager else {
            info = "骑行引擎没能创建，请重试"
            return false
        }
        attached = true
        arrival.preparePlan()
        installCallbacks()
        m.isUseInternalTTS = false                // 关闭 SDK 内置播报，文字交给现有语音服务
        m.allowsBackgroundLocationUpdates = true  // 锁屏继续定位（沿用驾车做法）
        m.pausesLocationUpdatesAutomatically = false
        return true
    }

    /// NavigationCoordinator 切换引擎时的第 1+2 步：先失效旧回调（会话代次），
    /// 再停止导航和相关任务。stopNavi 可能同步触发模拟结束回调，所以代次必须先失效。
    func stopForEngineSwitch() {
        planSeq += 1
        planSettled = true
        arrival.cancel(arrival.generation)
        arriveSeq += 1
        showArrived = false
        navigating = false
        emulating = false
        emuPaused = false
        rerouteFailed = false
        rerouting = false
        screen.reset()
        if let m = manager { m.stopNavi() }
    }

    /// 第 3+4 步：解绑 delegate 和数据代表，释放持有的引用，清空规划状态。
    func unbindForEngineSwitch() {
        if let m = manager {
            if let r = sessionCallbacks?.asRepresentative { m.removeDataRepresentative(r) }
            m.delegate = nil
        }
        sessionCallbacks = nil
        attached = false
        calculating = false; routeReady = false; planFailed = false; failure = nil
        routeOptions = []; selectedRouteID = -1; routeSummary = ""
        routeGroup = nil
        destLat = .nan; destLng = .nan; planOrigin = nil; endName = ""; historyEligible = true
        uiDir = ""; uiDist = -1; uiRoad = ""; uiRemainM = 0; uiRemainS = 0
        lastRouteKey = ""; screen.reset()
        MapFeeder.shared.onNaviEnd()               // 选路时预下载的沿线地图一并停掉（和驾车一致）
        info = "（还没开始骑行导航）"
    }

    // MARK: - 规划（无途经点独立算路）

    /// 规划去 (lat, lng)（高德坐标）的骑行路线。origin 为 nil 时由 SDK 用当前位置作起点。
    /// endName / historyEligible 属于规划输入的元信息：普通自行车规划成功后进历史（只存起终点），
    /// 分享路线的官方重划不进历史（和分享导入不记历史一致）。
    func plan(toLat lat: Double, lng: Double, origin: MotorPoint? = nil,
              endName: String = "", historyEligible: Bool = true) {
        guard !navigating, !NavigationCoordinator.shared.navigationActive else { return }
        guard MotorRequest.valid(lat, lng),
              origin.map({ MotorRequest.valid($0.lat, $0.lng) }) ?? true else {
            clearPlan()
            failure = .implementation("起终点无效")
            info = "起终点无效，请重新选择"
            planFailed = true
            return
        }
        guard attach() else {
            calculating = false
            failure = .implementation(info)
            planFailed = true
            return
        }
        destLat = lat; destLng = lng
        planOrigin = origin.map { ($0.lat, $0.lng) }
        self.endName = endName
        self.historyEligible = historyEligible
        replan()
    }

    /// 按上次的目的地重新规划（规划失败 / 超时后的“重新规划”按钮）
    func replan(retry: Int = 1) {
        guard !destLat.isNaN, !navigating, !NavigationCoordinator.shared.navigationActive, attached else { return }
        planFailed = false
        failure = nil
        let holdingArrival = arrival.canClearArrival(arrival.generation)
        arrival.cancel(arrival.generation)
        if holdingArrival { manager?.stopNavi() }
        arrival.preparePlan()
        installCallbacks()
        guard let end = AMapNaviPoint.location(withLatitude: CGFloat(destLat), longitude: CGFloat(destLng)) else { return }
        guard let m = manager else {
            info = "骑行引擎没能就绪，请重试"
            failure = .implementation(info)
            planFailed = true
            return
        }
        planSeq += 1
        planSettled = false
        calculating = true
        routeReady = false
        routeOptions = []; selectedRouteID = -1
        routeSummary = ""; routeGroup = nil
        let endPOI = AMapNaviPOIInfo()
        endPOI.locPoint = end
        var startPOI: AMapNaviPOIInfo?
        if let o = planOrigin, let s = AMapNaviPoint.location(withLatitude: CGFloat(o.lat), longitude: CGFloat(o.lng)) {
            let p = AMapNaviPOIInfo()
            p.locPoint = s
            startPOI = p
        }
        let seq = planSeq
        let token = arrival.generation
        info = "正在规划骑行路线…"
        let ok = m.independentCalculateRideRoute(withStart: startPOI, end: endPOI, strategy: .multipleDefault) { [weak self] group, error in
            let failure = error as NSError?
            let action = { [weak self] in
                guard let self = self else { return }
                self.performCallback(token) { bridge in
                    bridge.planDone(seq: seq, group: group, error: failure)
                }
            }
            if Thread.isMainThread { action() } else { DispatchQueue.main.async(execute: action) }
        }
        if !ok {
            calculating = false
            planSettled = true
            if retry > 0 {                      // 引擎可能还没准备好：1.5 秒后自动再试一次（和驾车一致）
                info = "规划路线没能开始，马上自动再试一次…"
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                    guard let self = self, seq == self.planSeq else { return }
                    self.replan(retry: retry - 1)
                }
            } else {
                planFailed = true
                failure = .implementation("规划请求没能开始（还没定位？检查定位权限和高德 key）")
                info = "规划路线没能开始（还没定位？检查定位权限和高德 key）"
            }
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + RideBridge.planTimeout) { [weak self] in
            guard let self = self, seq == self.planSeq, self.calculating else { return }
            self.calculating = false
            self.planSettled = true
            self.planFailed = true
            self.failure = .network("规划超时（\(Int(RideBridge.planTimeout)) 秒），请检查网络后重试")
            self.info = "规划超时"
        }
    }

    /// 独立算路回调（主线程、按代次过滤后到达）：同一代次只认第一个结果。
    fileprivate func planDone(seq: Int, group: AMapNaviRouteGroup?, error: NSError?) {
        guard seq == planSeq, !navigating, calculating || !planSettled else { return }
        planSettled = true
        calculating = false
        if let error = error, group == nil {
            routeReady = false
            planFailed = true
            failure = RidePlanFailure.classify(error)
            info = "骑行路线规划失败：\(failure?.detail ?? error.localizedDescription)"
            return
        }
        guard let group = group, !(group.naviRoutes ?? [:]).isEmpty else {
            routeReady = false
            planFailed = true
            failure = .implementation("SDK 没有返回骑行路线")
            info = "骑行路线规划失败：SDK 没有返回路线"
            return
        }
        routeGroup = group
        routeReady = true
        planFailed = false
        failure = nil
        buildOptions(from: group)
        info = routeOptions.count > 1 ? "规划好了 \(routeOptions.count) 条骑行路线，点卡片选一条" : "骑行路线规划好了"
        if let f = routeOptions.first { select(routeID: f.id) }
        if let f = routeOptions.first { recordHistory(f) }
    }

    /// 从同一组结果里取出所有路线做对比卡片；接受 SDK 实际返回的数量，不强求多条。
    private func buildOptions(from group: AMapNaviRouteGroup) {
        let routes = group.naviRoutes ?? [:]
        let ids = (group.naviRouteIDs ?? []).map { $0.intValue }.filter { routes[NSNumber(value: $0)] != nil }
        var opts: [NaviBridge.RouteOption] = []
        for (i, id) in (ids.isEmpty ? [group.naviRouteID] : ids).enumerated() {
            guard let r = routes[NSNumber(value: id)] ?? (id == group.naviRouteID ? group.naviRoute : nil) else { continue }
            let label = r.routeLabels?.first(where: { !$0.content.isEmpty })?.content ?? (i == 0 ? "推荐" : "方案\(i + 1)")
            opts.append(NaviBridge.RouteOption(id: id, label: label, timeS: r.routeTime, length: r.routeLength,
                                              lights: 0, toll: 0,
                                              coords: r.routeCoordinates.map { CLLocationCoordinate2D(latitude: Double($0.latitude), longitude: Double($0.longitude)) }))
        }
        routeOptions = opts
    }

    /// 选一条路线（在保存的 routeGroup 上选，开始导航仍用同一组结果）
    func select(routeID: Int) {
        selectedRouteID = routeID
        _ = routeGroup?.selectNaviRoute(withRouteID: routeID)
        if let o = routeOptions.first(where: { $0.id == routeID }) {
            routeSummary = "\(NaviBridge.distText(o.length))，约 \(NaviBridge.durText(o.timeS))"
            // 选路后预下载沿线地图（锁屏用缓存，和驾车一致）
            MapFeeder.shared.prepareRoute(key: "ride-\(routeID)", coords: o.coords.map { (lat: $0.latitude, lng: $0.longitude) })
        }
    }

    /// 历史只保存规划输入（起终点），恢复时重新算路；不保存 SDK 路线 ID 或路线几何。
    /// 起点没手选时用当前定位（和网页规划记“我的位置”一致）；连定位都没有就不记这次。
    private func recordHistory(_ option: NaviBridge.RouteOption) {
        guard historyEligible else { return }
        let start: MotorPoint
        if let o = planOrigin { start = MotorPoint(lat: o.lat, lng: o.lng, name: "所选起点") }
        else if let l = LocationService.shared.location, l.horizontalAccuracy >= 0, l.horizontalAccuracy <= 100,
                abs(l.timestamp.timeIntervalSinceNow) < 15,
                MotorRequest.valid(l.coordinate.latitude, l.coordinate.longitude) {
            let g = MapGeo.wgsToGcj(l.coordinate.latitude, l.coordinate.longitude)
            start = MotorPoint(lat: g.lat, lng: g.lng, name: "我的位置")
        } else { return }
        MotorPlanHistory.shared.save(request: MotorRequest(start: start,
                                                          end: MotorPoint(lat: destLat, lng: destLng, name: endName),
                                                          vias: [], bicycle: true),
                                    distance: option.length, seconds: option.timeS)
    }

    /// 不去这个目的地了（换目的地）
    func clearPlan() {
        if navigating { return }
        let holdingArrival = arrival.canClearArrival(arrival.generation)
        arrival.cancel(arrival.generation)
        if holdingArrival { manager?.stopNavi() }
        arriveSeq += 1
        showArrived = false
        planSeq += 1
        planSettled = true
        destLat = .nan; destLng = .nan; planOrigin = nil; endName = ""; historyEligible = true
        calculating = false; routeReady = false; planFailed = false; failure = nil
        routeOptions = []; selectedRouteID = -1
        routeSummary = ""; routeGroup = nil
        lastRouteKey = ""; screen.reset()
        MapFeeder.shared.onNaviEnd()
        info = "（还没开始骑行导航）"
    }

    // MARK: - 导航（真实 / 模拟）

    /// 开始导航。开始前必须先成功规划；真实 / 模拟都从保存的 routeGroup 启动。
    func start(emulate: Bool) {
        guard routeReady, !navigating, !NavigationCoordinator.shared.navigationActive else { return }
        guard attach() else {
            failure = .implementation(info)
            planFailed = true
            return
        }
        guard let m = manager, let group = routeGroup else {
            info = "骑行路线还没就绪，请重新规划"
            failure = .implementation(info)
            planFailed = true
            return
        }
        // 清掉上一次到达后的保持状态再挂本次会话回调（stopNavi 可能同步发模拟结束：先关闸）
        arrival.cancel(arrival.generation)
        m.stopNavi()
        resetState()
        let token = arrival.begin(simulation: emulate)
        installCallbacks()
        navigating = true                                  // 先置位再启动：SDK 回调可能同步到达
        emulating = emulate
        emuPaused = false
        if emulate {
            emuSpeed = NavigationSpeed.normalized(preferredSimulationSpeed, bicycle: true)
            m.setEmulatorNaviSpeed(Int32(emuSpeed))        // SDK 骑行模拟速度范围 [10,120]，自行车档位全部在内
        }
        let ok = emulate ? m.startEmulatorNavi(group) : m.startGPSNavi(group)
        if ok && arrival.acceptsGuidance(token) {
            // 真实导航用手机精确定位（活动类型 .fitness 由 LocationService 决定）并记录轨迹；模拟不记录
            if !emulate { RideRecorder.shared.start("骑行导航"); LocationService.shared.setPrecise(true) }
            screen.reset()
            BleLink.shared.send("C")               // 圆屏先回待机，再接收本次导航的读数
            MapFeeder.shared.onNaviStart()
            info = emulate ? "模拟骑行导航中" : "骑行导航中"
        } else if !ok && arrival.acceptsGuidance(token) {
            finish("导航没能开始", arrived: false, event: nil)
        }
    }

    /// 模拟导航：暂停 / 继续
    func toggleEmuPause() {
        guard navigating, emulating, let m = manager else { return }
        emuPaused.toggle()
        if emuPaused { m.pauseNavi() } else { m.resumeNavi() }
    }

    /// 模拟导航车速：自行车档位 10 → 20 → 30 km/h 循环（官方骑行始终自行车档）
    func cycleEmuSpeed() {
        guard navigating, emulating, let m = manager else { return }
        emuSpeed = NavigationSpeed.next(emuSpeed, bicycle: true)
        m.setEmulatorNaviSpeed(Int32(emuSpeed))
    }

    func stop() {
        arrival.cancel(arrival.generation)                 // stopNavi 可能同步发模拟结束：先关闸
        manager?.stopNavi()
        finish("已退出骑行导航", arrived: false, event: nil)
    }

    /// 导航中 SDK 重算失败后的重试（保持当前路线与导航，不切换引擎）
    func retryRecalculate() {
        guard navigating, rerouteFailed, let m = manager else { return }
        if m.recalculateRideRoute() {
            rerouteFailed = false
            info = "正在重新规划骑行路线…"
        }
    }

    private func finish(_ text: String, arrived: Bool, event: ArrivalPolicy.EndEvent?) {
        let token = arrival.generation
        if arrived {
            guard let event = event, arrival.complete(token, event: event) else { return }
        } else {
            arrival.cancel(token)
        }
        emulating = false
        emuPaused = false
        Settings.shared.resetTunnel()
        RideRecorder.shared.finish()                       // 真实导航结束轨迹（没在记录时是空操作）
        LocationService.shared.setPrecise(false)           // 模拟结束立即恢复真实定位来源
        MapFeeder.shared.onNaviEnd()
        arriveSeq += 1
        showArrived = arrived                              // 先设这个再设 navigating：界面据此决定等 4 秒
        navigating = false
        info = text
        uiDir = ""; uiDist = -1
        rerouteFailed = false
        rerouting = false
        screen.reset()
        if arrived {
            // 和驾车一致：先报行程统计，圆屏显示“已到达”4 秒后清屏回待机
            let minutes = max(1, Int(Date().timeIntervalSince(tripStarted) / 60))
            BleLink.shared.send("#O\(Int(tripMeters))/\(minutes)/\(tripMaxKmh)")
            BleLink.shared.send("A,0")
            let seq = arriveSeq
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
                guard let self = self, seq == self.arriveSeq, self.arrival.canClearArrival(token),
                      !self.navigating else { return }
                // 引擎可能已被切换销毁：不能为了收尾而重建旧单例
                NavigationCoordinator.shared.rideManagerIfActive()?.stopNavi()
                self.resetState()
                self.showArrived = false
                BleLink.shared.send("C")
            }
        } else {
            BleLink.shared.send("C")                       // 手动退出：圆屏直接回待机
        }
    }

    private func resetState() {
        uiDir = ""; uiDist = -1; uiRoad = ""; uiSpeed = 0; uiRemainM = 0; uiRemainS = 0
        rerouteFailed = false
        lastRouteKey = ""; tripMeters = 0; tripMaxKmh = 0; tripStarted = Date(); tripPosition = nil
        rerouting = false; gpsWeakSent = false
        screen.reset()
    }

    // MARK: - SDK 回调（由带会话代次的代理转发，见文末 RideSessionCallbacks）

    fileprivate func onSdkError(_ error: NSError?) {
        guard let error = error else { return }
        if navigating {
            // 导航中的通用错误按重算失败处理：保留当前路线与导航，提供重试
            rerouteFailed = true
            info = "重新规划失败：已保留当前路线，可点重试"
            return
        }
        guard calculating, !planSettled else { return }
        planDone(seq: planSeq, group: nil, error: error)
    }

    fileprivate func onRouteCalculated() {
        if navigating {                                    // 导航中偏航重算成功
            rerouteFailed = false
            setRerouting(false)
            return
        }
        // 规划结果以独立算路回调块为准；这里的成功回调忽略，避免同一结果处理两次
    }

    fileprivate func onRouteCalculateFailure(_ error: NSError?) {
        if navigating {
            rerouteFailed = true
            setRerouting(false)                            // “重新规划中”收起，改为提示保留当前路线
            info = "重新规划失败：已保留当前路线，可点重试"
            return
        }
        guard calculating, !planSettled else { return }    // 兜底：结果以回调块为准
        planDone(seq: planSeq, group: nil, error: error)
    }

    fileprivate func onSound(_ text: String?) {
        if let t = text { Speech.shared.speak(t) }         // 沿用现有语音服务
    }

    fileprivate func onArrived() {
        finish("已到达目的地", arrived: true, event: .destination)
    }

    fileprivate func onEmulatorEnd() {
        finish("模拟骑行导航结束", arrived: true, event: .emulator)
    }

    fileprivate func onYaw() {
        guard navigating else { return }
        setRerouting(true)                                 // 圆屏显示“重新规划中”（SDK 自动重算，不叠加旧引擎的偏航计数）
        info = "偏离路线，正在重新规划…"
    }

    // MARK: - 圆屏读数与沿线地图（协议与驾车/独立引擎一致）

    /// 圆屏上显示 / 收起 “重新规划中”（只在导航进行中；与驾车同格式 #y）
    func setRerouting(_ on: Bool) {
        if on && !navigating { return }
        if on == rerouting { return }
        rerouting = on
        BleLink.shared.send(on ? "#y,1" : "#y,0")
    }

    /// GPS 信号强弱：2 = 弱（与驾车同格式 #x），只在变化时发
    fileprivate func onGps(_ strength: Int) {
        let weak = strength == 2
        guard weak != gpsWeakSent else { return }
        gpsWeakSent = weak
        BleLink.shared.send(weak ? "#x,1" : "#x,0")
    }

    private func roundDist(_ d: Int) -> Int { d >= 1000 ? (d + 50) / 100 * 100 : d }

    /// 转向消息 “方向,米”：与驾车/独立引擎同格式；A 方向转成 S 发往圆屏，A,0 只留给真正的到达回调
    private func pushTurn(_ dir: String, _ dist: Int) {
        let msg = "\(ArrivalPolicy.wireDirection(dir)),\(roundDist(dist))"
        guard msg != screen.lastTurn else { return }
        screen.lastTurn = msg
        BleLink.shared.send(msg)
    }

    /// 道路文字、底部“剩余里程 · 到达时间”和 #e（剩余里程/ETA）：与驾车 updateTexts 同格式
    private func pushTexts(road: String, remainM: Int, remainS: Int) {
        if road != screen.lastRoad {
            screen.lastRoad = road
            TextImage.send(slot: 0, road, maxW: 290, size: 26, minSize: 18)
        }
        let km = remainM >= 1000 ? String(format: "%.1fkm", Double(remainM) / 1000) : "\(remainM)m"
        let eta = Calendar.current.date(byAdding: .second, value: remainS, to: Date()) ?? Date()
        let hh = Calendar.current.component(.hour, from: eta), mm = Calendar.current.component(.minute, from: eta)
        let bottom = String(format: "%@ · %02d:%02d到达", km, hh, mm)
        if bottom != screen.lastBottom {
            screen.lastBottom = bottom
            TextImage.send(slot: 1, bottom, maxW: 240, size: 19, minSize: 15)
        }
        let rm = remainM >= 1000 ? (remainM + 50) / 100 * 100 : remainM
        let trip = "#e,\(rm),\(hh * 100 + mm),0"
        if trip != screen.lastTrip { screen.lastTrip = trip; BleLink.shared.send(trip) }
    }

    /// 路线变化（新规划 / 偏航重算）时把整条路线发给小地图（与驾车 mnNaviInfo 同做法）
    private func pushRouteMap() {
        guard let r = manager?.naviRoute else { return }
        let rk = "\(r.routeUID):\(r.routeLength)"
        guard rk != lastRouteKey else { return }
        let coords = r.routeCoordinates.map { (lat: Double($0.latitude), lng: Double($0.longitude)) }
        if MapFeeder.shared.onRoute(key: rk, coords: coords, lights: []) { lastRouteKey = rk }
    }

    fileprivate func onNaviInfo(_ n: AMapNaviInfo?) {
        // 和驾车侧一致：导航结束后迟到的引导信息不得再改界面状态
        guard arrival.acceptsGuidance(arrival.generation), let n = n else { return }
        let dir = NaviBridge.iconToDir(n.iconType.rawValue)
        uiDir = dir
        // 显示侧取整（与驾车 uiDist 同规则：>=1000 米取整到百位）；圆屏线上格式由 pushTurn 单独处理
        uiDist = roundDist(n.segmentRemainDistance)
        uiRemainM = n.routeRemainDistance
        uiRemainS = n.routeRemainTime
        if dir == "A" { uiRoad = "前方为目的地" }
        else if dir == "S", let cur = n.currentRoadName, !cur.isEmpty { uiRoad = "沿 \(cur) 直行" }
        else if let next = n.nextRoadName, !next.isEmpty { uiRoad = "进入 \(next)" }
        else { uiRoad = "" }
        pushRouteMap()
        pushTurn(dir, n.segmentRemainDistance)
        pushTexts(road: uiRoad, remainM: n.routeRemainDistance, remainS: n.routeRemainTime)
        setRerouting(false)                                // 有新的导航信息 = 重新规划好了
        if rerouteFailed { rerouteFailed = false; info = emulating ? "模拟骑行导航中" : "骑行导航中" }
    }

    fileprivate func onLocation(_ l: AMapNaviLocation?) {
        guard arrival.acceptsGuidance(arrival.generation), let l = l else { return }
        let kmh = max(0, l.speed)
        uiSpeed = kmh
        if let c = l.coordinate {
            // SDK 匹配位置用于导航（小地图、行程统计）；轨迹记录走手机定位（RideRecorder）
            let lat = Double(c.latitude), lng = Double(c.longitude)
            if let p = tripPosition { let d = NaviBridge.distM(p.lat, p.lng, lat, lng); if d < 300 { tripMeters += d } }
            tripPosition = (lat, lng)
            tripMaxKmh = max(tripMaxKmh, kmh)
            MapFeeder.shared.onLocation(lat: lat, lng: lng, bearing: l.heading, kmh: kmh)
        }
        let msg = "#v,\(kmh)"
        if msg != screen.lastSpeed { screen.lastSpeed = msg; BleLink.shared.send(msg) }
    }
}

/// 圆屏消息的去重状态（消息格式见 RideBridge；这里只记录上一次发送的内容）
private final class RideScreenFeed {
    var lastTurn = "", lastRoad = "", lastBottom = "", lastTrip = "", lastSpeed = ""
    func reset() { lastTurn = ""; lastRoad = ""; lastBottom = ""; lastTrip = ""; lastSpeed = "" }
}

// MARK: - 失败分类

/// 骑行算路失败的三类原因（Task 1：明确区分权限错误、网络问题和实现错误）。
/// detail 面向用户，不包含 key、cookie 或精确位置等敏感信息。
enum RidePlanFailure: Equatable {
    case permission(String)        // 定位权限被拒 / 缺少精确定位
    case network(String)           // 网络失败 / 超时
    case implementation(String)    // 其他 SDK 或实现错误

    /// 按 AMapNaviCalcRouteState 错误码分类（AMapNaviCalcRouteStateCLAuthorizationStatusDenied = 3000、
    /// …ReducedAccuracy = 3001、AMapNaviCalcRouteStateNetworkError = 2）。
    static func classify(_ error: NSError) -> RidePlanFailure {
        switch error.code {
        case 3000:
            return .permission("App 没有定位权限，请在系统设置里允许定位后重试")
        case 3001:
            return .permission("缺少精确定位权限，请在系统设置里开启精确定位后重试")
        case 2:
            return .network("网络连接不上，请检查网络后重试")
        default:
            return .implementation("暂时没能完成（错误码 \(error.code)），请重试")
        }
    }

    var detail: String {
        switch self {
        case .permission(let text), .network(let text), .implementation(let text): return text
        }
    }

    var title: String {
        switch self {
        case .permission: return "定位权限问题"
        case .network: return "网络问题"
        case .implementation: return "暂时没能完成"
        }
    }
}

// MARK: - 会话代次回调代理
// 和 NaviSessionCallbacks 一样：每个 SDK 代理记录自己的代次，迟到或已被替换的代理
// 不能把结果或导航信息发布给新会话。协议在运行时登记（见 CLAUDE.md 高德坑第 1 条）。

final class RideSessionCallbacks: NSObject {
    private weak var bridge: RideBridge?
    private let token: UInt64

    init(bridge: RideBridge, token: UInt64) {
        self.bridge = bridge
        self.token = token
        super.init()
        class_addProtocol(RideSessionCallbacks.self, AMapNaviRideManagerDelegate.self)
        class_addProtocol(RideSessionCallbacks.self, AMapNaviRideDataRepresentable.self)
    }
    var asDelegate: AMapNaviRideManagerDelegate? { (self as AnyObject) as? AMapNaviRideManagerDelegate }
    var asRepresentative: AMapNaviRideDataRepresentable? { (self as AnyObject) as? AMapNaviRideDataRepresentable }

    private func deliver(_ body: @escaping (RideBridge) -> Void) {
        let action = { [weak bridge = bridge, token = token] in
            bridge?.performCallback(token, body)
        }
        if Thread.isMainThread { action() }
        else { DispatchQueue.main.async { action() } }
    }

    @objc(rideManager:error:)
    func mnError(_ m: AMapNaviRideManager, error: NSError?) {
        deliver { bridge in bridge.onSdkError(error) }
    }

    @objc(rideManagerOnCalculateRouteSuccess:)
    func mnRouteSuccess(_ m: AMapNaviRideManager) {
        deliver { bridge in bridge.onRouteCalculated() }
    }

    @objc(rideManager:onCalculateRouteFailure:)
    func mnRouteFail(_ m: AMapNaviRideManager, error: NSError?) {
        deliver { bridge in bridge.onRouteCalculateFailure(error) }
    }

    @objc(rideManager:playNaviSoundString:soundStringType:)
    func mnSound(_ m: AMapNaviRideManager, text: String?, type: Int) {
        deliver { bridge in bridge.onSound(text) }
    }

    @objc(rideManagerOnArrivedDestination:)
    func mnArrived(_ m: AMapNaviRideManager) {
        deliver { bridge in bridge.onArrived() }
    }

    @objc(rideManagerDidEndEmulatorNavi:)
    func mnEmuEnd(_ m: AMapNaviRideManager) {
        deliver { bridge in bridge.onEmulatorEnd() }
    }

    @objc(rideManagerNeedRecalculateRouteForYaw:)
    func mnYaw(_ m: AMapNaviRideManager) {
        deliver { bridge in bridge.onYaw() }
    }

    @objc(rideManager:updateGPSSignalStrength:)
    func mnGps(_ m: AMapNaviRideManager, strength: Int) {
        deliver { bridge in bridge.onGps(strength) }
    }

    @objc(rideManager:updateNaviInfo:)
    func mnNaviInfo(_ m: AMapNaviRideManager, info n: AMapNaviInfo?) {
        deliver { bridge in bridge.onNaviInfo(n) }
    }

    @objc(rideManager:updateNaviLocation:)
    func mnLocation(_ m: AMapNaviRideManager, location l: AMapNaviLocation?) {
        deliver { bridge in bridge.onLocation(l) }
    }
}
