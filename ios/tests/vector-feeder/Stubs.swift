enum TestEnvironment {static let root=FileManager.default.temporaryDirectory.appendingPathComponent("vector-feeder-"+UUID().uuidString)}
final class UIApplication {
    enum State {case active,background,inactive}
    static let shared=UIApplication()
    var applicationState:State = .active
}
final class Settings {
    static let shared=Settings()
    var mapOn=true,theme=1,mapSource=4,buildings=true
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
    var verified=true
    var connectionGeneration=0
    var bulkPending:Bool {get {bulkActive || receiptPending} set {bulkActive=newValue}}
    var cancels=0
    var roadPaletteVersion=2
    var maxWrite=500,mapRemaining=0
    var mapBytesPerSecond:Double?=1_000_000
    var packets:[Packet]=[],commands:[String]=[]
    func send(_ value:String){commands.append(value)}
    @discardableResult func sendBulk(type:Int,id:Int,data:Data)->Bool{packets.append(Packet(type:type,id:id,bytes:data));return true}
    var trackedMapPending=false
    func bulkPending(type:Int,id:Int)->Bool {trackedMapPending}
    func cancelMapTransfers(){cancels += 1}
    func mapPayloadRemaining(id:Int)->Int {mapRemaining}
    func notify(_ s:String,target:MapFeeder){}
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
    static func build(_ f:MapGeo.Frame,cx:Double,cy:Double,includeBuildings:Bool,
                      shouldCancel:()->Bool,onBaseReady:((Data)->Void)?=nil,
                      onBuildingStatus:((String)->Void)?=nil,satellite:Bool=false,style:Int=1,preparedBase:Data?=nil,buildingView:BuildingView?=nil,onBuildingReady:((BuildingUpdate)->Void)?=nil,shouldYield:(()->Bool)?=nil,fineRoads:Bool=false,fineQuadrant:Int?=nil)throws->RasterResult {
        captures+=1
        guard UIApplication.shared.applicationState == .active else {fatalError("SDK graphics attempted while locked")}
        throw MapProcessingError.invalid("AMap path not under test")
    }
}
