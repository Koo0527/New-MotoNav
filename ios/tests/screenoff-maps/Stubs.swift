enum TestEnvironment {static let root=FileManager.default.temporaryDirectory.appendingPathComponent("screenoff-"+UUID().uuidString)}
final class UIApplication {
    enum State {case active,background,inactive}
    static let shared=UIApplication()
    var applicationState:State = .active
}
final class Settings {
    static let shared=Settings()
    var mapOn=true,theme=1,mapSource=3,buildings=false
    func syncBuildingContinuity(){}
}
final class BleLink {
    struct Packet {let type:Int,id:Int,bytes:Data}
    static let shared=BleLink()
    var buildingsSupported=true,isReady=true,bulkPending=false
    var maxWrite=500,mapRemaining=0
    var mapBytesPerSecond:Double?=30000
    var packets:[Packet]=[],commands:[String]=[]
    func send(_ value:String){commands.append(value)}
    func sendBulk(type:Int,id:Int,data:Data){packets.append(Packet(type:type,id:id,bytes:data))}
    func bulkPending(type:Int,id:Int)->Bool {false}
    func cancelMapTransfers(){}
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
    static var pause=false
    static let release=DispatchSemaphore(value:0)
    static func build(_ f:MapGeo.Frame,cx:Double,cy:Double,includeBuildings:Bool,
                      shouldCancel:()->Bool,onBaseReady:((Data)->Void)?=nil,
                      onBuildingStatus:((String)->Void)?=nil,satellite:Bool=false,style:Int=1,preparedBase:Data?=nil,buildingView:BuildingView?=nil,onBuildingReady:((BuildingUpdate)->Void)?=nil,shouldYield:(()->Bool)?=nil)throws->RasterResult {
        captures+=1
        guard UIApplication.shared.applicationState == .active else {fatalError("Graphics attempted while locked")}
        if shouldCancel(){throw MapProcessingError.cancelled}
        if pause {_ = release.wait(timeout:.now()+5)}
        let bytes=testPacket(f,cx,cy)
        onBaseReady?(bytes)
        return RasterResult(bytes:bytes,tiles:1,fromCache:0)
    }
}
