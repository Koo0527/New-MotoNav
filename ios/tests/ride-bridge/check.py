"""Exercise the production RideBridge with the ride SDK boundary stubbed (macOS, no device)."""
from pathlib import Path
import os
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
bridge = (root / 'MotoNav/RideBridge.swift').read_text()
arrival = (root / 'MotoNav/ArrivalPolicy.swift').read_text()

stubs = r'''
import Foundation
import CoreLocation
import ObjectiveC
func check(_ condition: Bool, _ message: String) {
    if !condition { print("FAIL: \(message)"); exit(1) }
}
func wait(_ seconds: Double) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }
struct MotorPoint { let lat: Double; let lng: Double; var name = "" }
enum MotorRequest { static func valid(_ lat: Double, _ lng: Double) -> Bool { lat.isFinite && lng.isFinite && abs(lat) <= 90 && abs(lng) <= 180 } }
enum NavigationSpeed {
    static let values = [60, 100, 120]
    static func next(_ value: Int) -> Int { guard let i = values.firstIndex(of: value) else { return values[0] }; return values[(i + 1) % values.count] }
}
final class Speech {
    static let shared = Speech()
    var spoken: [String] = []
    func speak(_ text: String) { spoken.append(text) }
}
final class LocationService {
    static let shared = LocationService()
    var preciseCalls: [Bool] = []
    func setPrecise(_ on: Bool) { preciseCalls.append(on) }
}
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
    var routeTime = 0, routeLength = 0
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
enum AMapNaviIconType: Int { case left = 2, straight = 9 }
final class AMapNaviInfo: NSObject {
    var iconType: AMapNaviIconType = .straight
    var segmentRemainDistance = 0, routeRemainDistance = 0, routeRemainTime = 0
    var currentRoadName: String?, nextRoadName: String?
}
final class AMapNaviLocation: NSObject { var speed: Int = 0 }
final class AMapNaviRideManager: NSObject {
    weak var delegate: AMapNaviRideManagerDelegate?
    var representatives: [AMapNaviRideDataRepresentable] = []
    var isUseInternalTTS: Bool?
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
        bridge.preferredSimulationSpeed = 100
        bridge.start(emulate: true)
        check(bridge.navigating && bridge.emulating, "emulator navigation is armed")
        check(coordinator.rideManager.startedGroups.count == 1, "navigation starts with the saved route group")
        check(coordinator.rideManager.isUseInternalTTS == false, "SDK built-in announcements stay disabled")
        check(coordinator.rideManager.emulatorSpeeds.last == 100, "preferred simulation speed is applied (clamped to SDK range)")
        check(LocationService.shared.preciseCalls.isEmpty, "simulation does not require precise location")

        // 导航信息 → 界面状态
        let info = AMapNaviInfo()
        info.iconType = .left; info.segmentRemainDistance = 120; info.routeRemainDistance = 1500
        info.routeRemainTime = 600; info.currentRoadName = "测试路"; info.nextRoadName = "林荫道"
        bridge.testNaviInfo(info)
        check(bridge.uiDir == "L" && bridge.uiDist == 120, "turn info reaches the UI state")
        check(bridge.uiRoad.contains("林荫道"), "road name follows the drive text rules")
        check(bridge.uiRemainM == 1500, "remaining distance is published")

        // 模拟导航：暂停 / 继续、调速
        bridge.toggleEmuPause()
        check(bridge.emuPaused && coordinator.rideManager.pauseCalls == 1, "pause reaches the SDK")
        bridge.toggleEmuPause()
        check(!bridge.emuPaused && coordinator.rideManager.resumeCalls == 1, "resume reaches the SDK")
        let speedBefore = bridge.emuSpeed
        bridge.cycleEmuSpeed()
        check(bridge.emuSpeed == NavigationSpeed.next(speedBefore), "speed cycles within the SDK range")

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
        bridge.stop()
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

        print("PASS ride bridge: planning, generations, timeout, error classes, selection, simulation, reroute, arrival and teardown")
    }
}
'''

# Test-only hooks so the harness can drive the private @objc relay handlers directly.
bridge = bridge.replace('    fileprivate func onRouteCalculateFailure(', '    func testRouteCalculateFailure(_ error: NSError?) { onRouteCalculateFailure(error) }\n    fileprivate func onRouteCalculateFailure(')
bridge = bridge.replace('    fileprivate func onSound(', '    func testSound(_ text: String?) { onSound(text) }\n    fileprivate func onSound(')
bridge = bridge.replace('    fileprivate func onArrived()', '    func testArrived() { onArrived() }\n    fileprivate func onArrived()')
bridge = bridge.replace('    fileprivate func onEmulatorEnd()', '    func testEmulatorEnd() { onEmulatorEnd() }\n    fileprivate func onEmulatorEnd()')
bridge = bridge.replace('    fileprivate func onNaviInfo(', '    func testNaviInfo(_ n: AMapNaviInfo?) { onNaviInfo(n) }\n    fileprivate func onNaviInfo(')

with tempfile.TemporaryDirectory(prefix='motonav-ride-bridge-') as tmp:
    swift = Path(tmp) / 'main.swift'
    swift.write_text(stubs + arrival + bridge + tests)
    env = dict(os.environ, CLANG_MODULE_CACHE_PATH=str(Path(tmp) / 'cache'), SWIFT_MODULE_CACHE_PATH=str(Path(tmp) / 'cache'))
    subprocess.run(['swiftc', '-parse-as-library', str(swift), '-o', str(Path(tmp) / 'check')], check=True, env=env)
    subprocess.run([str(Path(tmp) / 'check')], check=True, env=env)
