"""Exercise the production NavigationCoordinator with SDK and bridge boundaries stubbed."""
from pathlib import Path
import os
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
coordinator = (root / 'MotoNav/NavigationCoordinator.swift').read_text()

stubs = r'''
import Foundation
func check(_ condition: Bool, _ message: String) {
    if !condition { print("FAIL: \(message)"); exit(1) }
}
// Only the SDK singletons and the two bridges are replaced; the switch order under
// test is the production coordinator. events[] records the observed global order.
var events: [String] = []
final class NaviBridge {
    static let shared = NaviBridge()
    var navigating = false, cruising = false
    var stopCalls = 0, unbindCalls = 0
    func stopForEngineSwitch() { stopCalls += 1; events.append("drive.halt") }
    func unbindForEngineSwitch() { unbindCalls += 1; events.append("drive.unbind") }
}
final class RideBridge {
    static let shared = RideBridge()
    var navigating = false
    var stopCalls = 0, unbindCalls = 0
    func stopForEngineSwitch() { stopCalls += 1; events.append("ride.halt") }
    func unbindForEngineSwitch() { unbindCalls += 1; events.append("ride.unbind") }
}
final class WebMotorSession { static let shared = WebMotorSession(); var running = false }
final class AMapNaviDriveManager {
    static var shared: AMapNaviDriveManager?
    static var destroyResult = true
    static var destroys = 0, creates = 0
    var representatives: [AMapNaviDriveView] = []
    static func sharedInstance() -> AMapNaviDriveManager {
        if shared == nil { shared = AMapNaviDriveManager(); creates += 1; events.append("drive.create") }
        return shared!
    }
    static func destroyInstance() -> Bool {
        destroys += 1; events.append("drive.destroy")
        if destroyResult { shared = nil }
        return destroyResult
    }
    func addDataRepresentative(_ view: AMapNaviDriveView) { representatives.append(view) }
    func removeDataRepresentative(_ view: AMapNaviDriveView) { representatives.removeAll { $0 === view } }
}
final class AMapNaviRideManager {
    static var shared: AMapNaviRideManager?
    static var destroyResult = true
    static var destroys = 0, creates = 0
    var rideRepresentatives: [AMapNaviRideView] = []
    func addDataRepresentative(_ view: AMapNaviRideView) { rideRepresentatives.append(view) }
    func removeDataRepresentative(_ view: AMapNaviRideView) { rideRepresentatives.removeAll { $0 === view } }
    static func sharedInstance() -> AMapNaviRideManager {
        if shared == nil { shared = AMapNaviRideManager(); creates += 1; events.append("ride.create") }
        return shared!
    }
    static func destroyInstance() -> Bool {
        destroys += 1; events.append("ride.destroy")
        if destroyResult { shared = nil }
        return destroyResult
    }
}
final class AMapNaviDriveView {}
final class AMapNaviRideView {}
'''

tests = r'''
@main struct Tests {
    @MainActor static func main() {
        let coordinator = NavigationCoordinator.shared
        check(coordinator.active == .none, "app starts with no engine claimed")
        check(coordinator.session == 0, "session starts at zero")

        // none -> drive: create only, no teardown of anything
        check(coordinator.activate(.drive) == nil, "first drive claim succeeds")
        check(coordinator.active == .drive && AMapNaviDriveManager.creates == 1, "drive engine created on demand")
        check(coordinator.session == 1, "engine change advances the session generation")
        let before = AMapNaviDriveManager.creates
        check(coordinator.activate(.drive) == nil, "claiming the current engine is a no-op")
        check(AMapNaviDriveManager.creates == before && coordinator.session == 1, "no new instance or session for the same engine")

        // drive -> ride: fixed order halt -> unbind -> destroy -> create
        events.removeAll()
        check(coordinator.activate(.ride) == nil, "switching to ride succeeds")
        check(events == ["drive.halt", "drive.unbind", "drive.destroy", "ride.create"],
              "switch order is fixed: invalidate+stop, unbind, destroy, then create; got \(events)")
        check(NaviBridge.shared.stopCalls == 1 && NaviBridge.shared.unbindCalls == 1, "drive bridge released exactly once")
        check(AMapNaviDriveManager.destroys == 1 && AMapNaviRideManager.creates == 1, "old singleton destroyed before ride creation")
        check(coordinator.active == .ride && coordinator.session == 2, "ride now owns the engine")

        // destroy failure: never create the other SDK instance
        events.removeAll()
        AMapNaviRideManager.destroyResult = false
        let failure = coordinator.activate(.drive)
        check(failure != nil && !failure!.isEmpty, "destroy failure surfaces a user-facing reason")
        check(failure!.contains("重试"), "failure message offers retry")
        check(AMapNaviDriveManager.creates == before, "no drive instance is created while ride cannot be destroyed")
        check(coordinator.active == .ride, "ownership stays with the engine that failed to be destroyed")
        check(coordinator.lastFailure == failure, "lastFailure remembers the switch failure")
        AMapNaviRideManager.destroyResult = true

        // an active navigation on the outgoing engine blocks the switch before any teardown
        RideBridge.shared.navigating = true
        let stopCalls = RideBridge.shared.stopCalls
        let blocked = coordinator.activate(.drive)
        check(blocked != nil, "switch is refused while ride navigation is running")
        check(RideBridge.shared.stopCalls == stopCalls, "no teardown hooks run for a refused switch")
        check(coordinator.active == .ride, "a refused switch keeps the current owner")
        RideBridge.shared.navigating = false

        // deactivateAll (key rebuild): destroy current, create nothing
        events.removeAll()
        check(coordinator.deactivateAll() == nil, "deactivate succeeds when ride is idle")
        check(events == ["ride.halt", "ride.unbind", "ride.destroy"], "deactivate destroys without creating; got \(events)")
        check(coordinator.active == .none, "back to no engine after deactivation")
        check(AMapNaviRideManager.creates == 1, "deactivation must not eagerly create a new engine")

        // navigationActive covers drive, official ride and independent guidance
        check(!coordinator.navigationActive, "idle means no navigation")
        NaviBridge.shared.navigating = true
        check(coordinator.navigationActive, "drive navigation counts")
        NaviBridge.shared.navigating = false
        RideBridge.shared.navigating = true
        check(coordinator.navigationActive, "official ride navigation counts")
        RideBridge.shared.navigating = false
        WebMotorSession.shared.running = true
        check(coordinator.navigationActive, "independent guidance counts")
        WebMotorSession.shared.running = false

        // owner-gated accessors: late callbacks / map teardown must not resurrect a destroyed singleton
        coordinator.activate(.drive)
        check(coordinator.driveManagerIfActive() != nil && coordinator.rideManagerIfActive() == nil, "only the owner engine is handed out")
        let view = AMapNaviDriveView()
        coordinator.attachDriveMap(view)
        check(AMapNaviDriveManager.shared!.representatives.count == 1, "map attaches while drive owns the engine")
        check(coordinator.activate(.ride) == nil, "switch to ride for the teardown case")
        let driveCreates = AMapNaviDriveManager.creates
        events.removeAll()
        coordinator.detachDriveMap(view)
        check(AMapNaviDriveManager.shared == nil, "map teardown must not recreate the destroyed drive singleton")
        check(AMapNaviDriveManager.creates == driveCreates && events.isEmpty, "detach after a switch touches no SDK at all")
        coordinator.attachDriveMap(view)
        check(AMapNaviRideManager.shared != nil && AMapNaviDriveManager.creates == driveCreates, "attach is also owner-gated")
        // 骑行地图（AMapNaviRideView）走同一套属主门禁：骑行属主才绑定，切换/无属主不得重建单例
        let rideMap = AMapNaviRideView()
        coordinator.attachRideMap(rideMap)
        check(AMapNaviRideManager.shared!.rideRepresentatives.count == 1, "ride map attaches while ride owns the engine")
        let rideEvents = events.count
        coordinator.attachRideMap(rideMap)
        check(events.count == rideEvents, "repeat ride map attach triggers no engine lifecycle events")
        check(coordinator.activate(.none) == nil, "release the ride engine for the teardown case")
        let rideCreates = AMapNaviRideManager.creates
        events.removeAll()
        coordinator.detachRideMap(rideMap)
        check(AMapNaviRideManager.shared == nil && AMapNaviRideManager.creates == rideCreates && events.isEmpty,
              "ride map teardown must not recreate the destroyed ride singleton")
        print("PASS navigation coordinator: ownership, fixed switch order, destroy failure, unified navigation state")
    }
}
'''

with tempfile.TemporaryDirectory(prefix='motonav-coordinator-') as tmp:
    swift = Path(tmp) / 'main.swift'
    swift.write_text(stubs + coordinator + tests)
    env = dict(os.environ, CLANG_MODULE_CACHE_PATH=str(Path(tmp) / 'cache'), SWIFT_MODULECACHE_PATH=str(Path(tmp) / 'cache'))
    subprocess.run(['swiftc', '-parse-as-library', str(swift), '-o', str(Path(tmp) / 'check')], check=True, env=env)
    subprocess.run([str(Path(tmp) / 'check')], check=True, env=env)
