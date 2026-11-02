"""Exercise the production planner with SDK and network boundaries replaced."""
from pathlib import Path
import subprocess
import os
import tempfile

root = Path(__file__).resolve().parents[2]
source = (root / 'MotoNav/IndependentRouteView.swift').read_text()
model = source[source.index('enum TravelMode:'):source.index('struct MotorLoginView:')]
stubs = r'''
import Foundation
import Combine
import CoreLocation
struct MotorPoint { let lat:Double; let lng:Double; var name="" }
struct MotorRequest { let start:MotorPoint; let end:MotorPoint; let vias:[MotorPoint]; let bicycle:Bool }
struct MotorRoute { let request:MotorRequest }
enum AmapShare { struct Route { let kind:String; let startLat:Double; let startLng:Double; let startName:String; let endLat:Double; let endLng:Double; let endName:String } }
enum MotorRoutes {
    static var pending:[CheckedContinuation<[MotorRoute],Error>]=[]
    static var requests:[MotorRequest]=[]
    static func load(_ request:MotorRequest) async throws -> [MotorRoute] {
        requests.append(request)
        return try await withCheckedThrowingContinuation { pending.append($0) }
    }
    static func fromShare(_ r:AmapShare.Route)->MotorRoute { MotorRoute(request:MotorRequest(start:MotorPoint(lat:r.startLat,lng:r.startLng),end:MotorPoint(lat:r.endLat,lng:r.endLng),vias:[],bicycle:true)) }
}
struct SavedMotorPlan { let valid:Bool; let request:MotorRequest }
final class MotorPlanHistory {
    static let shared=MotorPlanHistory()
    var saved:[MotorRoute]=[]
    func save(_ route:MotorRoute){saved.append(route)}
}
final class Settings { static let shared=Settings(); var keysMissing=false }
final class WebMotorSession { static let shared=WebMotorSession(); var running=false }
final class NaviBridge {
    struct Via { let name:String; let lat:Double; let lng:Double }
    static let shared=NaviBridge(); var navigating=false; var cruising=false; var routeReady=false; var clears=0; var plans=0; var origin:MotorPoint?; var vias:[Via]=[]; var imported=false
    func stopCruise(){cruising=false}
    func clearPlan(){clears += 1;routeReady=false}
    func plan(toLat:Double,lng:Double,share:AmapShare.Route?=nil,origin:MotorPoint?=nil,viaPoints:[Via]=[]){plans += 1;self.origin=origin;vias=viaPoints;imported=share != nil}
}
final class LocationService { static let shared=LocationService(); var location:CLLocation?; func start(){} }
final class RideBridge {
    static let shared=RideBridge()
    var navigating=false; var plans=0; var clears=0; var origin:MotorPoint?; var endName=""; var historyEligible=true
    func plan(toLat:Double,lng:Double,origin:MotorPoint?,endName:String="",historyEligible:Bool=true){
        plans += 1;self.origin=origin;self.endName=endName;self.historyEligible=historyEligible
    }
    func clearPlan(){clears += 1}
}
final class NavigationCoordinator {
    static let shared=NavigationCoordinator()
    var navigationActive:Bool { NaviBridge.shared.navigating || RideBridge.shared.navigating || WebMotorSession.shared.running }
}
enum MapGeo { static func wgsToGcj(_ lat:Double,_ lng:Double)->(lat:Double,lng:Double){(lat,lng)} }
'''
tests = r'''
@main struct Tests {
    @MainActor static func settle() async { for _ in 0..<20 { await Task.yield() } }
    @MainActor static func main() async {
        UserDefaults.standard.removeObject(forKey:"ride_engine_official") // keep the run hermetic
        let p=RoutePlanner()
        assert(p.officialRide,"ordinary bicycle routes default to the official ride engine (Task 2)")
        p.officialRide=false // the stale-result phase below exercises the compatible web planner
        p.start=MotorPoint(lat:31,lng:121,name:"origin")
        p.end=MotorPoint(lat:32,lng:122,name:"first")
        p.mode = .motorcycle
        p.plan();await settle()
        assert(MotorRoutes.pending.count==1)
        p.mode = .bicycle
        let old=MotorRoutes.requests[0]
        MotorRoutes.pending.removeFirst().resume(returning:[MotorRoute(request:old)])
        await settle()
        assert(p.routes.isEmpty && !p.busy,"stale callbacks must not publish after a mode change")
        p.vias=[MotorPoint(lat:31.5,lng:121.5,name:"via")]
        p.plan();await settle()
        assert(MotorRoutes.requests.count==1 && !p.message.isEmpty,"bicycle vias must be rejected, not dropped")
        assert(p.vias.count==1,"unsupported vias remain removable")
        p.vias=[];p.plan();await settle()
        p.end=MotorPoint(lat:33,lng:123,name:"second")
        MotorRoutes.pending.removeFirst().resume(returning:[MotorRoute(request:old)])
        await settle();assert(p.routes.isEmpty,"destination changes discard stale results")
        let restored=SavedMotorPlan(valid:true,request:MotorRequest(start:MotorPoint(lat:31,lng:121,name:"history origin"),end:MotorPoint(lat:32,lng:122,name:"history end"),vias:[MotorPoint(lat:31.5,lng:121.5,name:"fuel")],bicycle:false))
        p.load(restored)
        assert(p.mode == .motorcycle && p.start?.name == "history origin" && p.vias.count==1 && p.routes.isEmpty && !p.busy,"history restores inputs and invalidates geometry")
        p.vias=[]
        p.mode = .driving;NaviBridge.shared.cruising=true;p.plan()
        assert(!NaviBridge.shared.cruising,"planning replaces cruise deliberately")
        assert(p.drivingPlanned && NaviBridge.shared.plans==1)
        p.start=nil
        assert(!p.drivingPlanned && !NaviBridge.shared.routeReady)
        p.start=MotorPoint(lat:31,lng:121,name:"origin")
        p.mode = .motorcycle
        p.plan();await settle()
        p.mode = .bicycle;p.plan();await settle()
        let current=MotorRoutes.requests.last!
        MotorRoutes.pending.removeLast().resume(returning:[MotorRoute(request:current)])
        await settle();assert(p.routes.count==1)
        assert(!MotorPlanHistory.shared.saved.isEmpty,"successful plans are saved to history")
        MotorRoutes.pending.removeFirst().resume(throwing:NSError(domain:"old",code:1))
        await settle();assert(p.routes.count==1 && p.message.contains("已找到"),"old errors cannot replace a current result")
        let share=AmapShare.Route(kind:"摩托车",startLat:31,startLng:121,startName:"shared origin",endLat:32,endLng:122,endName:"shared end")
        p.importShare(share)
        assert(p.mode == .motorcycle && p.usesDriving && NaviBridge.shared.imported && NaviBridge.shared.origin == nil,"motorcycle imports use original share in driving SDK")
        p.mode = .bicycle
        assert(p.share == nil && !p.drivingPlanned && p.start?.name == "shared origin","mode changes discard share geometry while retaining origin")
        let bicycle=AmapShare.Route(kind:"自行车",startLat:31,startLng:121,startName:"cycle origin",endLat:32,endLng:122,endName:"cycle end")
        p.importShare(bicycle)
        assert(p.mode == .bicycle && p.routes.count==1 && !p.usesDriving,"bicycle share preloads independent route")
        p.end=MotorPoint(lat:34,lng:124,name:"changed import")
        assert(p.routes.isEmpty && p.share == nil)
        NaviBridge.shared.navigating=true
        let clears=NaviBridge.shared.clears
        let plans=NaviBridge.shared.plans
        p.invalidate();p.plan()
        assert(NaviBridge.shared.clears==clears,"invalidating must not clear an active navigation")
        assert(NaviBridge.shared.plans==plans,"planning must not create concurrent sessions")
        NaviBridge.shared.navigating=false
        // 官方骑行引擎：自行车模式下经 RideBridge 走 SDK 算路（Task 1 最小链路）
        let rideClears=RideBridge.shared.clears
        p.invalidate()
        assert(RideBridge.shared.clears==rideClears+1,"invalidating also clears the official ride plan")
        p.officialRide=true
        let webRequests=MotorRoutes.requests.count, drivePlans=NaviBridge.shared.plans
        p.plan();await settle()
        assert(p.ridePlanned && RideBridge.shared.plans==1 && RideBridge.shared.origin?.lat==31,"official ride bicycle plans go to RideBridge with the manual origin")
        assert(MotorRoutes.requests.count==webRequests && NaviBridge.shared.plans==drivePlans,"official ride bypasses the web planner and the driving SDK")
        RideBridge.shared.navigating=true
        let ridePlans=RideBridge.shared.plans
        p.invalidate();p.plan()
        assert(RideBridge.shared.plans==ridePlans,"an official ride navigation blocks replanning")
        assert(p.message.contains("导航"),"the block reason is surfaced")
        RideBridge.shared.navigating=false
        p.end=MotorPoint(lat:35,lng:125,name:"moved")
        assert(!p.ridePlanned,"geometry changes invalidate the official ride plan")
        p.officialRide=false
        UserDefaults.standard.removeObject(forKey:"ride_engine_official")

        // ---- Task 2：后端标识与分流默认 ----
        let fresh=RoutePlanner()
        assert(fresh.officialRide,"a fresh install keeps the official ride engine as the bicycle default")
        assert(fresh.shareRideOfficial == false,"official re-plans of a share are always explicit")
        // 后端标识：出行方式与实际引擎分别记录
        p.end=MotorPoint(lat:32,lng:122,name:"backend end")
        p.mode = .driving
        assert(p.backend == .driveSDK,"driving runs on the driving SDK")
        p.mode = .motorcycle
        assert(p.backend == .independent,"ordinary motorcycle routes stay on the web backend")
        p.importShare(AmapShare.Route(kind:"摩托车",startLat:31,startLng:121,startName:"s",endLat:32,endLng:122,endName:"e"))
        assert(p.backend == .driveSDK,"motorcycle share uses the driving SDK while the travel mode is motorcycle")
        p.importShare(AmapShare.Route(kind:"自行车",startLat:31,startLng:121,startName:"cs",endLat:32,endLng:122,endName:"ce"))
        assert(p.backend == .independent && !p.usesOfficialRide,"bicycle share keeps the original line on the independent backend by default")
        // 显式“用官方引擎重新规划”：走 rideSDK，起点交给 SDK 当前定位，不记历史
        p.shareRideOfficial=true
        let shareRidePlans=RideBridge.shared.plans
        p.plan();await settle()
        assert(RideBridge.shared.plans==shareRidePlans+1,"the explicit re-plan routes to RideBridge")
        assert(RideBridge.shared.origin == nil,"share re-plans let the SDK start from the current position")
        assert(RideBridge.shared.historyEligible == false,"share re-plans never enter history")
        assert(p.usesOfficialRide && p.backend == .rideSDK,"the share re-plan runs on the ride SDK")
        // 沿用原轨迹：回到独立预览，并清掉官方规划
        let shareClears=RideBridge.shared.clears
        p.restoreShareLine()
        assert(p.routes.count==1 && !p.shareRideOfficial,"restoring returns to the original-line preview")
        assert(RideBridge.shared.clears==shareClears+1 && p.backend == .independent,"restoring clears the ride plan and returns to the independent backend")
        // 输入变化重置官方重划和分享
        p.shareRideOfficial=true
        p.end=MotorPoint(lat:36,lng:126,name:"moved again")
        assert(p.shareRideOfficial == false && p.share == nil,"input changes reset the share re-plan and drop the share")
        // 默认官方引擎下普通自行车进 RideBridge；显式关闭才回到网页（兼容引擎是用户的选择，不静默切换）
        p.end=MotorPoint(lat:32,lng:122,name:"final")
        p.officialRide=true
        let defaultRidePlans=RideBridge.shared.plans, defaultWebRequests=MotorRoutes.requests.count
        p.plan();await settle()
        assert(RideBridge.shared.plans==defaultRidePlans+1 && MotorRoutes.requests.count==defaultWebRequests,"a bicycle plan with the engine on goes to RideBridge")
        p.officialRide=false
        p.plan();await settle()
        assert(MotorRoutes.requests.count==defaultWebRequests+1 && RideBridge.shared.plans==defaultRidePlans+1,"turning the engine off explicitly returns to the compatible web planner")
        UserDefaults.standard.removeObject(forKey:"ride_engine_official")
        print("PASS: unified planner lifecycle")
    }
}
'''
with tempfile.TemporaryDirectory(prefix='motonav-planner-') as tmp:
    swift = Path(tmp) / 'main.swift'
    swift.write_text(stubs + (root / 'MotoNav/NavigationSpeed.swift').read_text() + '\n' + model + tests)
    env=dict(os.environ, CLANG_MODULE_CACHE_PATH=str(Path(tmp)/'cache'), SWIFT_MODULECACHE_PATH=str(Path(tmp)/'cache'))
    subprocess.run(['swiftc', '-parse-as-library', str(swift), '-o', str(Path(tmp)/'check')], check=True, env=env)
    subprocess.run([str(Path(tmp)/'check')], check=True, env=env)

# Exercise the production SDK adapter method separately; only attach/replan and
# clearPlan (external lifecycle boundaries) are substituted with observations.
bridge = (root / 'MotoNav/NaviBridge.swift').read_text()
plan = bridge[bridge.index('    func plan(toLat '):bridge.index('    /// 加一个途经点')]
motor = (root / 'MotoNav/WebMotor.swift').read_text()
valid = next(line for line in motor.splitlines() if 'static func valid(_ lat:' in line)
adapter = r'''
import Foundation
struct MotorPoint { let lat:Double; let lng:Double }
enum MotorRequest {
''' + valid + r'''
}
enum AmapShare { struct Route { let id:Int } }
final class WebMotorSession { static let shared=WebMotorSession(); var running=false }
final class RideBridge { static let shared=RideBridge(); var navigating=false }
final class NavigationCoordinator {
    static let shared=NavigationCoordinator()
    var navigationActive:Bool { bridge.navigating || RideBridge.shared.navigating || WebMotorSession.shared.running }
}
final class NaviBridge {
    struct Via { let name:String; let lat:Double; let lng:Double }
    var navigating=false, cruising=false, planFailed=false, calculating=false
    var info="", destLat=Double.nan, destLng=Double.nan
    var planOrigin:(Double,Double)?, shareRoute:AmapShare.Route?, vias:[Via]=[]
    var attachments=0, replans=0, clears=0
    var onReplan:(()->Void)?
    @discardableResult func attach()->Bool{attachments += 1;return true}
    func replan(){replans += 1;onReplan?()}
    func clearPlan(){clears += 1;destLat = .nan;destLng = .nan;planOrigin=nil;shareRoute=nil;vias=[]}
''' + plan + r'''
}
let bridge=NaviBridge()
let origin=MotorPoint(lat:31,lng:121)
let via=NaviBridge.Via(name:"fuel",lat:31.5,lng:121.5)
for count in 0...3 {
    let expected=Array(repeating:via,count:count)
    bridge.onReplan={
        assert(bridge.destLat==32 && bridge.destLng==122)
        assert(bridge.planOrigin?.0==31 && bridge.planOrigin?.1==121)
        assert(bridge.vias.count==count && bridge.vias.allSatisfy{$0.name=="fuel" && $0.lat==31.5 && $0.lng==121.5})
        assert(bridge.shareRoute == nil,"manual inputs atomically replace imported share")
    }
    let before=bridge.replans
    bridge.plan(toLat:32,lng:122,origin:origin,viaPoints:expected)
    assert(bridge.replans==before+1 && bridge.attachments==bridge.replans,"one complete input change causes exactly one replan")
}
bridge.onReplan={assert(bridge.planOrigin == nil && bridge.vias.isEmpty && bridge.shareRoute == nil)}
bridge.plan(toLat:33,lng:123)
assert(bridge.replans==5,"backward-compatible default replaces previous explicit origin/vias")
let share=AmapShare.Route(id:42)
bridge.onReplan={assert(bridge.shareRoute?.id==42 && bridge.planOrigin == nil && bridge.vias.isEmpty)}
bridge.plan(toLat:34,lng:124,share:share,origin:nil)
assert(bridge.replans==6,"imported geometry reaches the SDK adapter unchanged")
bridge.onReplan=nil
func reject(_ call:()->Void) {
    let before=bridge.replans, attached=bridge.attachments, clears=bridge.clears
    bridge.planFailed=false
    call()
    assert(bridge.replans==before && bridge.attachments==attached,"invalid input cannot reach routing")
    assert(bridge.planFailed && !bridge.info.isEmpty && bridge.clears==clears+1)
    assert(bridge.destLat.isNaN && bridge.planOrigin == nil && bridge.vias.isEmpty,"invalid input clears old startable plans")
}
for coordinate in [Double.nan,Double.infinity,-Double.infinity,91,-91] {
    reject {bridge.plan(toLat:coordinate,lng:122)}
}
for longitude in [Double.nan,Double.infinity,181,-181] {
    reject {bridge.plan(toLat:32,lng:longitude)}
}
reject {bridge.plan(toLat:32,lng:122,origin:MotorPoint(lat:91,lng:121))}
reject {bridge.plan(toLat:32,lng:122,viaPoints:[NaviBridge.Via(name:"bad",lat:31,lng:.nan)])}
reject {bridge.plan(toLat:32,lng:122,viaPoints:Array(repeating:via,count:4))}
reject {bridge.plan(toLat:32,lng:122,share:share,viaPoints:[via])}
bridge.plan(toLat:32,lng:122,origin:origin,viaPoints:[via])
let before=bridge.replans, attached=bridge.attachments, clears=bridge.clears
for independent in [false,true] {
    bridge.navigating = !independent
    WebMotorSession.shared.running=independent
    bridge.plan(toLat:40,lng:130,share:share)
    bridge.plan(toLat:.nan,lng:130)
    assert(bridge.replans==before && bridge.attachments==attached && bridge.clears==clears)
    assert(bridge.destLat==32 && bridge.destLng==122 && bridge.planOrigin?.0==31 && bridge.vias.count==1 && bridge.shareRoute == nil,"active navigation owns its existing plan")
}
print("PASS: production NaviBridge planning adapter")
'''
with tempfile.TemporaryDirectory(prefix='motonav-plan-adapter-') as tmp:
    swift = Path(tmp) / 'main.swift'
    swift.write_text(adapter)
    env=dict(os.environ, CLANG_MODULE_CACHE_PATH=str(Path(tmp)/'cache'), SWIFT_MODULECACHE_PATH=str(Path(tmp)/'cache'))
    subprocess.run(['swiftc', str(swift), '-o', str(Path(tmp)/'check')], check=True, env=env)
    subprocess.run([str(Path(tmp)/'check')], check=True, env=env)
