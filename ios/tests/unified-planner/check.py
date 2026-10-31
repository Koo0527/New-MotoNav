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
enum MapGeo { static func wgsToGcj(_ lat:Double,_ lng:Double)->(lat:Double,lng:Double){(lat,lng)} }
'''
tests = r'''
@main struct Tests {
    @MainActor static func settle() async { for _ in 0..<20 { await Task.yield() } }
    @MainActor static func main() async {
        let p=RoutePlanner()
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
        print("PASS: unified planner lifecycle")
    }
}
'''
with tempfile.TemporaryDirectory(prefix='motonav-planner-') as tmp:
    swift = Path(tmp) / 'main.swift'
    swift.write_text(stubs + model + tests)
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
final class NaviBridge {
    struct Via { let name:String; let lat:Double; let lng:Double }
    var navigating=false, cruising=false, planFailed=false
    var info="", destLat=Double.nan, destLng=Double.nan
    var planOrigin:(Double,Double)?, shareRoute:AmapShare.Route?, vias:[Via]=[]
    var attachments=0, replans=0, clears=0
    var onReplan:(()->Void)?
    func attach(){attachments += 1}
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
