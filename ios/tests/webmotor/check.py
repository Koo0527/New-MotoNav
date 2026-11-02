from pathlib import Path
import os,subprocess,tempfile
root=Path(__file__).resolve().parents[2]
s=(root/'MotoNav/WebMotor.swift').read_text()
core=s[s.index('struct MotorPoint'):s.index('enum MotorRoutes')]
start=s.index('    static func parse(_ bytes: Data')
end=s.index('\n}\n\n/// Independent',start)
core+='enum MotorRoutes {\n'+s[start:end]+'\n}\n'
nav=(root/'MotoNav/NaviBridge.swift').read_text()
start=nav.index('    static func distM('); end=nav.index('\n    }',start)+6
core+='enum NaviBridge {\n'+nav[start:end]+'\n}\n'
core+=(root/'MotoNav/RouteGeometry.swift').read_text()+'\n'
core+=(root/'MotoNav/MotorRouteTracker.swift').read_text()+'\n'
bicycle=(root/'MotoNav/BicycleRoutes.swift').read_text()
core+=(root/'MotoNav/BleHandshakeClock.swift').read_text()+'\n'
share=(root/'MotoNav/AmapShare.swift').read_text()
share=share[:share.index('final class ShareGuide')]
share=share[:share.rfind('}')+1]
# Expose only the parser to this command-line harness, leaving app visibility unchanged.
core+=share.replace('private static func parse(', 'static func parse(').replace('private struct Share {', 'struct Share {')+'\n'
# Replace only the external riding SDK boundary; execute the production request and parser.
core+=r'''
@objc protocol AMapSearchDelegate {
    @objc optional func onRouteSearchDone(_ request:AMapRouteSearchBaseRequest?,response:AMapRouteSearchResponse?)
}
final class AMapGeoPoint: NSObject {
    var latitude:CGFloat=0, longitude:CGFloat=0
    static func location(withLatitude lat:CGFloat,longitude lng:CGFloat)->AMapGeoPoint {
        let p=AMapGeoPoint();p.latitude=lat;p.longitude=lng;return p
    }
}
struct AMapRidingRouteShowFieldsType: OptionSet {
    let rawValue:UInt
    static let cost=Self(rawValue:1 << 1),navi=Self(rawValue:1 << 2),polyline=Self(rawValue:1 << 3)
}
class AMapRouteSearchBaseRequest: NSObject { var origin:AMapGeoPoint?;var destination:AMapGeoPoint? }
final class AMapRidingRouteSearchRequest: AMapRouteSearchBaseRequest { var showFieldsType:AMapRidingRouteShowFieldsType=[] }
final class AMapStep: NSObject {
    var instruction:String?,road:String?,action:String?,polyline:String?
    var distance=0,duration=0
}
final class AMapPath: NSObject { var steps:[AMapStep]?;var polyline:String?;var duration=0,distance=0 }
final class AMapRoute: NSObject { var paths:[AMapPath]?;var polyline:String? }
final class AMapRouteSearchResponse: NSObject { var route:AMapRoute? }
final class AMapSearchAPI {
    weak var delegate:AMapSearchDelegate?
    func aMapRidingRouteSearch(_ request:AMapRidingRouteSearchRequest) {
        let first=AMapStep(),second=AMapStep()
        first.instruction="沿测试路骑行";first.road="测试路";first.distance=100
        second.instruction="左转进入终点路";second.road="终点路";second.distance=50
        // SDK 9.7.5 exposes these fields only when requested with showFieldsType.
        if request.showFieldsType.contains(.polyline) {
            first.polyline="104,30;104.001,30.001"
            second.polyline="104.001,30.001;104.002,30.002"
        }
        if request.showFieldsType.contains(.navi) { first.action="直行";second.action="左转" }
        let path=AMapPath();path.steps=[first,second]
        if request.showFieldsType.contains(.cost) { path.duration=90;first.duration=60;second.duration=30 }
        let route=AMapRoute();route.paths=[path]
        let response=AMapRouteSearchResponse();response.route=route
        let receiver=delegate
        DispatchQueue.main.async { receiver?.onRouteSearchDone?(request,response:response) }
    }
}
'''
core+=(root/'MotoNav/BicycleRoutes.swift').read_text()+'\n'
tests=r'''
func expectFailure(_ body: () throws -> Void) { do { try body(); fatalError("invalid input accepted") } catch {} }
let url = URL(string:"https://www.amap.com/ssr/dir?type=4&flat=30&flon=104&dlat=30.01&dlon=104.01&vlat=30.005&vlon=104.005")!
let req = try MotorRequest.parse(url)
precondition(req.vias.count == 1)
let roundTrip = try MotorRequest.parse(req.page)
precondition(roundTrip.end.lng == 104.01)
expectFailure { _ = try MotorRequest.parse(URL(string:"http://www.amap.com/ssr/dir?type=4")!) }
expectFailure { _ = try MotorRequest.parse(URL(string:"https://evil.example/ssr/dir?type=4")!) }
expectFailure { _ = try MotorRequest.parse(URL(string:"https://www.amap.com/ssr/dir?type=0&flat=30&flon=104&dlat=31&dlon=105")!) }
expectFailure { _ = try MotorRequest.parse(URL(string:"https://www.amap.com/ssr/dir?type=4&flat=nan&flon=104&dlat=31&dlon=105")!) }
let text = """
{"code":1,"data":[{"cost":{"duration":20},"steps":[{"polyline":"104,30;104.001,30.001","instruction":"前方终点","navi":{"action":"到达"}}]}]}
"""
let route = try MotorRoutes.parse(Data(text.utf8),request:req)[0]
precondition(route.points.count == 2 && route.steps[0].dir == "S")
precondition(!MotorArrival.confirmed(remaining:800,offset:0,endpointDistance:5))
precondition(!MotorArrival.confirmed(remaining:0,offset:100,endpointDistance:5))
precondition(!MotorArrival.confirmed(remaining:0,offset:0,endpointDistance:800))
precondition(MotorArrival.confirmed(remaining:0,offset:0,endpointDistance:0))
expectFailure { _ = try MotorRoutes.parse(Data("{}".utf8),request:req) }
expectFailure { _ = try MotorRoutes.parse(Data(text.replacingOccurrences(of:"104.001,30.001",with:"120,40").utf8),request:req) }
print("PASS motor URL validation, parser, continuity and arrival regression")
let bike = "amapuri://route/plan?t=3&rideType=bike&dev=0&slat=30&slon=104&dlat=30.01&dlon=104.01"
precondition(AmapShare.parse(bike)?.mode == "ridemap")
precondition(AmapShare.parse(bike.replacingOccurrences(of:"rideType=bike",with:"rideType=elebike")) == nil)
precondition(AmapShare.parse(bike.replacingOccurrences(of:"dev=0",with:"dev=1")) == nil)
precondition(AmapShare.parse(bike + "&vian=2") == nil)
print("PASS bicycle native share parser and electric bicycle rejection")
var bicycleResult:Result<[MotorRoute],Error>?
let bicycleRequest=MotorRequest(start:MotorPoint(lat:30,lng:104),end:MotorPoint(lat:30.002,lng:104.002),bicycle:true)
Task { @MainActor in
    do { bicycleResult = .success(try await BicycleRouteQuery.load(bicycleRequest)) }
    catch { bicycleResult = .failure(error) }
}
let bicycleDeadline=Date().addingTimeInterval(5)
while bicycleResult == nil && Date()<bicycleDeadline { RunLoop.current.run(until:Date().addingTimeInterval(0.01)) }
switch bicycleResult {
case .success(let routes):
    let route=routes[0]
    precondition(route.request.bicycle && route.points.count==3,"bicycle geometry must survive the SDK response")
    precondition(route.points[2].lat==30.002 && route.points[2].lng==104.002)
    precondition(route.steps.count==2 && route.steps[1].start==1 && route.steps[1].end==2)
    precondition(route.steps[1].dir=="L" && route.steps[1].instruction=="左转进入终点路","request navigation actions")
    precondition(route.seconds==90 && route.steps[1].duration==30,"request route and step duration")
    precondition(route.totalMeters==150)
case .failure(let error):
    print("FAIL bicycle planning must request usable route details: \(error.localizedDescription)");exit(1)
case nil:
    print("FAIL bicycle planning callback timed out");exit(1)
}
print("PASS bicycle SDK request: segment geometry, actions and duration")
'''
tests+='\n'+(root/'tests/parity-015/main.swift').read_text()
core+=(root/'MotoNav/NavigationSpeed.swift').read_text()+'\n'
core+=(root/'MotoNav/PhoneClockSync.swift').read_text()+'\n'
core+=(root/'MotoNav/MotorPlanHistory.swift').read_text()+'\n'
tests+='\n'+(root/'tests/parity-016/main.swift').read_text()
tests+='\n'+(root/'tests/bicycle-planning/main.swift').read_text()
folder=Path(tempfile.mkdtemp(prefix='motonav-core-'))
(folder/'main.swift').write_text('import Foundation\n'+core+tests)
env=dict(os.environ)
env.setdefault('CLANG_MODULE_CACHE_PATH',str(folder/'clang-cache'))
env.setdefault('SWIFT_MODULECACHE_PATH',str(folder/'swift-cache'))
subprocess.run(['swiftc',str(folder/'main.swift'),'-o',str(folder/'test')],check=True,env=env)
subprocess.run([str(folder/'test')],check=True)
