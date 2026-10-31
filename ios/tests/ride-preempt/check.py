"""Independent takeover of a planned official ride: real WebMotorSession.start + takeover policy (macOS)."""
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

stubs = r'''
import Foundation
import CoreLocation
func check(_ condition: Bool, _ message: String) {
    if !condition { print("FAIL: \(message)"); exit(1) }
}
func wait(_ seconds: Double) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }
enum AmapShare { struct Fail: Error { let message: String; init(_ m: String) { message = m } } }
enum NavigationSpeed {
    static let values = [60, 100, 120, 150]
    static func next(_ value: Int) -> Int { guard let i = values.firstIndex(of: value) else { return values[0] }; return values[(i + 1) % values.count] }
}
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
        print("PASS ride preemption: explicit notice, unblocked takeover, auto-clear")
    }
}
'''

with tempfile.TemporaryDirectory(prefix='motonav-ride-preempt-') as tmp:
    swift = Path(tmp) / 'main.swift'
    swift.write_text(stubs + core + (root / 'MotoNav/RouteGeometry.swift').read_text() + '\n'
                     + (root / 'MotoNav/MotorRouteTracker.swift').read_text() + '\n' + session + tests)
    env = dict(os.environ, CLANG_MODULE_CACHE_PATH=str(Path(tmp) / 'cache'), SWIFT_MODULE_CACHE_PATH=str(Path(tmp) / 'cache'))
    subprocess.run(['swiftc', '-parse-as-library', str(swift), '-o', str(Path(tmp) / 'check')], check=True, env=env)
    subprocess.run([str(Path(tmp) / 'check')], check=True, env=env)
