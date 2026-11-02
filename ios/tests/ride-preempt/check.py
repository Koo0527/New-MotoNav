"""Independent takeover of a planned official ride: real WebMotorSession.start, the cruise notice from
NaviBridge.startCruise (surfaceRidePlanTakeoverNotice), and the shared takeover policy (macOS)."""
from pathlib import Path
import os
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
s = (root / 'MotoNav/WebMotor.swift').read_text()
# Independent takeover policy + the production independent session class.
session = s[s.index('/// Independent takeover notices'):s.index('\nfinal class MotorBrowser')]
# Production planning-input types and the arrival gate used by the session.
core = s[s.index('struct MotorPoint'):s.index('enum MotorRoutes')]
# Cruise takeover notice: the real property + method NaviBridge.startCruise calls before attach()
# (attach tears the ride engine down and wipes RideBridge's planned-but-not-navigating plan).
n = (root / 'MotoNav/NaviBridge.swift').read_text()
cruise = n[n.index('    /// 官方骑行规划被巡航抢占时的短暂提示'):n.index('    /// 开始巡航（不设目的地）')]

stubs = r'''
import Foundation
import CoreLocation
func check(_ condition: Bool, _ message: String) {
    if !condition { print("FAIL: \(message)"); exit(1) }
}
func wait(_ seconds: Double) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }
enum AmapShare { struct Fail: Error { let message: String; init(_ m: String) { message = m } } }
enum MapGeo { static func wgsToGcj(_ lat: Double, _ lng: Double) -> (lat: Double, lng: Double) { (lat, lng) } }
final class UIApplication { static let shared = UIApplication(); var isIdleTimerDisabled = false }
final class MapFeeder {
    static let shared = MapFeeder()
    var naviStarts = 0, naviEnds = 0
    func onNaviStart() { naviStarts += 1 }
    func onNaviEnd() { naviEnds += 1 }
    func prepareRoute(key: String, coords: [(lat: Double, lng: Double)]) {}
    func onRoute(key: String, coords: [(lat: Double, lng: Double)], lights: [(lat: Double, lng: Double)]) -> Bool { true }
    func onLocation(lat: Double, lng: Double, bearing: Double, kmh: Int) {}
}
final class BleLink {
    static let shared = BleLink()
    var sent: [String] = []
    func send(_ msg: String) { sent.append(msg) }
    func sendImage(slot: Int, w: Int, h: Int, data: Data) {}
}
final class Speech {
    static let shared = Speech()
    var spoken: [String] = []
    func speak(_ text: String) { spoken.append(text) }
    func stopNow() {}
}
final class Settings { static let shared = Settings(); func resetTunnel() {} }
final class RideRecorder {
    static let shared = RideRecorder()
    var started: [String] = [], finished = 0
    func start(_ mode: String) { started.append(mode) }
    func finish() { finished += 1 }
}
final class LocationService { static let shared = LocationService(); var preciseCalls: [Bool] = []; func setPrecise(_ on: Bool) { preciseCalls.append(on) } }
final class WebRouteMetadata {
    static let shared = WebRouteMetadata()
    var loads = 0
    func load(_ route: MotorRoute) { loads += 1 }
    func stop() {}
    func push(route: MotorRoute, progress: Double, fresh: Bool, speed: Int) {}
}
final class RideBridge {
    static let shared = RideBridge()
    var navigating = false
    var routeReady = false
    var stopCalls = 0
    func stop() { stopCalls += 1 }
}
final class NaviBridge {
    static let shared = NaviBridge()
    var navigating = false, cruising = false
    var stopCalls = 0
    func stop() { stopCalls += 1 }
    func stopCruise() {}
    static func distText(_ m: Int) -> String { m >= 1000 ? String(format: "%.1f 公里", Double(m) / 1000) : "\(m) 米" }
    static func distM(_ lat1: Double, _ lng1: Double, _ lat2: Double, _ lng2: Double) -> Double {
        let k = Double.pi / 180
        let x = (lng2 - lng1) * k * cos((lat1 + lat2) / 2 * k)
        let y = (lat2 - lat1) * k
        return (x * x + y * y).squareRoot() * 6_371_000.0
    }
}
final class NavigationCoordinator {
    static let shared = NavigationCoordinator()
    var navigationActive: Bool { NaviBridge.shared.navigating || RideBridge.shared.navigating || WebMotorSession.shared.running }
}
enum MotorRoutes { static func load(_ request: MotorRequest) async throws -> [MotorRoute] { [] } }
struct Img { let w: Int; let h: Int; let data: Data }
enum TextImage {
    static func render(_ text: String, maxW: Int, size: CGFloat, minSize: CGFloat = 16) -> Img? {
        Img(w: 1, h: 1, data: Data())
    }
}
'''

# Carries the real cruise notice members extracted verbatim from NaviBridge.swift so the
# harness executes the production cruise path (NaviBridge itself needs the AMap SDK).
cruise_harness = '''
/// 承载从 NaviBridge.swift 逐字抽取的巡航提示代码（属性 + startCruise 调用的方法）
final class CruiseNavi: ObservableObject {
    static let shared = CruiseNavi()
''' + cruise + '''}
'''

tests = r'''
@main struct Tests {
    @MainActor static func main() {
        // 决策规则（真实生产函数）：只有“已规划未导航”的官方骑行才提示
        check(IndependentTakeoverPolicy.ridePlanNotice(officialRidePlanned: true, rideNavigating: false) != nil,
              "a planned-but-not-started official ride earns a notice")
        check(IndependentTakeoverPolicy.ridePlanNotice(officialRidePlanned: false, rideNavigating: false) == nil,
              "no ride plan means no notice")
        check(IndependentTakeoverPolicy.ridePlanNotice(officialRidePlanned: true, rideNavigating: true) == nil,
              "an active ride navigation earns no notice (the independent start is blocked anyway)")

        // 真实 start()：官方骑行规划被独立导航启动抢占 → 不阻断接管 + 显式提示 + 释放骑行规划
        let session = WebMotorSession.shared
        let route = MotorRoute(request: MotorRequest(start: MotorPoint(lat: 31, lng: 121),
                                                     end: MotorPoint(lat: 31.01, lng: 121.01), bicycle: true),
                               points: [MotorPoint(lat: 31, lng: 121), MotorPoint(lat: 31.005, lng: 121.005), MotorPoint(lat: 31.01, lng: 121.01)],
                               steps: [MotorStep(instruction: "沿测试路骑行", road: "测试路", action: "直行", end: 2)],
                               seconds: 600)
        RideBridge.shared.routeReady = true
        session.start(route, simulate: true)
        check(session.running, "the takeover itself is never blocked")
        check(RideBridge.shared.stopCalls == 1, "the reclaimed official ride plan is released")
        check(session.ridePlanNotice.contains("官方骑行"), "the preemption notice is surfaced in-app")
        wait(4.3)
        check(session.ridePlanNotice.isEmpty, "the notice is brief and auto-clears")
        session.stop(sendCancel: false)

        // 官方骑行没有已规划路线时不提示
        RideBridge.shared.routeReady = false
        let stops = RideBridge.shared.stopCalls
        session.start(route, simulate: true)
        check(session.running && session.ridePlanNotice.isEmpty, "no notice when the ride engine has no plan")
        check(RideBridge.shared.stopCalls == stops + 1, "the idle ride bridge is still stopped for engine ownership")
        session.stop(sendCancel: false)
        check(!session.running, "the independent session ends cleanly")

        // 巡航路径（真实 NaviBridge.surfaceRidePlanTakeoverNotice + 同一决策函数）：同一机制显示提示
        RideBridge.shared.navigating = false
        RideBridge.shared.routeReady = true
        check(IndependentTakeoverPolicy.ridePlanNotice(officialRidePlanned: true, rideNavigating: false, takenOverBy: "巡航") == "已规划的官方骑行路线被本次巡航取代",
              "the cruise takeover reuses the same notice wording source")
        check(IndependentTakeoverPolicy.ridePlanNotice(officialRidePlanned: false, rideNavigating: false, takenOverBy: "巡航") == nil,
              "no ride plan means no cruise notice")
        check(IndependentTakeoverPolicy.ridePlanNotice(officialRidePlanned: true, rideNavigating: true, takenOverBy: "巡航") == nil,
              "an active ride navigation earns no cruise notice (startCruise is blocked anyway)")
        CruiseNavi.shared.surfaceRidePlanTakeoverNotice()
        check(CruiseNavi.shared.ridePlanNotice.contains("官方骑行"), "the cruise takeover surfaces the notice in-app")
        check(CruiseNavi.shared.ridePlanNotice.contains("巡航"), "the cruise notice names the cruise takeover")
        wait(4.3)
        check(CruiseNavi.shared.ridePlanNotice.isEmpty, "the cruise notice is brief and auto-clears")
        RideBridge.shared.routeReady = false
        CruiseNavi.shared.surfaceRidePlanTakeoverNotice()
        check(CruiseNavi.shared.ridePlanNotice.isEmpty, "no cruise notice when the ride engine has no plan")
        print("PASS ride preemption: explicit notice, unblocked takeover, auto-clear (independent start + cruise)")
    }
}
'''

with tempfile.TemporaryDirectory(prefix='motonav-ride-preempt-') as tmp:
    swift = Path(tmp) / 'main.swift'
    speeds = (root / 'MotoNav/NavigationSpeed.swift').read_text()
    swift.write_text('enum MapPipelineTrace {static func event(_ name:String,_ fields:[String:Any]=[:]){}}\n' + stubs + speeds + '\n' + core + (root / 'MotoNav/RouteGeometry.swift').read_text() + '\n'
                     + (root / 'MotoNav/MotorRouteTracker.swift').read_text() + '\n'
                     + (root / 'MotoNav/MotorReroutePolicy.swift').read_text() + '\n' + session + cruise_harness + tests)
    env = dict(os.environ, CLANG_MODULE_CACHE_PATH=str(Path(tmp) / 'cache'), SWIFT_MODULECACHE_PATH=str(Path(tmp) / 'cache'))
    subprocess.run(['swiftc', '-parse-as-library', str(swift), '-o', str(Path(tmp) / 'check')], check=True, env=env)
    subprocess.run([str(Path(tmp) / 'check')], check=True, env=env)
