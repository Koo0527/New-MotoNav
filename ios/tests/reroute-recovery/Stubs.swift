// Test boundaries only: production session, tracking and gate are compiled unchanged.
enum AmapShare { struct Fail: LocalizedError { let text:String;init(_ text:String){self.text=text};var errorDescription:String?{text} } }
final class UIApplication {static let shared=UIApplication();var isIdleTimerDisabled=false}
enum MapGeo {static func wgsToGcj(_ lat:Double,_ lng:Double)->(lat:Double,lng:Double){(lat,lng)}}
final class NaviBridge {
    static let shared=NaviBridge();var navigating=false,cruising=false
    func stop(){navigating=false};func stopCruise(){cruising=false}
    static func distM(_ a:Double,_ b:Double,_ c:Double,_ d:Double)->Double{RouteShape.metres(MotorPoint(lat:a,lng:b),MotorPoint(lat:c,lng:d))}
    static func distText(_ metres:Int)->String{String(metres)}
}
final class BleLink {
    static let shared=BleLink();var messages:[String]=[]
    func send(_ text:String){messages.append(text)}
    var images:[Int]=[]
    func sendImage(slot:Int,w:Int,h:Int,data:Data){images.append(slot)}
}
enum TextImage {
    struct Image {let w:Int,h:Int,data:Data}
    static func render(_ text:String,maxW:Int,size:Double,minSize:Double)->Image?{Image(w:1,h:1,data:Data())}
}
final class Speech {
    static let shared=Speech();var spoken:[String]=[],queued:[String]=[]
    func stopNow(){queued=[]}
    func speak(_ text:String){spoken.append(text);queued.append(text)}
}
final class RideRecorder {static let shared=RideRecorder();func start(_ text:String){};func finish(){}}
final class LocationService {static let shared=LocationService();func setPrecise(_ on:Bool){}}
final class MapFeeder {
    static let shared=MapFeeder();var keys:[String]=[]
    func onNaviStart(){};func onNaviEnd(){}
    func prepareRoute(key:String,coords:[(lat:Double,lng:Double)]){keys.append(key)}
    func onLocation(lat:Double,lng:Double,bearing:Double,kmh:Int){}
    func onRoute(key:String,coords:[(lat:Double,lng:Double)],lights:[Int])->Bool{true}
}
final class WebRouteMetadata {
    static let shared=WebRouteMetadata();var current:UUID?
    func stop(){current=nil};func load(_ route:MotorRoute){current=route.id}
    func push(route:MotorRoute,progress:Double,fresh:Bool,speed:Int){}
}
enum MotorRoutes {
    enum Mode {case success,empty,failure,cancelled,suspend}
    static var mode=Mode.success,calls=0,answer:MotorRoute?
    static var waiting:[CheckedContinuation<[MotorRoute],Error>]=[]
    @MainActor static func load(_ request:MotorRequest) async throws -> [MotorRoute] {
        calls+=1
        switch mode {
        case .success:return [answer!]
        case .empty:return []
        case .failure:throw AmapShare.Fail("test network failure")
        case .cancelled:throw CancellationError()
        case .suspend:return try await withCheckedThrowingContinuation{waiting.append($0)}
        }
    }
}

enum MapPipelineTrace {static func event(_ name:String,_ fields:[String:Any]=[:]){}}

final class NavigationCoordinator { static let shared=NavigationCoordinator(); var navigationActive=false }
final class RideBridge { static let shared=RideBridge();var routeReady=false,navigating=false;func stop(){} }
final class Settings { static let shared=Settings();func resetTunnel(){} }
