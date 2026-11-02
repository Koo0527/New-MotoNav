"""Exercise the production RideBridge with the ride SDK boundary stubbed (macOS, no device)."""
from pathlib import Path
import os
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
bridge = (root / 'MotoNav/RideBridge.swift').read_text()
arrival = (root / 'MotoNav/ArrivalPolicy.swift').read_text()
history = (root / 'MotoNav/MotorPlanHistory.swift').read_text()
speeds = (root / 'MotoNav/NavigationSpeed.swift').read_text()

stubs = r'''
import Foundation
import CoreLocation
import Combine
import ObjectiveC
func check(_ condition: Bool, _ message: String) {
    if !condition { print("FAIL: \(message)"); exit(1) }
}
func wait(_ seconds: Double) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }
struct MotorPoint: Codable { let lat: Double; let lng: Double; var name = "" }
struct MotorRequest: Codable {
    var start: MotorPoint; let end: MotorPoint; var vias: [MotorPoint] = []; var bicycle = false
    static func valid(_ lat: Double, _ lng: Double) -> Bool { lat.isFinite && lng.isFinite && abs(lat) <= 90 && abs(lng) <= 180 }
}
final class Speech {
    static let shared = Speech()
    var spoken: [String] = []
    func speak(_ text: String) { spoken.append(text) }
}
final class Settings {
    static let shared = Settings()
    var tunnelResets = 0
    func resetTunnel() { tunnelResets += 1 }
}
final class LocationService {
    static let shared = LocationService()
    var preciseCalls: [Bool] = []
    var location: CLLocation?
    func setPrecise(_ on: Bool) { preciseCalls.append(on) }
}
// ---- 圆屏 / 沿线地图 / 轨迹边界（记录调用，供圆屏输出断言） ----
final class BleLink {
    static let shared = BleLink()
    var sent: [String] = []
    func send(_ msg: String) { sent.append(msg) }
}
final class MapFeeder {
    static let shared = MapFeeder()
    var naviStarts = 0, naviEnds = 0
    var preparedRoutes: [String] = []
    var routeKeys: [String] = []
    var locations: [(lat: Double, lng: Double, bearing: Double, kmh: Int)] = []
    func onNaviStart() { naviStarts += 1 }
    func onNaviEnd() { naviEnds += 1 }
    func prepareRoute(key: String, coords: [(lat: Double, lng: Double)]) { preparedRoutes.append(key) }
    func onRoute(key: String, coords: [(lat: Double, lng: Double)], lights: [(lat: Double, lng: Double)]) -> Bool {
        guard coords.count >= 2 else { return false }
        routeKeys.append(key); return true
    }
    func onLocation(lat: Double, lng: Double, bearing: Double, kmh: Int) { locations.append((lat, lng, bearing, kmh)) }
}
final class RideRecorder {
    static let shared = RideRecorder()
    var started: [String] = [], finished = 0
    func start(_ mode: String) { started.append(mode) }
    func finish() { finished += 1 }
}
final class TextImage {
    static let shared = TextImage()
    var slots: [Int: [String]] = [:]
    static func send(slot: Int, _ text: String, maxW: Int, size: CGFloat, minSize: CGFloat) {
        TextImage.shared.slots[slot, default: []].append(text)
    }
}
enum MapGeo { static func wgsToGcj(_ lat: Double, _ lng: Double) -> (lat: Double, lng: Double) { (lat, lng) } }
struct MotorRoute { let request: MotorRequest; let totalMeters: Int; let seconds: Int }
final class NaviBridge {
    static let shared = NaviBridge()
    var navigating = false
    struct RouteOption: Identifiable {
        let id: Int; let label: String; let timeS: Int; let length: Int; let lights: Int; let toll: Int
        let coords: [CLLocationCoordinate2D]
    }
    static func iconToDir(_ icon: Int) -> String {
        switch icon {
        case 2, 6, 21: return "L"
        case 3, 7, 22: return "R"
        case 4, 65: return "SL"
        case 5, 66: return "SR"
        case 8, 19, 24: return "U"
        case 15: return "A"
        default: return "S"
        }
    }
    static func distText(_ m: Int) -> String { "\(m)" }
    static func durText(_ s: Int) -> String { "\(s)" }
    static func distM(_ lat1: Double, _ lng1: Double, _ lat2: Double, _ lng2: Double) -> Double {
        let k = Double.pi / 180
        let x = (lng2 - lng1) * k * cos((lat1 + lat2) / 2 * k)
        let y = (lat2 - lat1) * k
        return (x * x + y * y).squareRoot() * 6_371_000.0
    }
}
final class WebMotorSession { static let shared = WebMotorSession(); var running = false }
// Coordinator stub: the coordinator's own order is covered by tests/nav-coordinator.
final class NavigationCoordinator {
    static let shared = NavigationCoordinator()
    enum Engine: String, Equatable { case none, drive, ride }
    var active: Engine = .none
    var navigationActive: Bool { NaviBridge.shared.navigating || RideBridge.shared.navigating || WebMotorSession.shared.running }
    var activateFailure: String?
    var lastFailure: String?
    let rideManager = AMapNaviRideManager()
    func activate(_ target: Engine) -> String? {
        if let f = activateFailure { return f }
        active = target
        return nil
    }
    func rideManagerIfActive() -> AMapNaviRideManager? { active == .ride ? rideManager : nil }
}
// ---- ride SDK boundary ----
enum AMapNaviTravelStrategy: Int { case multipleDefault = 1001 }
@objc protocol AMapNaviRideManagerDelegate: AnyObject {}
@objc protocol AMapNaviRideDataRepresentable: AnyObject {}
final class AMapNaviPoint: NSObject {
    var latitude: CGFloat = 0, longitude: CGFloat = 0
    static func location(withLatitude lat: CGFloat, longitude lng: CGFloat) -> AMapNaviPoint? {
        let p = AMapNaviPoint(); p.latitude = lat; p.longitude = lng; return p
    }
}
final class AMapNaviPOIInfo: NSObject { var mid: String?; var locPoint: AMapNaviPoint? }
final class AMapNaviRouteLabel: NSObject { var content: String = "" }
final class AMapNaviRoute: NSObject {
    var routeTime = 0, routeLength = 0, routeUID = 0
    var routeLabels: [AMapNaviRouteLabel]? = []
    var routeCoordinates: [AMapNaviPoint] = []
}
final class AMapNaviRouteGroup: NSObject {
    var naviRouteID: Int = 1
    var naviRoute: AMapNaviRoute?
    var naviRouteIDs: [NSNumber]? = []
    var naviRoutes: [NSNumber: AMapNaviRoute]? = [:]
    var selections: [Int] = []
    func selectNaviRoute(withRouteID id: Int) -> Bool { selections.append(id); return true }
}
enum AMapNaviIconType: Int { case left = 2, straight = 9, destination = 15 }
final class AMapNaviInfo: NSObject {
    var iconType: AMapNaviIconType = .straight
    var segmentRemainDistance = 0, routeRemainDistance = 0, routeRemainTime = 0
    var currentRoadName: String?, nextRoadName: String?
}
final class AMapNaviLocation: NSObject {
    var speed: Int = 0
    var heading: Double = 0
    var coordinate: AMapNaviPoint?
}
final class AMapNaviRideManager: NSObject {
    weak var delegate: AMapNaviRideManagerDelegate?
    var representatives: [AMapNaviRideDataRepresentable] = []
    var isUseInternalTTS: Bool?
    var allowsBackgroundLocationUpdates: Bool?
    var pausesLocationUpdatesAutomatically: Bool?
    var naviRoute: AMapNaviRoute?
    var calcStartPOI: AMapNaviPOIInfo?
    var calcEndPOI: AMapNaviPOIInfo?
    var calcStrategy: AMapNaviTravelStrategy?
    var calcCallback: ((AMapNaviRouteGroup?, NSError?) -> Void)?
    var stopNaviCalls = 0, pauseCalls = 0, resumeCalls = 0, recalculated = 0
    var emulatorSpeeds: [Int32] = []
    var startedGroups: [AMapNaviRouteGroup] = []
    var startedGPSGroups: [AMapNaviRouteGroup] = []
    func addDataRepresentative(_ r: AMapNaviRideDataRepresentable) { representatives.append(r) }
    func removeDataRepresentative(_ r: AMapNaviRideDataRepresentable) { representatives.removeAll { $0 === r } }
    func independentCalculateRideRoute(withStart s: AMapNaviPOIInfo?, end e: AMapNaviPOIInfo,
                                       strategy: AMapNaviTravelStrategy,
                                       callback: ((AMapNaviRouteGroup?, NSError?) -> Void)?) -> Bool {
        calcStartPOI = s; calcEndPOI = e; calcStrategy = strategy; calcCallback = callback
        return true
    }
    func stopNavi() { stopNaviCalls += 1 }
    func pauseNavi() { pauseCalls += 1 }
    func resumeNavi() { resumeCalls += 1 }
    func setEmulatorNaviSpeed(_ speed: Int32) { emulatorSpeeds.append(speed) }
    func startEmulatorNavi() -> Bool { true }
    func startEmulatorNavi(_ group: AMapNaviRouteGroup) -> Bool { startedGroups.append(group); return true }
    func startGPSNavi() -> Bool { true }
    func startGPSNavi(_ group: AMapNaviRouteGroup) -> Bool { startedGPSGroups.append(group); return true }
    func recalculateRideRoute() -> Bool { recalculated += 1; return true }
}
func makeRoute(id: Int, time: Int, length: Int, label: String) -> AMapNaviRoute {
    let r = AMapNaviRoute(); r.routeTime = time; r.routeLength = length
    let l = AMapNaviRouteLabel(); l.content = label; r.routeLabels = [l]
    let a = AMapNaviPoint.location(withLatitude: 31, longitude: 121)
    let b = AMapNaviPoint.location(withLatitude: 31.01, longitude: 121.01)
    r.routeCoordinates = [a!, b!]
    return r
}
func makeGroup() -> AMapNaviRouteGroup {
    let g = AMapNaviRouteGroup()
    let a = makeRoute(id: 1, time: 600, length: 3000, label: "推荐")
    let b = makeRoute(id: 2, time: 700, length: 2800, label: "少步行")
    g.naviRouteID = 1; g.naviRoute = a
    g.naviRouteIDs = [NSNumber(value: 1), NSNumber(value: 2)]
    g.naviRoutes = [NSNumber(value: 1): a, NSNumber(value: 2): b]
    return g
}
'''

tests = r'''
@main struct Tests {
    @MainActor static func main() {
        let coordinator = NavigationCoordinator.shared
        let bridge = RideBridge.shared
        check(RideBridge.planTimeout == 25, "the production plan-timeout default is the required 25 seconds")
        RideBridge.planTimeout = 25

        // 无效输入：不认领引擎，不发出算路请求
        bridge.plan(toLat: 91, lng: 121)
        check(bridge.planFailed && !bridge.calculating, "invalid destination fails the plan")
        check(coordinator.active == .none, "invalid input never claims the ride engine")
        check(coordinator.rideManager.calcCallback == nil, "invalid input never reaches the SDK")

        // 正常规划：认领引擎 → 独立算路（多路线默认策略）→ 保存 routeGroup → 自动选第一条
        bridge.plan(toLat: 31.2, lng: 121.5)
        check(coordinator.active == .ride, "planning claims the ride engine")
        check(bridge.calculating && !bridge.routeReady, "plan is in flight")
        check(coordinator.rideManager.calcStrategy == .multipleDefault, "strategy is the multi-route default")
        check(coordinator.rideManager.calcStartPOI == nil && coordinator.rideManager.calcEndPOI != nil,
              "no manual origin passes nil start (SDK uses current location)")
        coordinator.rideManager.calcCallback?(makeGroup(), nil)
        check(!bridge.calculating && bridge.routeReady, "successful callback readies the route")
        check(bridge.routeOptions.count == 2, "both returned routes become options (SDK count accepted)")
        check(bridge.routeOptions[1].label == "少步行", "route labels are surfaced")
        check(bridge.selectedRouteID == 1, "the default route is auto-selected")
        // selection happens on the saved group; start uses the same group
        bridge.select(routeID: 2)
        check(bridge.routeSummary.contains("700"), "summary carries the selected route time")

        // 起点：手选起点时传给 SDK
        bridge.plan(toLat: 31.3, lng: 121.6, origin: MotorPoint(lat: 31.0, lng: 121.0, name: "起点"))
        check(coordinator.rideManager.calcStartPOI != nil, "manual origin is forwarded to the SDK")
        coordinator.rideManager.calcCallback?(makeGroup(), nil)

        // 请求代次：取消或过期的结果不得覆盖新输入
        bridge.plan(toLat: 31.4, lng: 121.7)
        let stale = coordinator.rideManager.calcCallback
        bridge.plan(toLat: 31.5, lng: 121.8)
        stale?(nil, NSError(domain: "test", code: 2))
        check(!bridge.planFailed && bridge.failure == nil, "a cancelled request's error cannot fail the new one")
        let staleGroup = makeGroup()
        stale?(staleGroup, nil)
        check(bridge.calculating, "a cancelled request's result cannot complete the new one")
        coordinator.rideManager.calcCallback?(makeGroup(), nil)
        check(bridge.routeReady && !bridge.calculating, "the current request's result wins")

        // 25 秒超时（此处调短验证）
        RideBridge.planTimeout = 0.05
        bridge.plan(toLat: 31.6, lng: 121.9)
        wait(0.2)
        check(bridge.planFailed && !bridge.calculating, "timeout fails the plan")
        if case .network(let d)? = bridge.failure { check(d.contains("超时"), "timeout is classified as a network problem") }
        else { check(false, "timeout is classified as a network problem") }
        RideBridge.planTimeout = 25

        // 错误分类：权限 / 网络 / 实现
        let expectedKinds: [Int: String] = [3000: "permission", 2: "network", 13: "implementation"]
        for code in [3000, 2, 13] {
            bridge.plan(toLat: 31.6, lng: 121.9)
            coordinator.rideManager.calcCallback?(nil, NSError(domain: "AMapNavi", code: code))
            let kind: String
            switch bridge.failure { case .permission: kind = "permission" case .network: kind = "network" case .implementation: kind = "implementation" case nil: kind = "none" }
            check(kind == expectedKinds[code], "error code \(code) maps to \(expectedKinds[code]!)")
            check(bridge.planFailed, "classified failure marks the plan failed")
            if code == 3000 { check(bridge.failure?.detail.contains("定位") == true, "permission failures tell the user how to recover") }
            if code == 13 { check(bridge.failure?.detail.contains("13") == true, "implementation failures carry the SDK code without sensitive data") }
        }

        // 开始模拟导航：保存的 routeGroup 原样交给 SDK；SDK 内置播报关掉
        bridge.plan(toLat: 31.7, lng: 122.0)
        coordinator.rideManager.calcCallback?(makeGroup(), nil)
        bridge.preferredSimulationSpeed = 30
        bridge.start(emulate: true)
        check(bridge.navigating && bridge.emulating, "emulator navigation is armed")
        check(coordinator.rideManager.startedGroups.count == 1, "navigation starts with the saved route group")
        check(coordinator.rideManager.isUseInternalTTS == false, "SDK built-in announcements stay disabled")
        check(coordinator.rideManager.emulatorSpeeds.last == 30, "preferred bicycle simulation gear is applied without clamping")
        check(LocationService.shared.preciseCalls.isEmpty, "simulation does not require precise location")

        // 导航信息 → 界面状态
        let info = AMapNaviInfo()
        info.iconType = .left; info.segmentRemainDistance = 120; info.routeRemainDistance = 1500
        info.routeRemainTime = 600; info.currentRoadName = "测试路"; info.nextRoadName = "林荫道"
        bridge.testNaviInfo(info)
        check(bridge.uiDir == "L" && bridge.uiDist == 120, "turn info reaches the UI state")
        check(bridge.uiRoad.contains("林荫道"), "road name follows the drive text rules")
        check(bridge.uiRemainM == 1500, "remaining distance is published")
        // 显示侧取整（与驾车 uiDist 同规则：>=1000 米取整到百位）；圆屏线上格式不变
        let far = AMapNaviInfo()
        far.iconType = .left; far.segmentRemainDistance = 1580; far.routeRemainDistance = 5200
        far.routeRemainTime = 900
        bridge.testNaviInfo(far)
        check(bridge.uiDist == 1600 && bridge.uiRemainM == 5200, "display turn distance rounds to hundreds past 1 km")

        // 模拟导航：暂停 / 继续、调速
        bridge.toggleEmuPause()
        check(bridge.emuPaused && coordinator.rideManager.pauseCalls == 1, "pause reaches the SDK")
        bridge.toggleEmuPause()
        check(!bridge.emuPaused && coordinator.rideManager.resumeCalls == 1, "resume reaches the SDK")
        let speedBefore = bridge.emuSpeed
        bridge.cycleEmuSpeed()
        check(bridge.emuSpeed == NavigationSpeed.next(speedBefore, bicycle: true), "speed cycles the bicycle gears 10/20/30")

        // 导航中重算失败：保留当前路线与导航，提供重试；SDK 负责偏航重算
        bridge.testRouteCalculateFailure(NSError(domain: "AMapNavi", code: 2))
        check(bridge.rerouteFailed && bridge.navigating, "recalc failure keeps the current navigation")
        check(coordinator.rideManager.stopNaviCalls == 1, "recalc failure does not stop navigation (only start's guard stop)")
        bridge.retryRecalculate()
        check(!bridge.rerouteFailed && coordinator.rideManager.recalculated == 1, "retry asks the SDK to recalculate")

        // 播报文字走现有语音服务
        bridge.testSound("前方100米左转")
        check(Speech.shared.spoken.last == "前方100米左转", "announcements go through the shared speech service")

        // 到达：模拟结束 → 显示“已到达”4 秒 → 收尾；重复终点回调被忽略
        let stopsBefore = coordinator.rideManager.stopNaviCalls
        bridge.testEmulatorEnd()
        check(!bridge.navigating && bridge.showArrived, "emulator end shows arrival")
        bridge.testArrived()
        check(!bridge.navigating && bridge.showArrived, "a duplicate terminal callback is ignored")
        check(bridge.emulating == false, "emulation flags are cleared")
        wait(4.3)
        check(!bridge.showArrived, "arrival clears after four seconds")
        check(coordinator.rideManager.stopNaviCalls == stopsBefore + 1, "the SDK is stopped once during arrival cleanup")

        // 迟到的导航信息不得再改界面状态
        let late = AMapNaviInfo(); late.iconType = .left; late.segmentRemainDistance = 5
        bridge.testNaviInfo(late)
        check(bridge.uiDir.isEmpty && bridge.uiDist == -1, "late guidance cannot redraw a finished trip")

        // 主动退出
        bridge.plan(toLat: 31.8, lng: 122.1)
        coordinator.rideManager.calcCallback?(makeGroup(), nil)
        bridge.start(emulate: true)
        bridge.testNaviInfo(info)
        let tunnelResetsBeforeStop = Settings.shared.tunnelResets
        bridge.stop()
        check(Settings.shared.tunnelResets == tunnelResetsBeforeStop + 1, "stop resets tunnel dimming exactly once")
        check(!bridge.navigating && !bridge.showArrived, "stop ends navigation without the arrival banner")
        check(bridge.uiDir.isEmpty, "stop clears turn state")

        // 手动退出导航 → 重新规划 → 新代次安装新的会话代理
        let oldDelegate = coordinator.rideManager.delegate
        bridge.plan(toLat: 31.9, lng: 122.2)
        check(coordinator.rideManager.delegate != nil && coordinator.rideManager.delegate !== oldDelegate,
              "each plan installs a fresh session relay")

        // 引擎切换钩子：失效回调 → 停止 → 解绑，状态归零
        coordinator.rideManager.calcCallback?(makeGroup(), nil)
        bridge.stopForEngineSwitch()
        check(!bridge.navigating && !bridge.emulating, "halt drops navigation state (route release waits for unbind)")
        check(coordinator.rideManager.stopNaviCalls > 0, "halt stops the SDK")
        bridge.unbindForEngineSwitch()
        check(coordinator.rideManager.delegate == nil && coordinator.rideManager.representatives.isEmpty,
              "unbind removes delegate and data representatives")
        check(bridge.routeOptions.isEmpty && bridge.selectedRouteID == -1, "unbind clears route options")

        // attach 失败（驾车引擎销毁失败）：不得继续规划
        coordinator.activateFailure = "驾车引擎没能释放，请重试"
        bridge.plan(toLat: 31.9, lng: 122.3)
        check(bridge.planFailed && !bridge.calculating && !bridge.routeReady, "engine-claim failure fails the plan")
        if case .implementation? = bridge.failure { check(true, "engine-claim failure is an implementation error") }
        else { check(false, "engine-claim failure is an implementation error") }
        coordinator.activateFailure = nil

        // 未经规划不得开始导航
        RideBridge.shared.start(emulate: true)
        check(!RideBridge.shared.navigating, "navigation cannot start without a ready route")

        // ---- Task 2：真实导航 + 圆屏读数 + 沿线地图 + 轨迹 + 历史 ----
        UserDefaults.standard.removeObject(forKey: "motor_plan_history_v1")
        MotorPlanHistory.shared.clear(bicycle: true)
        let ble = BleLink.shared, feeder = MapFeeder.shared, recorder = RideRecorder.shared
        LocationService.shared.location = CLLocation(coordinate: CLLocationCoordinate2D(latitude: 31.0, longitude: 121.0),
                                                     altitude: 0, horizontalAccuracy: 20, verticalAccuracy: 0,
                                                     course: 0, speed: 0, timestamp: Date())
        check(recorder.started.isEmpty, "plans and simulated navigation never record tracks")
        // 后台定位沿用驾车做法（锁屏继续、不自动暂停）
        check(coordinator.rideManager.allowsBackgroundLocationUpdates == true, "ride engine keeps location alive in the background")
        check(coordinator.rideManager.pausesLocationUpdatesAutomatically == false, "ride engine does not auto-pause location")

        // 历史只存规划输入：目的地 + 起点（没手选就记“我的位置”），不带 SDK 路线 ID
        bridge.plan(toLat: 31.7, lng: 122.0, endName: "公园")
        coordinator.rideManager.calcCallback?(makeGroup(), nil)
        check(MotorPlanHistory.shared.plans.count == 1, "a successful official ride plan stores its planning inputs")
        let savedPlan = MotorPlanHistory.shared.plans.first!
        check(savedPlan.request.bicycle && savedPlan.request.end.lat == 31.7 && savedPlan.request.end.name == "公园",
              "history keeps the destination input")
        check(savedPlan.request.start.name == "我的位置", "an unspecified origin is recorded as the current position")
        check(feeder.preparedRoutes.last == "ride-1", "selecting a route prepares the along-route map")

        // 真实导航：圆屏回待机、沿线地图会话启动、轨迹开始、手机精确定位
        ble.sent.removeAll(); feeder.naviStarts = 0; recorder.finished = 0
        bridge.start(emulate: false)
        check(bridge.navigating && !bridge.emulating, "real navigation is armed")
        check(coordinator.rideManager.startedGPSGroups.count == 1, "real navigation starts with the saved route group")
        check(ble.sent.last == "C", "the round screen is reset when navigation starts")
        check(feeder.naviStarts == 1, "the along-route map session starts")
        check(recorder.started == ["骑行导航"], "real ride navigation records a track")
        check(recorder.finished == 0, "the track stays open while navigating")
        check(LocationService.shared.preciseCalls.last == true, "real navigation requests precise phone location")

        // 圆屏读数：转向、道路文字、剩余里程 / ETA（与驾车/独立引擎同格式）
        ble.sent.removeAll(); TextImage.shared.slots.removeAll()
        let info2 = AMapNaviInfo()
        info2.iconType = .left; info2.segmentRemainDistance = 120; info2.routeRemainDistance = 1500
        info2.routeRemainTime = 600; info2.currentRoadName = "测试路"; info2.nextRoadName = "林荫道"
        bridge.testNaviInfo(info2)
        check(ble.sent.contains("L,120"), "turn guidance follows the existing wire format")
        check(ble.sent.contains { $0.hasPrefix("#e,1500,") }, "remaining distance and ETA follow the #e format")
        check((TextImage.shared.slots[0] ?? []).last == "进入 林荫道", "road text goes to round-screen slot 0")
        check((TextImage.shared.slots[1] ?? []).last?.contains("到达") == true, "the ETA footer goes to round-screen slot 1")
        bridge.testNaviInfo(info2)
        check(ble.sent.filter { $0 == "L,120" }.count == 1, "identical guidance is not re-sent")

        // 到达方向 A 转成 S 发往圆屏（A,0 只留给真正的到达回调）
        let infoA = AMapNaviInfo()
        infoA.iconType = .destination; infoA.segmentRemainDistance = 30; infoA.routeRemainDistance = 30
        infoA.routeRemainTime = 60; infoA.currentRoadName = "终点路"
        ble.sent.removeAll()
        bridge.testNaviInfo(infoA)
        check(ble.sent.contains("S,30"), "destination-ahead direction is wired as S")

        // 位置与车速 → 圆屏车速、小地图位置
        let loc1 = AMapNaviLocation(); loc1.speed = 18; loc1.heading = 90
        loc1.coordinate = AMapNaviPoint.location(withLatitude: 31.71, longitude: 121.99)
        let loc2 = AMapNaviLocation(); loc2.speed = 20; loc2.heading = 95
        loc2.coordinate = AMapNaviPoint.location(withLatitude: 31.72, longitude: 121.995)
        ble.sent.removeAll()
        bridge.testNaviLocation(loc1)
        bridge.testNaviLocation(loc2)
        check(ble.sent.contains("#v,18") && ble.sent.contains("#v,20"), "speed follows the #v format")
        check(feeder.locations.last?.kmh == 20 && feeder.locations.last?.bearing == 95, "the matched position feeds the along-route map")

        // GPS 信号弱只在变化时发
        ble.sent.removeAll()
        bridge.testGps(2); bridge.testGps(2); bridge.testGps(0)
        check(ble.sent == ["#x,1", "#x,0"], "gps state changes follow the #x format without repeats")

        // 偏航 → 圆屏“重新规划中”；重算失败收起提示并保留导航；新导航信息清除提示
        ble.sent.removeAll()
        bridge.testYaw()
        check(ble.sent.last == "#y,1", "yaw shows the reroute flag")
        bridge.testRouteCalculateFailure(NSError(domain: "AMapNavi", code: 2))
        check(ble.sent.last == "#y,0", "recalc failure clears the reroute flag")
        check(bridge.rerouteFailed && bridge.navigating, "recalc failure keeps the current navigation")
        bridge.testYaw()
        bridge.testNaviInfo(info2)
        check(ble.sent.last == "#y,0" && !bridge.rerouteFailed, "fresh guidance clears the reroute flag")

        // 到达：行程统计 + A,0 + 4 秒后 C；轨迹结束、沿线地图结束、恢复真实定位来源
        ble.sent.removeAll(); feeder.naviEnds = 0
        bridge.testArrived()
        check(ble.sent.contains { $0.hasPrefix("#O") }, "arrival reports the trip summary")
        check(ble.sent.contains("A,0"), "arrival is announced on the wire")
        check(recorder.finished == 1, "the track is closed on arrival")
        check(feeder.naviEnds == 1, "the along-route map session ends")
        check(LocationService.shared.preciseCalls.last == false, "arrival restores the real location source immediately")
        wait(4.3)
        check(ble.sent.last == "C", "the round screen returns to idle four seconds after arrival")

        // 分享重划（historyEligible=false）不进历史；同起终点的重复规划也不产生重复条目
        let historyBefore = MotorPlanHistory.shared.plans.count
        bridge.plan(toLat: 31.75, lng: 122.05, endName: "分享终点", historyEligible: false)
        coordinator.rideManager.calcCallback?(makeGroup(), nil)
        check(MotorPlanHistory.shared.plans.count == historyBefore, "official re-plans of a share never enter history")
        bridge.plan(toLat: 31.7, lng: 122.0, endName: "公园")
        coordinator.rideManager.calcCallback?(makeGroup(), nil)
        check(MotorPlanHistory.shared.plans.count == historyBefore, "re-planning the same inputs does not duplicate history")

        // 手动退出：圆屏回待机、轨迹收尾
        ble.sent.removeAll(); feeder.naviEnds = 0
        bridge.start(emulate: false)
        bridge.testNaviInfo(info2)
        bridge.stop()
        check(ble.sent.last == "C", "manual exit returns the round screen to idle")
        check(recorder.finished == 2, "manual exit closes the track")
        check(feeder.naviEnds == 1, "manual exit ends the along-route map session")
        UserDefaults.standard.removeObject(forKey: "motor_plan_history_v1")

        // ---- Task 4 回归：连续改变起终点（最新输入生效，过期结果丢弃）----
        bridge.clearPlan()
        bridge.plan(toLat: 30.1, lng: 110.1, endName: "第一目的地")
        bridge.plan(toLat: 30.2, lng: 110.2, endName: "第二目的地")
        bridge.plan(toLat: 30.3, lng: 110.3, endName: "最终目的地")
        check(abs(coordinator.rideManager.calcEndPOI!.locPoint!.latitude - 30.3) < 1e-9
              && abs(coordinator.rideManager.calcEndPOI!.locPoint!.longitude - 110.3) < 1e-9,
              "after consecutive destination changes only the latest input reaches the SDK")
        let firstCallback = coordinator.rideManager.calcCallback
        bridge.plan(toLat: 30.4, lng: 110.4, endName: "又一次")
        firstCallback?(makeGroup(), nil)                       // 两代之前的迟到结果
        check(bridge.calculating && !bridge.routeReady && bridge.routeOptions.isEmpty,
              "a result from two destination generations back is discarded")
        coordinator.rideManager.calcCallback?(makeGroup(), nil)
        check(bridge.routeReady && bridge.routeOptions.first?.id == 1, "the latest request's result wins")

        // ---- Task 4 回归：算路超时后迟到结果不覆盖新输入，且可重试 ----
        RideBridge.planTimeout = 0.05
        bridge.clearPlan()
        bridge.plan(toLat: 30.5, lng: 110.5)
        wait(0.2)
        check(bridge.planFailed && !bridge.calculating, "the 25 s plan timeout fires (shortened here)")
        coordinator.rideManager.calcCallback?(makeGroup(), nil) // 超时后才到的结果
        check(!bridge.routeReady && bridge.planFailed && bridge.routeOptions.isEmpty,
              "a result arriving after the timeout cannot satisfy or overwrite the timed-out request")
        bridge.replan()                                          // “重新规划”按钮
        check(bridge.calculating && !bridge.planFailed, "re-plan after a timeout retries the same destination")
        coordinator.rideManager.calcCallback?(makeGroup(), nil)
        check(bridge.routeReady, "the retried plan succeeds")
        RideBridge.planTimeout = 25

        // ---- Task 4 回归：路线选择一致性（预览、选路、开始导航同一 AMapNaviRouteGroup）----
        bridge.plan(toLat: 30.45, lng: 110.45)
        let identityGroup = makeGroup()
        coordinator.rideManager.calcCallback?(identityGroup, nil)
        check(bridge.routeReady && bridge.routeOptions.count == 2, "the identity group becomes the preview options")
        bridge.select(routeID: 2)
        check(identityGroup.selections == [1, 2],
              "selection happens on the saved group itself (auto first route, then the user's pick)")
        bridge.start(emulate: false)
        check(coordinator.rideManager.startedGPSGroups.last === identityGroup,
              "navigation starts with the exact route group that previewed and was selected")
        bridge.stop()
        bridge.start(emulate: true)
        check(coordinator.rideManager.startedGroups.last === identityGroup,
              "emulated navigation reuses the same saved route group")
        bridge.stop()

        // ---- Task 4 回归：重算失败保留原线、不自动切换引擎 ----
        bridge.plan(toLat: 30.6, lng: 110.6)
        coordinator.rideManager.calcCallback?(makeGroup(), nil)
        bridge.start(emulate: false)
        bridge.testNaviInfo(info2)
        let managerBefore = coordinator.rideManager
        bridge.testRouteCalculateFailure(NSError(domain: "AMapNavi", code: 2))
        check(bridge.rerouteFailed && bridge.navigating && bridge.routeReady,
              "an in-navigation recalculation failure keeps the current route and navigation")
        check(coordinator.active == .ride && coordinator.rideManager === managerBefore,
              "recalculation failure never switches or recreates the engine")
        bridge.retryRecalculate()
        check(!bridge.rerouteFailed && coordinator.rideManager === managerBefore && coordinator.active == .ride,
              "retry recalculates without touching engine ownership")

        // ---- Task 4 回归：重复到达只结算一次（对齐 ArrivalPolicy 语义）----
        ble.sent.removeAll()
        bridge.testNaviInfo(info2)
        bridge.testArrived()
        let tripSummaries = ble.sent.filter { $0.hasPrefix("#O") }.count
        let arrivalMarks = ble.sent.filter { $0 == "A,0" }.count
        check(tripSummaries == 1 && arrivalMarks == 1, "the first terminal callback settles exactly once")
        bridge.testArrived()
        bridge.testEmulatorEnd()
        ble.sent.removeAll()
        bridge.testArrived()
        check(ble.sent.filter { $0.hasPrefix("#O") }.count == 0 && !ble.sent.contains("A,0"),
              "duplicate destination and emulator-end callbacks produce no second settlement")
        check(!bridge.navigating, "settled trip stays finished")
        wait(4.3)
        // 真实导航收到杂散的模拟结束回调必须被策略拒绝；随后真正的到达回调照常结算
        bridge.plan(toLat: 30.7, lng: 110.7)
        coordinator.rideManager.calcCallback?(makeGroup(), nil)
        bridge.start(emulate: false)
        ble.sent.removeAll()
        bridge.testEmulatorEnd()
        check(bridge.navigating && !ble.sent.contains("A,0"),
              "a stray emulator-end callback cannot finish a GPS ride navigation (ArrivalPolicy gate)")
        bridge.testArrived()
        check(!bridge.navigating && ble.sent.contains("A,0"), "the real destination callback then settles once")
        wait(4.3)

        // ---- Task 4 回归：模拟结束/取消恢复真实定位来源（Build14 语义，ride 路径）----
        LocationService.shared.preciseCalls.removeAll()
        bridge.plan(toLat: 30.8, lng: 110.8)
        coordinator.rideManager.calcCallback?(makeGroup(), nil)
        bridge.start(emulate: true)
        bridge.toggleEmuPause()
        feeder.locations.removeAll()
        bridge.stop()                                            // 模拟中手动取消
        check(!bridge.emulating && !bridge.emuPaused, "cancelling an emulation clears both emulation flags")
        check(LocationService.shared.preciseCalls.last == false,
              "cancelling an emulation restores the real location source immediately")
        let lateEmuLocation = AMapNaviLocation(); lateEmuLocation.speed = 25
        lateEmuLocation.coordinate = AMapNaviPoint.location(withLatitude: 30.81, longitude: 110.81)
        bridge.testNaviLocation(lateEmuLocation)
        check(feeder.locations.isEmpty, "late simulator fixes cannot move the map position after the trip ended")
        feeder.routeKeys.removeAll()
        coordinator.rideManager.naviRoute = makeRoute(id: 9, time: 600, length: 3000, label: "收尾路线")
        bridge.testNaviInfo(info2)
        check(feeder.routeKeys.isEmpty, "late guidance cannot re-feed the along-route map")
        // 新会话从干净状态开始：同样的读数会重新下发（去重状态已随会话重置）
        bridge.plan(toLat: 30.9, lng: 110.9)
        coordinator.rideManager.calcCallback?(makeGroup(), nil)
        bridge.start(emulate: true)
        ble.sent.removeAll()
        bridge.testNaviInfo(info2)
        check(ble.sent.contains("L,120"), "a fresh session re-sends the same guidance (per-session dedup reset)")

        // ---- Task 4 回归：旧代次代理的迟到回调不得覆盖新会话（规划 / 导航 / 地图）----
        bridge.stopForEngineSwitch(); bridge.unbindForEngineSwitch()
        func currentToken() -> UInt64 {
            for t in UInt64(1)...1024 where bridge.acceptsCallback(t) { return t }
            fatalError("no live ride session token found")
        }
        // 规划代次：旧代理的失败/结果都不得影响新规划
        bridge.plan(toLat: 31.0, lng: 111.0)
        let oldPlanRelay = RideSessionCallbacks(bridge: bridge, token: currentToken())
        bridge.plan(toLat: 31.1, lng: 111.1)                     // 新规划代次
        oldPlanRelay.mnRouteFail(coordinator.rideManager, error: NSError(domain: "AMapNavi", code: 2))
        check(bridge.calculating && !bridge.planFailed,
              "a retained previous-generation relay cannot fail the new plan")
        oldPlanRelay.mnRouteSuccess(coordinator.rideManager)
        coordinator.rideManager.calcCallback?(makeGroup(), nil)
        check(bridge.routeReady && bridge.routeOptions.count == 2,
              "the stale relay's success callback does not double-settle the new plan")
        // 导航代次：旧代理的导航信息/到达不得覆盖新导航会话
        bridge.start(emulate: false)
        let navRelayOld = oldPlanRelay                            // 规划代次的代理在导航代次里也已过期
        let freshNavRelay = RideSessionCallbacks(bridge: bridge, token: currentToken())
        feeder.routeKeys.removeAll()
        coordinator.rideManager.naviRoute = makeRoute(id: 9, time: 600, length: 3000, label: "当前路线")
        navRelayOld.mnNaviInfo(coordinator.rideManager, info: info2)
        check(bridge.uiDir.isEmpty && feeder.routeKeys.isEmpty,
              "a stale relay cannot publish guidance to the new navigation session")
        navRelayOld.mnArrived(coordinator.rideManager)
        check(bridge.navigating, "a stale relay cannot finish the new navigation session")
        freshNavRelay.mnNaviInfo(coordinator.rideManager, info: info2)
        check(bridge.uiDir == "L" && bridge.uiDist == 120, "the current relay's guidance is published")
        check(feeder.routeKeys.count == 1, "the current relay feeds the along-route map")
        coordinator.rideManager.naviRoute = makeRoute(id: 9, time: 600, length: 4500, label: "换一条路线")
        navRelayOld.mnNaviInfo(coordinator.rideManager, info: info2)
        check(feeder.routeKeys.count == 1,
              "a stale relay cannot re-feed the map even when its payload carries a different route")
        bridge.stop()
        UserDefaults.standard.removeObject(forKey: "motor_plan_history_v1")

        print("PASS ride bridge: planning, generations, timeout, error classes, selection, navigation, round screen, reroute, arrival, history and teardown")
        print("PASS ride bridge task4: consecutive inputs, timeout retry, route identity, reroute keeps line, single settlement, emulation restore, stale relay isolation")
    }
}
'''

# Test-only hooks so the harness can drive the private @objc relay handlers directly.
bridge = bridge.replace('    fileprivate func onRouteCalculateFailure(', '    func testRouteCalculateFailure(_ error: NSError?) { onRouteCalculateFailure(error) }\n    fileprivate func onRouteCalculateFailure(')
bridge = bridge.replace('    fileprivate func onSound(', '    func testSound(_ text: String?) { onSound(text) }\n    fileprivate func onSound(')
bridge = bridge.replace('    fileprivate func onArrived()', '    func testArrived() { onArrived() }\n    fileprivate func onArrived()')
bridge = bridge.replace('    fileprivate func onEmulatorEnd()', '    func testEmulatorEnd() { onEmulatorEnd() }\n    fileprivate func onEmulatorEnd()')
bridge = bridge.replace('    fileprivate func onNaviInfo(', '    func testNaviInfo(_ n: AMapNaviInfo?) { onNaviInfo(n) }\n    fileprivate func onNaviInfo(')
bridge = bridge.replace('    fileprivate func onLocation(', '    func testNaviLocation(_ l: AMapNaviLocation?) { onLocation(l) }\n    fileprivate func onLocation(')
bridge = bridge.replace('    fileprivate func onGps(', '    func testGps(_ strength: Int) { onGps(strength) }\n    fileprivate func onGps(')
bridge = bridge.replace('    fileprivate func onYaw()', '    func testYaw() { onYaw() }\n    fileprivate func onYaw()')

with tempfile.TemporaryDirectory(prefix='motonav-ride-bridge-') as tmp:
    swift = Path(tmp) / 'main.swift'
    swift.write_text(stubs + speeds + '\n' + arrival + history + bridge + tests)
    env = dict(os.environ, CLANG_MODULE_CACHE_PATH=str(Path(tmp) / 'cache'), SWIFT_MODULE_CACHE_PATH=str(Path(tmp) / 'cache'))
    subprocess.run(['swiftc', '-parse-as-library', str(swift), '-o', str(Path(tmp) / 'check')], check=True, env=env)
    subprocess.run([str(Path(tmp) / 'check')], check=True, env=env)
