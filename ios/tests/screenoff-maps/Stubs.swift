enum TestEnvironment {static let root=FileManager.default.temporaryDirectory.appendingPathComponent("screenoff-"+UUID().uuidString)}
final class UIApplication {
    enum State {case active,background,inactive}
    static let shared=UIApplication()
    var applicationState:State = .active
}
final class Settings {
    static let shared=Settings()
    var mapOn=true,theme=1,mapSource=3,buildings=false
    var navigationActive=false
    func setNavigationActive(_ active:Bool) {
        navigationActive=active
        mapSource = (1...9).contains(theme) && !active ? 4 : 3
    }
    func syncBuildingContinuity(){}
}
final class BleLink {
    struct Packet {let type:Int,id:Int,bytes:Data}
    static let shared=BleLink()
    var buildingsSupported=true,isReady=true,bulkActive=false,receiptPending=false
    var bulkPending:Bool {get {bulkActive || receiptPending} set {bulkActive=newValue}}
    var verified=true,cancels=0
    var connectionGeneration=0
    func notify(_ s:String,target:MapFeeder) {
        // NOTIFY_BODY
    }
    var roadPaletteVersion=2
    var maxWrite=500,mapRemaining=0
    var mapBytesPerSecond:Double?=30000
    var packets:[Packet]=[],commands:[String]=[]
    func send(_ value:String){commands.append(value)}
    var trackedMapPending=false
    var refuseBulk=false
    @discardableResult func sendBulk(type:Int,id:Int,data:Data)->Bool{ if refuseBulk { return false }; packets.append(Packet(type:type,id:id,bytes:data));return true }
    func bulkPending(type:Int,id:Int)->Bool {trackedMapPending}
    func cancelMapTransfers(){cancels += 1}
    func mapPayloadRemaining(id:Int)->Int {mapRemaining}
}
enum MapPipelineTrace {
    static var names:[String]=[]
    static func event(_ name:String,_ fields:[String:Any]=[:]){names.append(name)}
    static func packet(_ bytes:Data,type:Int,id:Int,ready:Bool){}
}
final class MapSampleReport {
    static let shared=MapSampleReport()
    func fail(_ text:String){}
    func failIfWaiting(_ text:String){}
}
final class AmapCaptureHost {
    static let shared=AmapCaptureHost()
    func cancel(){}
}
enum AmapSdkRaster {
    static var captures=0
    static var fineCaptures=0
    static var lastFineRoads: Bool?
    static var lastFinePreparedBase: Data?
    static var lastIncludeBuildings: Bool?
    static var lastPreparedBase: Data?
    static var pause=false,buildingCompletion=false
    static let release=DispatchSemaphore(value:0)
    static func build(_ f:MapGeo.Frame,cx:Double,cy:Double,includeBuildings:Bool,
                      shouldCancel:()->Bool,onBaseReady:((Data)->Void)?=nil,
                      onBuildingStatus:((String)->Void)?=nil,satellite:Bool=false,style:Int=1,preparedBase:Data?=nil,buildingView:BuildingView?=nil,onBuildingReady:((BuildingUpdate)->Void)?=nil,shouldYield:(()->Bool)?=nil,fineRoads:Bool=false,fineQuadrant:Int?=nil)throws->RasterResult {
        captures+=1
        if fineRoads { fineCaptures+=1; lastFinePreparedBase=preparedBase }
        lastFineRoads=fineRoads
        lastIncludeBuildings=includeBuildings
        lastPreparedBase=preparedBase
        guard UIApplication.shared.applicationState == .active else {fatalError("Graphics attempted while locked")}
        if shouldCancel(){throw MapProcessingError.cancelled}
        if pause {_ = release.wait(timeout:.now()+5)}
        let bytes=testPacket(f,cx,cy)
        onBaseReady?(bytes)
        if includeBuildings && buildingCompletion {
            let update=BuildingUpdate(bytes:FastBuildings.packet(base:bytes,patches:[0:Data(repeating:1,count:90000)]),coverage:BuildingCoverage(checkedMask:15))
            try RouteMapCache.shared.storeBuildingUpdate(update,frame:f,source:3,node:RouteMapPlan.Node(x:cx,y:cy,distance:0))
            onBuildingReady?(update)
            return RasterResult(bytes:update.bytes,tiles:5,fromCache:0,coverage:update.coverage)
        }
        return RasterResult(bytes:bytes,tiles:1,fromCache:0)
    }
}
