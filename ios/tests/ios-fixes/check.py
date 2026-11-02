"""Run iOS search/storage regressions on macOS without network or user data."""
from pathlib import Path
import os
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
output = Path(tempfile.mkdtemp(prefix="motonav-ios-fixes-"))
env = dict(os.environ)
env.setdefault("SWIFT_MODULECACHE_PATH", str(output / "swift-cache"))
env.setdefault("CLANG_MODULE_CACHE_PATH", str(output / "clang-cache"))


def run(name, code):
    folder = output / name
    folder.mkdir()
    source = folder / "main.swift"
    source.write_text(code)
    subprocess.run(["swiftc", "-O", str(source), "-o", str(folder / "test")], check=True, env=env)
    subprocess.run([str(folder / "test")], check=True, env=env)


# Run the actual management callback with Favorites' real mutation/persistence.
content = (root / "MotoNav/ContentView.swift").read_text()
deletion = content[content.index('.onDelete { indexSet in'):].split('indexSet in', 1)[1].split('\n                    }', 1)[0]
favorites = (root / "MotoNav/RideTools.swift").read_text().split('final class Favorites:', 1)[1].split('/// WGS84 fixes only.', 1)[0]
run("favorites-deletion", r'''
import Foundation
import Combine
let domain = "motonav-delete-test-" + UUID().uuidString
let testDefaults = UserDefaults(suiteName: domain)!
defer { testDefaults.removePersistentDomain(forName: domain) }
enum SearchService { struct Place { let name: String; let address: String; let lat: Double; let lng: Double } }
enum NaviBridge { static func distM(_ a: Double, _ b: Double, _ c: Double, _ d: Double) -> Double { 100 } }
final class Favorites:
''' + favorites.replace('UserDefaults.standard', 'testDefaults') + r'''
let initial = (0..<4).map { Favorites.Place(name: String($0), address: "", lat: Double($0), lng: 0) }
func delete(_ indexSet: IndexSet) {
    let favorites = Favorites.shared
''' + deletion + r'''
}
testDefaults.set(try JSONEncoder().encode(initial), forKey: "favorite_places")
delete(IndexSet([0, 2, 3]))
precondition(Favorites.shared.places.map(\.name) == ["1"], "multi-delete must remove exactly the selected favorites")
let saved = try JSONDecoder().decode([Favorites.Place].self, from: testDefaults.data(forKey: "favorite_places")!)
precondition(saved.map(\.name) == ["1"], "saved favorites must match the surviving selection")
delete(IndexSet())
precondition(Favorites.shared.places.count == 1)
delete(IndexSet(integer: 0))
precondition(Favorites.shared.places.isEmpty)
print("PASS favorites: multi-delete, persisted survivors, empty and final item")
''')


search = (root / "MotoNav/SearchService.swift").read_text()
search = search[search.index("final class SearchService:"):search.index("/// iOS v0.4 最近去过")]
run("search", r'''
import Foundation
import ObjectiveC
import CoreLocation
import Combine
func check(_ condition: Bool, _ message: String) {
    if !condition { print("FAIL: \(message)"); exit(1) }
}
// Only the external SDK/network boundary is replaced; search behavior is production code.
@objc protocol AMapSearchDelegate {}
final class AMapGeoPoint: NSObject {
    var latitude=31.0; var longitude=121.0
    static func location(withLatitude lat:CGFloat,longitude lng:CGFloat)->AMapGeoPoint { let p=AMapGeoPoint();p.latitude=Double(lat);p.longitude=Double(lng);return p }
}
class AMapPOISearchBaseRequest: NSObject {}
final class AMapPOIAroundSearchRequest: AMapPOISearchBaseRequest {
    var location:AMapGeoPoint?;var keywords="";var types="";var sortrule=0;var radius=0;var offset=0
}
final class AMapPOI: NSObject { var name:String?;var address:String?;var location:AMapGeoPoint? }
final class AMapPOISearchResponse: NSObject { var pois:[AMapPOI]? }
enum MotorRequest { static func valid(_ lat:Double,_ lng:Double)->Bool { lat.isFinite && lng.isFinite && (-90...90).contains(lat) && (-180...180).contains(lng) } }
final class AMapTip: NSObject { var name:String?; var district:String?; var address:String?; var location:AMapGeoPoint? }
final class AMapInputTipsSearchRequest: NSObject { var keywords:String?; var location:String? }
final class AMapInputTipsSearchResponse: NSObject { var tips:[AMapTip]? }
final class AMapSearchAPI: NSObject {
    static var requests:[AMapInputTipsSearchRequest]=[]
    static var fuelRequests:[AMapPOIAroundSearchRequest]=[]
    var delegate:AMapSearchDelegate?
    func aMapInputTipsSearch(_ request:AMapInputTipsSearchRequest) { Self.requests.append(request) }
    func aMapPOIAroundSearch(_ request:AMapPOIAroundSearchRequest) { Self.fuelRequests.append(request) }
}
final class LocationService { static let shared=LocationService(); var location:CLLocation? }
enum MapGeo { static func wgsToGcj(_ lat:Double,_ lng:Double)->(lat:Double,lng:Double) { (lat,lng) } }
''' + search + r'''
func response(_ name:String)->AMapInputTipsSearchResponse {
    let tip=AMapTip(); tip.name=name; tip.location=AMapGeoPoint()
    let response=AMapInputTipsSearchResponse(); response.tips=[tip]; return response
}
let search=SearchService()
LocationService.shared.location=CLLocation(latitude:31.23,longitude:121.47)
search.search("加油站")
let original=AMapSearchAPI.requests.last!
search.mnTipsDone(original,response:response("旧地区"))
LocationService.shared.location=CLLocation(latitude:30.27,longitude:120.15)
search.clear(); search.search("加油站")
check(AMapSearchAPI.requests.count==2,"searching after movement must request the new location")
let current=AMapSearchAPI.requests.last!
check(current.location=="120.150000,30.270000","the new request must use the new position")
search.mnTipsDone(current,response:response("新地区"))
check(search.results.first?.name=="新地区","show the current result")
search.mnTipsDone(original,response:response("迟到旧结果"))
check(search.results.first?.name=="新地区","old callbacks must not replace current results")
search.search("医院")
let cleared=AMapSearchAPI.requests.last!
search.clear(); search.mnTipsDone(cleared,response:response("已取消"))
check(search.results.isEmpty,"cleared search must remain cleared after a late callback")
search.search("停车场")
let pending=AMapSearchAPI.requests.last!
search.mnSearchFail(original,error:NSError(domain:"test",code:1002))
check(search.status=="搜索中…","a stale failure must not interrupt a newer search")
search.mnSearchFail(pending,error:NSError(domain:"test",code:1002))
check(search.status.contains("1002"),"current SDK errors must still reach the user")
// Repeated same-text requests must be distinguished by object identity too.
search.search("同名地点",near:(32,122))
let oldSame=AMapSearchAPI.requests.last!
search.search("同名地点",near:(32,122))
let newSame=AMapSearchAPI.requests.last!
search.mnTipsDone(oldSame,response:response("同词迟到结果"))
check(search.results.isEmpty && search.status=="搜索中…","same keyword/location is insufficient to accept an old result")
search.mnSearchFail(oldSame,error:NSError(domain:"test",code:1002))
check(search.status=="搜索中…","same-keyword stale errors must be ignored")
search.mnTipsDone(newSame,response:response("最新同名地点"))
let count=AMapSearchAPI.requests.count
search.search("同名地点",near:(32,122))
check(AMapSearchAPI.requests.count==count && search.results.first?.name=="最新同名地点","only accepted results populate the location cache")
search.search("同名地点",near:(33,123))
check(AMapSearchAPI.requests.count==count+1,"cache entries must be location sensitive")
search.searchFuel(near:(32,122))
let oldFuel=AMapSearchAPI.fuelRequests.last!
search.searchFuel(near:(33,123))
let fuel=AMapSearchAPI.fuelRequests.last!
check(fuel.location?.latitude==33 && fuel.location?.longitude==123,"fuel search uses explicit route origin")
let poi=AMapPOI();poi.name="当前加油站";poi.location=AMapGeoPoint()
let stations=AMapPOISearchResponse();stations.pois=[poi]
search.mnFuelDone(oldFuel,response:stations)
search.mnSearchFail(oldFuel,error:NSError(domain:"test",code:1002))
check(search.results.isEmpty && search.status=="搜索附近加油站…","stale fuel success and failure are ignored")
search.mnFuelDone(fuel,response:stations)
check(search.results.first?.name=="当前加油站","current fuel results appear")
search.search("新目的地")
search.mnFuelDone(fuel,response:stations)
check(search.results.isEmpty && search.status=="搜索中…","fuel results cannot replace a newer tip search")
search.searchFuel(near:(32,122))
search.mnSearchFail(AMapSearchAPI.fuelRequests.last!,error:NSError(domain:"test",code:1002))
check(search.status.contains("1002"),"current fuel errors remain actionable")
search.searchFuel(near:(Double.nan,122))
search.mnTipsDone(AMapSearchAPI.requests.last!,response:response("旧提示"))
check(search.results.isEmpty && search.status.contains("等待定位"),"invalid fuel origins cancel older requests")
print("PASS search: moved origin, location cache, same-keyword identity, cancellation, fuel results and current errors")
''')

rides = (root / "MotoNav/RideTools.swift").read_text()
rides = rides[rides.index("final class RideRecorder:"):rides.index("struct RideHistoryView:")]
# Redirect the legacy implementation's private initializer to temporary storage too.
if "private init() {" in rides:
    start = rides.index("    private let root =")
    end = rides.index("\n", start)
    rides = rides[:start] + "    private let root: URL" + rides[end:]
    rides = rides.replace("private init() {", "init(directory: URL) {\n        root = directory")
    rides = rides.replace("static let shared = RideRecorder()", "static let shared = RideRecorder(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))")
run("rides", r'''
final class GRecorder { static let shared=GRecorder(); func rideStarted(_ id:UUID) {}; func rideFinished(_ id:UUID) {}; func unlinkRide(_ id:UUID) {} }
import Foundation
import CoreLocation
import Combine
func check(_ condition: Bool, _ message: String) {
    if !condition { print("FAIL: \(message)"); exit(1) }
}
func wait(_ message:String,_ condition:()->Bool) {
    let deadline=Date().addingTimeInterval(5)
    while !condition() && Date()<deadline { RunLoop.current.run(until:Date().addingTimeInterval(0.01)) }
    check(condition(),message)
}
''' + rides + r'''
let fm=FileManager.default
let root=fm.temporaryDirectory.appendingPathComponent("rides-\(UUID().uuidString)")
try fm.createDirectory(at:root,withIntermediateDirectories:true)
defer { try? fm.removeItem(at:root) }
let legacy="""
{"id":"11111111-1111-1111-1111-111111111111","started":0,"ended":1,"mode":"旧记录","fixes":[{"lat":31,"lng":121,"time":0,"speed":2}],"meters":0}
"""
try Data(legacy.utf8).write(to:root.appendingPathComponent("11111111-1111-1111-1111-111111111111.json"))
let recorder=RideRecorder(directory:root)
wait("legacy JSON records must remain readable") { recorder.rides.count==1 }
recorder.start("巡航")
let id=recorder.active!.id
let metadata=root.appendingPathComponent(id.uuidString+".json")
let journal=root.appendingPathComponent(id.uuidString+".jsonl")
wait("new ride metadata must reach disk") { fm.fileExists(atPath:metadata.path) }
let stamp=Date().addingTimeInterval(-10)
for i in 0..<90 {
    let fix=CLLocation(coordinate:.init(latitude:31+Double(i)*0.00005,longitude:121),altitude:0,horizontalAccuracy:5,verticalAccuracy:5,course:0,speed:10,timestamp:stamp.addingTimeInterval(Double(i)*0.1))
    recorder.fix(fix)
}
check(recorder.active?.fixes.count==90,"accepted WGS84 points must remain available")
wait("points must be appended to a journal rather than rewriting the full ride") {
    ((try? String(contentsOf:journal,encoding:.utf8)) ?? "").split(separator:"\n").count==90
}
let summary=try JSONDecoder().decode(RideRecorder.Ride.self,from:Data(contentsOf:metadata))
check(summary.fixes.isEmpty,"per-point writes must not rewrite the full JSON snapshot")
let recoveryRoot=fm.temporaryDirectory.appendingPathComponent("recovery-\(UUID().uuidString)")
try fm.createDirectory(at:recoveryRoot,withIntermediateDirectories:true)
defer { try? fm.removeItem(at:recoveryRoot) }
try fm.copyItem(at:metadata,to:recoveryRoot.appendingPathComponent(metadata.lastPathComponent))
var interrupted=try Data(contentsOf:journal);interrupted.append(Data("{\"partial\":".utf8))
try interrupted.write(to:recoveryRoot.appendingPathComponent(journal.lastPathComponent))
let recovered=RideRecorder(directory:recoveryRoot)
wait("interrupted journal must recover every complete point") { recovered.rides.first?.fixes.count==90 }
check(recovered.rides.first?.ended==stamp.addingTimeInterval(8.9),"recovery ends at the last accepted fix")
check((recovered.rides.first?.meters ?? 0)>400,"recovery must preserve recorded distance")
let gpx=try recovered.export(recovered.rides[0]);defer {try? fm.removeItem(at:gpx)}
check(try String(contentsOf:gpx,encoding:.utf8).components(separatedBy:"<trkpt ").count-1==90,"GPX must preserve every recovered point")
recorder.finish()
wait("finish must archive the complete ride") { recorder.rides.contains{$0.id==id} }
check(!fm.fileExists(atPath:journal.path),"journal is removed only after successful archive")
check(recorder.rides.first?.fixes.count==90,"archive must contain every accepted point")
for mode in ["导航一","导航二"] { recorder.start(mode); recorder.finish() }
wait("rapid stop/start must keep separate sessions") { recorder.rides.count==4 }
check(Set(recorder.rides.map{$0.id}).count==4,"session IDs must not be mixed by asynchronous writes")
let old=recorder.rides.first{$0.mode=="旧记录"}!
recorder.remove(old)
wait("deletion must update disk and history") { !recorder.rides.contains{$0.id==old.id} && !fm.fileExists(atPath:root.appendingPathComponent(old.id.uuidString+".json").path) }
print("PASS rides: append-only storage, legacy files, interrupted tail recovery, GPX and session ordering")
''')

navigation = (root / "MotoNav/NaviScreen.swift").read_text()
readout = navigation[navigation.index("struct NavigationReadout"):navigation.index("struct NavigationPanelHeights")]
layout = navigation[navigation.index("enum NaviHudLayout"):navigation.index("/// Three navigation engines")]
navigation = navigation[navigation.index("final class DriveViewController:"):navigation.index("struct NaviScreen:")]
# UIKit's edge-inset return type is replaced only at the macOS test boundary.
navigation = navigation.replace("@objc(driveViewEdgePadding:)", "").replace("@objc(rideViewEdgePadding:)", "")
run("navigation-ui", r'''
import Foundation
import CoreGraphics
import ObjectiveC
import Combine
func check(_ condition:Bool,_ message:String) {
    if !condition { print("FAIL: \(message)");exit(1) }
}
protocol UIViewRepresentable { typealias Context = Void }
final class UIImage {}
struct UIEdgeInsets: Equatable {
    var top:CGFloat,left:CGFloat,bottom:CGFloat,right:CGFloat
    static let zero=Self(top:0,left:0,bottom:0,right:0)
}
enum NaviBridge {
    static func distText(_ m:Int)->String { "\(m) 米" }
    static func durText(_ s:Int)->String { "\(s) 秒" }
}
@objc protocol AMapNaviDriveViewDelegate {}
@objc protocol AMapNaviRideViewDelegate {}
enum AMapNaviViewMapModeType { case day,night }
enum AMapNaviDriveViewShowMode { case overview,carPositionLocked }
final class AMapNaviDriveView: NSObject {
    var delegate:AMapNaviDriveViewDelegate?
    var mapViewModeType=AMapNaviViewMapModeType.day
    var showMode=AMapNaviDriveViewShowMode.carPositionLocked
    var mapShowTraffic=true,showUIElements=true,showCrossImage=true,showTrafficLightView=false
    var screenAnchor=CGPoint(x:0.5,y:0.5)
    var bounds=CGRect(x:0,y:0,width:393,height:852)
    var overviewUpdates=0
    init(frame:CGRect) { super.init() }
    func updateRoutePolylineInTheVisualRangeWhenTheShowModeIsOverview() { overviewUpdates+=1 }
}
final class AMapNaviDriveManager {
    static let shared=AMapNaviDriveManager()
    static func sharedInstance()->AMapNaviDriveManager { shared }
    var representatives:[AMapNaviDriveView]=[]
    func addDataRepresentative(_ view:AMapNaviDriveView) { representatives.append(view) }
    func removeDataRepresentative(_ view:AMapNaviDriveView) { representatives.removeAll{$0 === view} }
}
final class AMapNaviRideManager {
    static let shared=AMapNaviRideManager()
    static func sharedInstance()->AMapNaviRideManager { shared }
    var representatives:[AMapNaviRideView]=[]
    func addDataRepresentative(_ view:AMapNaviRideView) { representatives.append(view) }
    func removeDataRepresentative(_ view:AMapNaviRideView) { representatives.removeAll{$0 === view} }
}
enum AMapNaviRideViewShowMode { case overview,carPositionLocked }
final class AMapNaviRideView: NSObject {
    var delegate:AMapNaviRideViewDelegate?
    var showMode=AMapNaviRideViewShowMode.carPositionLocked
    var showUIElements=true
    var screenAnchor=CGPoint(x:0.5,y:0.5)
    var bounds=CGRect(x:0,y:0,width:393,height:852)
    var overviewUpdates=0
    init(frame:CGRect) { super.init() }
    func updateRoutePolylineInTheVisualRangeWhenTheShowModeIsOverview() { overviewUpdates+=1 }
}
final class NavigationCoordinator {
    static let shared=NavigationCoordinator()
    enum Engine { case none, drive, ride }
    var active:Engine = .drive
    func attachDriveMap(_ view:AMapNaviDriveView) { guard active == .drive else { return }; AMapNaviDriveManager.shared.addDataRepresentative(view) }
    func detachDriveMap(_ view:AMapNaviDriveView) { guard active == .drive else { return }; AMapNaviDriveManager.shared.removeDataRepresentative(view) }
    func attachRideMap(_ view:AMapNaviRideView) { guard active == .ride else { return }; AMapNaviRideManager.shared.representatives.append(view) }
    func detachRideMap(_ view:AMapNaviRideView) { guard active == .ride else { return }; AMapNaviRideManager.shared.representatives.removeAll{$0 === view} }
}
''' + readout + layout + navigation + r'''
let drive=DriveViewController()
let renderer=AMapDriveViewRep(controller:drive,night:true)
let view=renderer.makeUIView(context:())
check(!view.showUIElements,"default navigation must leave room for the shared App interface")
check(view.mapViewModeType == .night,"keep the selected map palette")
check(AMapNaviDriveManager.shared.representatives.count==1,"the SDK map must remain attached to navigation data")
renderer.updateUIView(view,context:())
check(AMapNaviDriveManager.shared.representatives.count==1,"display updates must not attach another map")
check(view.showTrafficLightView,"keep the SDK traffic-light display enabled")
var full=renderer
full.showNativeUI=true
full.updateUIView(view,context:())
check(view.showUIElements && view.showCrossImage,"full navigation must restore the SDK interface and junction images")
check(drive.mapPadding(view) == .zero,"the SDK interface controls its own visible map area")
var custom=renderer
custom.edgePadding=UIEdgeInsets(top:180,left:16,bottom:280,right:16)
view.showMode = .overview
custom.updateUIView(view,context:())
check(!view.showUIElements && !view.showCrossImage,"return to the shared App interface")
check(drive.mapPadding(view)==custom.edgePadding,"route overview must avoid the measured panels")
check(view.overviewUpdates==1,"update overview when visible map bounds change")
custom.updateUIView(view,context:())
check(view.overviewUpdates==1,"unchanged display updates must not reset route overview")
check(view.screenAnchor.y>0 && view.screenAnchor.y<1,"the vehicle anchor must remain inside the map")
check(AMapNaviDriveManager.shared.representatives.count==1 && drive.view === view,"switching styles keeps the same navigation map")
var readout=NavigationReadout(direction:"S",turnMetres:100,instruction:"",status:"",speed:0,remaining:1000,
                              remainingSeconds:120,simulation:false,paused:false,simulationSpeed:60,arrived:false)
for (direction,symbol,label) in [("L","arrow.turn.up.left","左转"),("R","arrow.turn.up.right","右转"),
                                ("SL","arrow.up.left","左前方"),("SR","arrow.up.right","右前方"),
                                ("U","arrow.uturn.down","掉头"),("A","mappin.and.ellipse","前方目的地"),
                                ("S","arrow.up","直行"),("","arrow.up","直行")] {
    readout.direction=direction
    check(readout.turn.symbol==symbol && readout.turn.label==label,"both engines need the same visible and spoken turn direction")
}
// 缺失数据显示"—"，不填充虚构提示
var missing=NavigationReadout(direction:"S",turnMetres:-1,instruction:"",status:"",speed:0,remaining:-1,
                              remainingSeconds:0,simulation:false,paused:false,simulationSpeed:60,arrived:false)
check(missing.turnDistanceText=="—" && missing.remainingText=="剩余 —" && missing.etaText=="到达时间 —",
      "missing guidance data renders an em dash instead of an invented value")
var present=NavigationReadout(direction:"S",turnMetres:1200,instruction:"",status:"",speed:0,remaining:3400,
                              remainingSeconds:120,simulation:false,paused:false,simulationSpeed:60,arrived:false)
check(present.turnDistanceText=="1200 米" && present.remainingText=="剩余 3400 米" && present.etaText=="约 120 秒 到",
      "real guidance data renders the true values")
// 统一 HUD 布局：按实测卡片高度设置地图可视区域（动态字号、安全区由实测传入）
var insets=NaviHudLayout.mapEdgeInsets(panelTop:150,panelBottom:200,safeTop:59,safeBottom:34)
check(insets==UIEdgeInsets(top:225,left:16,bottom:250,right:16),
      "map insets follow measured panel heights, safe areas and breathing margin")
check(NaviHudLayout.mapEdgeInsets(panelTop:0,panelBottom:0,safeTop:0,safeBottom:0,margin:0) == .zero,
      "zero inputs collapse to zero insets")
let anchor=NaviHudLayout.carAnchor(boundsHeight:852,padding:UIEdgeInsets(top:225,left:16,bottom:250,right:16))
check(abs(anchor.y-(225+0.6*(852-475))/852)<0.0001 && anchor.x==0.5,
      "the vehicle anchor sits at about 60% of the HUD-free visible area")
check(NaviHudLayout.carAnchor(boundsHeight:852,padding:UIEdgeInsets(top:900,left:16,bottom:0,right:16)).y==0.85,
      "the anchor stays clamped inside the map")
AMapDriveViewRep.dismantleUIView(view,coordinator:())
check(AMapNaviDriveManager.shared.representatives.isEmpty,"dismissal must detach the map")
// 引擎所有权：非驾车所有者时，地图绑定/解绑不得触碰驾车单例（切换骑行后地图销毁不得重建它）
NavigationCoordinator.shared.active = .ride
let rideView=renderer.makeUIView(context:())
check(AMapNaviDriveManager.shared.representatives.isEmpty,"attaching a map while ride owns the engine touches no drive SDK")
AMapDriveViewRep.dismantleUIView(rideView,coordinator:())
check(AMapNaviDriveManager.shared.representatives.isEmpty,"map teardown under a foreign owner still touches no drive SDK")
NavigationCoordinator.shared.active = .none
AMapDriveViewRep.dismantleUIView(view,coordinator:())
check(AMapNaviDriveManager.shared.representatives.isEmpty,"teardown with no owner also stays silent")
// 官方骑行地图容器：与驾车同一套统一 HUD 规则（默认隐藏 SDK 自带 UI、边距、锚点、属主门禁）
NavigationCoordinator.shared.active = .ride
let rideCtl=RideViewController()
let rideRenderer=AMapRideViewRep(controller:rideCtl)
let rv=rideRenderer.makeUIView(context:())
check(!rv.showUIElements,"ride navigation must also leave room for the shared App interface")
check(AMapNaviRideManager.shared.representatives.count==1,"the ride map attaches to the ride engine data")
check(!rideCtl.isOverview,"ride view starts in follow mode")
rideCtl.toggleOverview()
check(rv.showMode == .overview && rideCtl.isOverview,"the shared overview button really toggles into overview")
rideCtl.toggleOverview()
check(rv.showMode != .overview,"and back into follow mode")
rv.showMode = .overview
var ridePadded=rideRenderer
ridePadded.edgePadding=UIEdgeInsets(top:200,left:16,bottom:260,right:16)
ridePadded.updateUIView(rv,context:())
check(rv.overviewUpdates==1 && rideCtl.mapPadding(rv)==ridePadded.edgePadding,
      "ride overview must avoid the measured panels")
check(abs(rv.screenAnchor.y-NaviHudLayout.carAnchor(boundsHeight:rv.bounds.height,padding:ridePadded.edgePadding).y)<0.0001,
      "ride anchor follows the same pure layout rule as drive")
var rideFull=rideRenderer
rideFull.showNativeUI=true
rideFull.updateUIView(rv,context:())
check(rv.showUIElements,"full ride navigation restores the SDK interface")
check(rideCtl.mapPadding(rv) == .zero,"the SDK ride interface controls its own visible map area")
AMapRideViewRep.dismantleUIView(rv,coordinator:())
check(AMapNaviRideManager.shared.representatives.isEmpty,"ride map dismissal detaches from the engine")
NavigationCoordinator.shared.active = .drive
let strayRide=rideRenderer.makeUIView(context:())
check(AMapNaviRideManager.shared.representatives.isEmpty && AMapNaviDriveManager.shared.representatives.isEmpty,
      "attaching a ride map while drive owns the engine touches no ride SDK and rebuilds no drive singleton")
AMapRideViewRep.dismantleUIView(strayRide,coordinator:())
check(AMapNaviRideManager.shared.representatives.isEmpty,"ride map teardown under a foreign owner stays silent")
print("PASS navigation UI: shared display, native hints, map padding, turn accessibility and SDK map lifecycle")
''')

# A finished simulator must never remain the origin of the next real route.
bridge = (root / "MotoNav/NaviBridge.swift").read_text()


def bridge_method(signature):
    start = bridge.index(signature)
    opening = bridge.index("{", start)
    depth, end = 1, opening + 1
    while depth:
        depth += (bridge[end] == "{") - (bridge[end] == "}")
        end += 1
    return bridge[start:end].replace("private func", "func", 1)


run("navigation-position", r'''
import Foundation
import CoreLocation
func check(_ value: Bool, _ message: String) {
    if !value { print("FAIL: \(message)"); exit(1) }
}
// Replace device/SDK side effects; the position getters, lifecycle and callback gate are real.
final class LocationService {
    static let shared=LocationService()
    var location:CLLocation?
    func setPrecise(_ on:Bool) {}
}
final class RideRecorder { static let shared=RideRecorder(); func finish() {} }
final class MapFeeder {
    static let shared=MapFeeder()
    func onNaviEnd() {}
    func onLocation(lat:Double,lng:Double,bearing:Double,kmh:Int) {}
}
final class ShareGuide {
    static let shared=ShareGuide()
    func stop() {}
    func onLocation(_ lat:Double,_ lng:Double) {}
}
final class Settings { static let shared=Settings(); func resetTunnel() {} }
final class BleLink { static let shared=BleLink(); func send(_ text:String) {} }
final class AMapNaviDriveManager {
    var onStop:(()->Void)?
    var stopNaviCalls=0
    func stopNavi() { stopNaviCalls += 1; onStop?() }
}
final class RideBridge { static let shared=RideBridge() }
final class WebMotorSession { static let shared=WebMotorSession() }
final class NavigationCoordinator {
    static let shared=NavigationCoordinator()
    var driveManager:AMapNaviDriveManager?
    func driveManagerIfActive()->AMapNaviDriveManager? { driveManager }
}
final class AMapNaviLocation {
    let coordinate:CLLocationCoordinate2D?
    let speed=60,heading=90.0
    init(_ lat:Double,_ lng:Double) { coordinate=CLLocationCoordinate2D(latitude:lat,longitude:lng) }
}
''' + (root / "MotoNav/ArrivalPolicy.swift").read_text() + '''
enum MapGeo {
''' + (root / "MotoNav/MapGeo.swift").read_text().split("enum MapGeo {", 1)[1].split("    // MARK: - 平面坐标", 1)[0] + '''
}
final class NaviBridge {
    let arrival=ArrivalPolicy(),manager=AMapNaviDriveManager()
    var uiLaneImage:Int?,uiCrossImage:Int?
    var navigating=false,cruising=false,emulating=false,emuPaused=false,showArrived=false
    var myLat=Double.nan,myLng=Double.nan
    var arriveSeq=0,info="",shownDir="",shownDist = -1,lastSent=""
    var tick:Timer?,suggestTimer:Timer?
    var tunnelRouteKey="",tunnelPath:Int?,lastTunnelFix=Date.distantPast
    var tripMeters=0.0,tripMaxKmh=0,tripStarted=Date(),tripPosition:(lat:Double,lng:Double)?
    var curDir="",curAngle:Int?,angleKey="",lastRouteKey="",baseDist=0,speedMps=0.0,speedKmhNow=0
    var lastRoadText="",lastBottomText="",lastTrip="",lastSpeedMsg="",rerouting=false
    var lightBase = -1,lastLightMsg="",lastCamMsg="",lastCamAt=Date.distantPast,camLimit=0,camMinDist=Int.max,lastCamMapMsg=""
    var camPts:[Int]=[],cruiseCamPts:[Int]=[],facPts:[String:Int]=[:],navFacPts:[Int]=[],routeFacKey="",uiRemainM=0,uiRemainS=0
    var lastLaneMsg="",lastTrafficMsg="",lastTrafficAt=Date.distantPast,gpsWeakSent=false
    var suggestRoute:Int?,uiSuggestMin=0,uiDir="",uiDist = -1,uiRoad="",extraInfo="",uiSpeed=0
    func clearSuggest() {}
    func send(_ text:String) { lastSent=text }
    func updateTunnel(_ fix:AMapNaviLocation,manager:AMapNaviDriveManager) {}
''' + '\n'.join(bridge_method(signature) for signature in [
    "var lastLocation: CLLocation?", "func myPosition()", "func stop()",
    "private func finish(", "private func resetState()", "func mnEmuEnd(",
    "func mnLocation(", "static func distM(",
]) + r'''
}
func phone(_ lat:Double=51.5,_ lng:Double = -0.12) {
    LocationService.shared.location=CLLocation(latitude:lat,longitude:lng)
}
func expectPhone(_ bridge:NaviBridge,_ message:String,lat:Double=51.5,lng:Double = -0.12) {
    let point=bridge.myPosition()
    check(point?.lat==lat && point?.lng==lng,message)
}
func begin(_ bridge:NaviBridge,simulate:Bool) {
    bridge.resetState()
    bridge.arrival.begin(simulation:simulate)
    bridge.navigating=true;bridge.emulating=simulate
}
phone()
let simulator=NaviBridge()
begin(simulator,simulate:true)
simulator.mnLocation(simulator.manager,location:AMapNaviLocation(32,118))
simulator.mnEmuEnd(simulator.manager)
expectPhone(simulator,"natural simulation end restores actual phone position")
check(simulator.lastLocation==nil,"ended simulator is not a real navigation location")
check(!simulator.emulating && !simulator.emuPaused,"completed simulation clears its active flags")
phone(51.51,-0.11)
expectPhone(simulator,"subsequent physical movement updates current position",lat:51.51,lng:-0.11)
simulator.mnLocation(simulator.manager,location:AMapNaviLocation(33,119))
expectPhone(simulator,"late simulator fixes cannot replace real position",lat:51.51,lng:-0.11)

phone()
let cancelled=NaviBridge()
begin(cancelled,simulate:true)
cancelled.mnLocation(cancelled.manager,location:AMapNaviLocation(32,118))
cancelled.emuPaused=true
cancelled.manager.onStop={cancelled.mnEmuEnd(cancelled.manager)}
NavigationCoordinator.shared.driveManager=cancelled.manager   // 驾车引擎属主：stopNavi 正常触达
let stopsBefore=cancelled.manager.stopNaviCalls
cancelled.stop()
check(cancelled.manager.stopNaviCalls==stopsBefore+1,"stop touches the SDK while drive owns the engine")
expectPhone(cancelled,"manual simulation exit restores phone position despite synchronous end callback")
check(!cancelled.emulating && !cancelled.emuPaused,"manual exit clears simulation flags")
check(cancelled.lastLocation==nil,"manual exit clears cached simulation location")

// 独立导航接管（WebMotor.start → NaviBridge.stop）时引擎可能已切到骑行：
// stop 不得触碰或重建不属于驾车的单例，但仍要完成自身收尾
NavigationCoordinator.shared.driveManager=nil              // 骑行引擎属主（或尚未创建）
phone()
let takenOver=NaviBridge()
begin(takenOver,simulate:true)
takenOver.mnLocation(takenOver.manager,location:AMapNaviLocation(32,118))
takenOver.manager.onStop={takenOver.mnEmuEnd(takenOver.manager)}
takenOver.stop()
check(takenOver.manager.stopNaviCalls==0,"takeover stop never touches a drive engine the coordinator does not own")
check(!takenOver.navigating && !takenOver.emulating,"takeover stop still finishes its own navigation state")
expectPhone(takenOver,"takeover stop still restores the live phone position")

NavigationCoordinator.shared.driveManager=cancelled.manager
begin(cancelled,simulate:false)
expectPhone(cancelled,"a new GPS trip must not reuse the previous simulator position")
cancelled.mnLocation(cancelled.manager,location:AMapNaviLocation(31.23,121.47))
check(cancelled.myPosition()?.lat==31.23 && cancelled.myPosition()?.lng==121.47,"active GPS navigation keeps its matched SDK coordinates without double conversion")
check(cancelled.lastLocation?.coordinate.latitude==31.23,"real guidance still exposes its navigation location")
cancelled.stop()
expectPhone(cancelled,"ending GPS guidance also returns to live phone position")

begin(cancelled,simulate:true)
cancelled.mnLocation(cancelled.manager,location:AMapNaviLocation(32,118))
check(cancelled.lastLocation==nil,"simulation must not act as the physical location for day/night settings")
expectPhone(cancelled,"current physical position stays separate from simulator progress")
LocationService.shared.location=nil
cancelled.stop()
check(cancelled.myPosition()==nil,"without a real fix report unavailable instead of the simulated destination")
check(cancelled.lastLocation==nil,"unknown real position stays unknown")
print("PASS navigation position: simulator completion/cancel, stale callbacks, live movement, next GPS trip and no-fix fallback")
''')

# A delayed clear must precede the new lanes and must not be coalesced with a turn.
ble = (root / "MotoNav/BleLink.swift").read_text()
key_of = ble[ble.index("    private func keyOf("):ble.index("    /// 发一条文字消息")]
send = ble[ble.index("    func send(_ msg:"):ble.index("    /// 只发一次")]
send_once = ble[ble.index("    func sendOnce("):ble.index("    /// 圆屏屏幕数据线速度")]
enqueue = ble[ble.index("    private func enqueue("):ble.index("    private func header(")]
run("ble-navigation-state", r'''
import Foundation
func check(_ value: Bool, _ message: String) {
    if !value { print("FAIL: \(message)"); exit(1) }
}
final class BleLink {
    struct Out { let key: String?; var data: Data }
    var queue: [Out] = []
    var lastState: [String: String] = [:]
    var stateOrder: [String] = []
    var lastImg: [Int: (w: Int, h: Int, data: Data)] = [:]
    // Only CoreBluetooth's write-credit boundary is blocked; queue and cache logic are production code.
    func pump() {}
    func sendClock(_ message: String) {}
    var writes: [String] { queue.map { String(data: $0.data, encoding: .utf8)! } }
    var replay: [String] { stateOrder.compactMap { lastState[$0] } }
''' + key_of + send + send_once + enqueue + r'''
}
let link = BleLink()
link.send("#b,200")
link.send("#j,0033")
link.send("#v,60")
link.queue.append(BleLink.Out(key: "B0:1:0", data: Data([0])))
link.lastImg[0] = (1, 1, Data([0]))
link.send("C")
link.send("#j,1100")
check(link.writes == ["#b,200", "C", "#j,1100"],
      "clear drops old navigation and bitmaps before queuing the new lanes")
check(link.lastImg.isEmpty, "clear cannot replay an old road bitmap")
link.send("R,90")
check(link.writes == ["#b,200", "C", "#j,1100", "R,90"],
      "the first new turn cannot overwrite a pending clear")
check(link.replay == ["#b,200", "C", "#j,1100", "R,90"],
      "reconnect cache also preserves clear before the current lanes and turn")

link.send("#j")
check(link.writes == ["#b,200", "C", "#j", "R,90"],
      "an explicit SDK hide replaces pending lanes")
link.send("#j,1100")
check(link.writes == ["#b,200", "C", "#j,1100", "R,90"],
      "the same lanes can return after a hide without losing the clear")
link.send("L,50")
check(link.writes == ["#b,200", "C", "#j,1100", "L,50"],
      "ordinary turns still coalesce to the latest guidance")

link.send("A,0")
link.send("#O1500/5/60")
link.send("C")
check(link.writes == ["#b,200", "C"] && link.replay == ["#b,200", "C"],
      "another clear discards old arrival, trip and lane state in both queue and cache")
link.send("#j,3300")
link.send("S,400")
check(link.writes == ["#b,200", "C", "#j,3300", "S,400"],
      "a later trip preserves clear, lane and guidance ordering")

let controls = BleLink()
controls.sendOnce("#q,80")
controls.sendOnce("#f,1")
controls.send("#ML,1")
controls.send("#j,0033")
controls.send("C")
controls.send("#j,1100")
check(controls.writes == ["#q,80", "#f,1", "#ML,1", "C", "#j,1100"],
      "clearing navigation preserves pending hardware calibration and media controls")
let deviceCommands = ["#TM,FFFF,255,70,0,1", "#CTL", "#PS", "#PS,600,120", "#BS", "#BS,1,20", "#GC,2,359", "#GQ"]
for command in deviceCommands { controls.send(command) }
check(controls.replay.allSatisfy { !deviceCommands.contains($0) }, "device commands never enter reconnect cache")
controls.send("C")
check(controls.replay.allSatisfy { !deviceCommands.contains($0) }, "navigation clear cannot resurrect device commands")
print("PASS BLE navigation state: backpressure, clear/lane/turn order, reconnect cache, hide/show and arrival cleanup")
''')
