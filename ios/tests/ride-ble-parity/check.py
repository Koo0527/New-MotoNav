"""Ride BLE wire-format parity vs the drive and independent engines (macOS, no device).

Compiles the production NaviBridge (drive), RideBridge (official ride) and the real
independent session from WebMotor.swift side by side, feeds equivalent SDK guidance
into the drive and ride bridges, and asserts the round-screen messages the ride path
emits are byte-identical to the drive engine's output for the shared families
(turn, #e trip, #v speed, #x gps, #y reroute, #O arrival summary, A,0, and the two
TextImage slots). The independent engine is executed with its real render loop and
compared field-by-field on the same wire grammar.
"""
from pathlib import Path
import os
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
read = lambda name: (root / 'MotoNav' / name).read_text()

arrival = read('ArrivalPolicy.swift')
geo = read('MapGeo.swift')
tunnel = read('TunnelDimming.swift')
idle = read('CruiseIdleTimer.swift')
clock = read('PhoneClockSync.swift')
speeds = read('NavigationSpeed.swift')
history = read('MotorPlanHistory.swift')
shape = read('RouteGeometry.swift')
tracker = read('MotorRouteTracker.swift') + read('MotorReroutePolicy.swift')
drive_callbacks = read('NaviSessionCallbacks.swift')
drive = read('NaviBridge.swift').replace('import UIKit\n', '')
ride = read('RideBridge.swift')

webmotor = read('WebMotor.swift')
core = webmotor[webmotor.index('struct MotorPoint'):webmotor.index('enum MotorRoutes')]
session = webmotor[webmotor.index('/// Independent takeover notices'):webmotor.index('\nfinal class MotorBrowser')]

stubs = r'''
import Foundation
import CoreLocation
import Combine
import ObjectiveC
final class UIImage: NSObject {}
func CreateLaneInfoImageWithLaneInfo(_ back: String, _ select: String) -> UIImage? { UIImage() }
func check(_ condition: Bool, _ message: String) {
    if !condition { print("FAIL: \(message)"); exit(1) }
}
func wait(_ seconds: Double) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }

// ---- 服务边界（记录调用，供字节级输出断言） ----
final class BleLink {
    static let shared = BleLink()
    var sent: [String] = []
    var images: [Int] = []
    func send(_ msg: String) { sent.append(msg) }
    func sendImage(slot: Int, w: Int, h: Int, data: Data) { images.append(slot) }
}
struct Img { let w: Int; let h: Int; let data: Data }
typealias SlotRecord = (slot: Int, text: String, maxW: Int, size: CGFloat, minSize: CGFloat)
func encode(_ s: SlotRecord) -> String { "\(s.slot)|\(s.text)|\(s.maxW)|\(s.size)|\(s.minSize)" }
enum TextImage {
    static var sentSlots: [SlotRecord] = []
    static var rendered: [(text: String, maxW: Int, size: CGFloat, minSize: CGFloat)] = []
    static func send(slot: Int, _ text: String, maxW: Int, size: CGFloat, minSize: CGFloat) {
        sentSlots.append((slot, text, maxW, size, minSize))
    }
    static func render(_ text: String, maxW: Int, size: CGFloat, minSize: CGFloat = 16) -> Img? {
        rendered.append((text, maxW, size, minSize)); return Img(w: 1, h: 1, data: Data())
    }
}
final class Speech {
    static let shared = Speech()
    var spoken: [String] = [], isSpeaking = false
    func speak(_ text: String) { spoken.append(text) }
    func stopNow() {}
}
final class LocationService {
    static let shared = LocationService()
    var location: CLLocation?
    var preciseCalls: [Bool] = []
    func setPrecise(_ on: Bool) { preciseCalls.append(on) }
}
final class RideRecorder {
    static let shared = RideRecorder()
    var started: [String] = [], finished = 0
    func start(_ mode: String) { started.append(mode) }
    func finish() { finished += 1 }
}
final class MapFeeder {
    static let shared = MapFeeder()
    var naviStarts = 0, naviEnds = 0
    var preparedRoutes: [String] = []
    var routeKeys: [String] = []
    var locations: [(lat: Double, lng: Double, bearing: Double, kmh: Int)] = []
    var frame: (id: Int, x: Int, y: Int)?
    func onNaviStart() { naviStarts += 1 }
    func onNaviEnd() { naviEnds += 1 }
    func prepareRoute(key: String, coords: [(lat: Double, lng: Double)]) { preparedRoutes.append(key) }
    func onRoute(key: String, coords: [(lat: Double, lng: Double)], lights: [(lat: Double, lng: Double)]) -> Bool {
        guard coords.count >= 2 else { return false }
        routeKeys.append(key); return true
    }
    func onLocation(lat: Double, lng: Double, bearing: Double, kmh: Int) { locations.append((lat, lng, bearing, kmh)) }
    func toFrame(_ lat: Double, _ lng: Double) -> (x: Int, y: Int)? { nil }
}
final class WebRouteMetadata {
    static let shared = WebRouteMetadata()
    var loads = 0
    func load(_ route: MotorRoute) { loads += 1 }
    func stop() {}
    func push(route: MotorRoute, progress: Double, fresh: Bool, speed: Int) {}
}
final class ShareGuide {
    static let shared = ShareGuide()
    func start(_ share: AmapShare.Route?, avoidHighway: Bool, emulate: Bool, myLat: Double, myLng: Double) {}
    func stop() {}
    func onYaw() {}
    func onLocation(_ lat: Double, _ lng: Double) {}
    func onCalcDone(ok: Bool) {}
}
enum AmapShare {
    struct Fail: Error { let message: String; init(_ m: String) { message = m } }
    struct Route { let kind: String }
    static func waypoints(_ r: Route, myLat: Double, myLng: Double) -> [(lat: Double, lng: Double)] { [] }
    static func match(_ r: Route, sdk: [(lat: Double, lng: Double)], myLat: Double, myLng: Double)
        -> (ratio: Double, bad: Int) { (1, 0) }
}
final class Settings {
    static let shared = Settings()
    var avoidHighway = false
    var tunnelSamples: [TunnelEvidence] = []
    func resetTunnel() {}
    func updateTunnel(_ evidence: TunnelEvidence) { tunnelSamples.append(evidence) }
}
final class UIApplication { static let shared = UIApplication(); var isIdleTimerDisabled = false }
enum MotorRoutes { static func load(_ request: MotorRequest) async throws -> [MotorRoute] { [] } }
extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

// ---- 引擎协调器：固定销毁顺序本身由 tests/nav-coordinator 覆盖；这里给出两个引擎实例 ----
final class NavigationCoordinator {
    static let shared = NavigationCoordinator()
    enum Engine: String, Equatable { case none, drive, ride }
    var active: Engine = .none
    var activateFailure: String?
    var lastFailure: String?
    // The drive bridge reaches its singleton directly; the coordinator stub hands
    // that same instance out so the harness seeds the engine the bridge observes.
    var driveManager: AMapNaviDriveManager { AMapNaviDriveManager.sharedInstance() }
    let rideManager = AMapNaviRideManager()
    var navigationActive: Bool {
        NaviBridge.shared.navigating || RideBridge.shared.navigating || WebMotorSession.shared.running
    }
    func activate(_ target: Engine) -> String? {
        if let f = activateFailure { return f }
        active = target
        return nil
    }
    func deactivateAll() -> String? { active = .none; return nil }
    func driveManagerIfActive() -> AMapNaviDriveManager? { active == .drive ? driveManager : nil }
    func rideManagerIfActive() -> AMapNaviRideManager? { active == .ride ? rideManager : nil }
}

// ---- 高德 SDK 边界（驾车 + 骑行共用一套 DTO） ----
@objc protocol AMapNaviDriveManagerDelegate: AnyObject {}
@objc protocol AMapNaviDriveDataRepresentable: AnyObject {}
@objc protocol AMapNaviRideManagerDelegate: AnyObject {}
@objc protocol AMapNaviRideDataRepresentable: AnyObject {}
enum AMapNaviDrivingStrategy: Int { case multiple = 50 }
func ConvertDrivingPreferenceToDrivingStrategy(_ a: Bool, _ b: Bool, _ c: Bool, _ d: Bool, _ e: Bool)
    -> AMapNaviDrivingStrategy { .multiple }
enum AMapNaviTravelStrategy: Int { case multipleDefault = 1001 }
enum AMapNaviIconType: Int { case leftTurn = 2, straight = 9, destination = 15 }
enum AMapNaviLinkType: Int { case normal = 0, underPass = 2 }
enum AMapNaviDetectedMode: Int { case none = 0, cameraAndSpecialRoad = 3 }
enum AMapNaviCameraType: Int { case electronEye = 0 }
enum AMapNaviRoadFacilityType: Int { case sharpTurn = 3 }
enum AMapNaviTrafficStatusLevel: Int { case smooth = 1 }
final class AMapNaviPoint: NSObject {
    var latitude: CGFloat = 0, longitude: CGFloat = 0
    static func location(withLatitude lat: CGFloat, longitude lng: CGFloat) -> AMapNaviPoint? {
        let p = AMapNaviPoint(); p.latitude = lat; p.longitude = lng; return p
    }
}
final class AMapNaviRouteLabel: NSObject { var content: String = "" }
final class AMapNaviLink: NSObject {
    var length = 100
    var linkType: AMapNaviLinkType = .normal
    var isHadTrafficLights = false
    var coordinates: [AMapNaviPoint] = []
}
final class AMapNaviSegment: NSObject {
    var links: [AMapNaviLink] = []
    var coordinates: [AMapNaviPoint] = []
}
final class AMapNaviRoadFacilityInfo: NSObject {
    var type: AMapNaviRoadFacilityType = .sharpTurn
    var coordinate: AMapNaviPoint?
}
final class AMapNaviRoute: NSObject {
    var routeTime = 0, routeLength = 0, routeUID = 0
    var routeLabels: [AMapNaviRouteLabel]? = []
    var routeCoordinates: [AMapNaviPoint] = []
    var routeSegments: [AMapNaviSegment] = []
    var routeTrafficLights: [AMapNaviPoint]? = []
    var routeTrafficLightCount = 0, routeTollCost = 0
    var roadFacilityInfo: [AMapNaviRoadFacilityInfo]? = []
}
final class AMapNaviRouteGroup: NSObject {
    var naviRouteID: Int = 1
    var naviRoute: AMapNaviRoute?
    var naviRouteIDs: [NSNumber]? = []
    var naviRoutes: [NSNumber: AMapNaviRoute]? = [:]
    var selections: [Int] = []
    func selectNaviRoute(withRouteID id: Int) -> Bool { selections.append(id); return true }
}
final class AMapNaviInfo: NSObject {
    var iconType: AMapNaviIconType = .straight
    var segmentRemainDistance = 0, routeRemainDistance = 0, routeRemainTime = 0
    var currentRoadName: String?, nextRoadName: String?
    var currentSegmentIndex = 0, currentLinkIndex = 0
    var routeRemainTrafficLightCount = 0
}
final class AMapNaviLocation: NSObject {
    var speed = 0
    var heading: Double = 0
    var coordinate: AMapNaviPoint?
    var isMatchNaviPath = true
    var accuracy: Double = 5
    var timestamp: Date? = Date()
    var currentSegmentIndex = 0, currentLinkIndex = 0, currentPointIndex = 0
}
final class AMapNaviCameraInfo: NSObject {
    var cameraType: AMapNaviCameraType = .electronEye
    var cameraSpeed = 0, distance = 0
    var coordinate: AMapNaviPoint?
}
final class AMapNaviSuggestChangeMainNaviRouteInfo: NSObject {
    var backupRoute: AMapNaviRoute?
    var savingTime = 0
}
final class AMapNaviTrafficStatus: NSObject {
    var length = 0
    var status: AMapNaviTrafficStatusLevel = .smooth
}
final class AMapNaviTrafficFacilityInfo: NSObject {
    var boardcastType = 0, limitSpeed = 0, distance = 0
    var coordinate: AMapNaviPoint?
}
final class AMapNaviCruiseInfo: NSObject { var cruisingDriveDistance = 0, cruisingDriveTime = 0 }
final class AMapNaviDriveManager: NSObject {
    weak var delegate: AMapNaviDriveManagerDelegate?
    var representatives: [AMapNaviDriveDataRepresentable] = []
    static var shared: AMapNaviDriveManager?
    static func sharedInstance() -> AMapNaviDriveManager {
        if shared == nil { shared = AMapNaviDriveManager() }
        return shared!
    }
    var isUseInternalTTS: Bool?
    var allowsBackgroundLocationUpdates: Bool?
    var pausesLocationUpdatesAutomatically: Bool?
    var detectedMode: AMapNaviDetectedMode = .none
    var naviRoute: AMapNaviRoute?
    var naviRoutes: [NSNumber: AMapNaviRoute]? = [:]
    var naviRouteIDs: [NSNumber]? = []
    var naviRouteID = 1
    var selections: [Int] = []
    var multipleRouteMode: Bool?
    var updateCameraInfo: Bool?
    var updateTrafficInfo: Bool?
    var stopNaviCalls = 0, pauseCalls = 0, resumeCalls = 0, recalculated = 0
    var emulatorSpeeds: [Int32] = []
    var startedEmulator = 0, startedGPS = 0
    var calculateStart: [AMapNaviPoint]?; var calculateEnd: [AMapNaviPoint]?; var calculateWayPoints: [AMapNaviPoint]?
    func addDataRepresentative(_ r: AMapNaviDriveDataRepresentable) { representatives.append(r) }
    func removeDataRepresentative(_ r: AMapNaviDriveDataRepresentable) { representatives.removeAll { $0 === r } }
    func setMultipleRouteNaviMode(_ on: Bool) { multipleRouteMode = on }
    func calculateDriveRoute(withStart s: [AMapNaviPoint], end e: [AMapNaviPoint],
                             wayPoints w: [AMapNaviPoint], drivingStrategy: AMapNaviDrivingStrategy) -> Bool {
        calculateStart = s; calculateEnd = e; calculateWayPoints = w; return true
    }
    func calculateDriveRoute(withEnd e: [AMapNaviPoint], wayPoints w: [AMapNaviPoint],
                             drivingStrategy: AMapNaviDrivingStrategy) -> Bool {
        calculateStart = nil; calculateEnd = e; calculateWayPoints = w; return true
    }
    func selectNaviRoute(withRouteID id: Int) -> Bool { selections.append(id); return true }
    func stopNavi() { stopNaviCalls += 1 }
    func pauseNavi() { pauseCalls += 1 }
    func resumeNavi() { resumeCalls += 1 }
    func setEmulatorNaviSpeed(_ speed: Int32) { emulatorSpeeds.append(speed) }
    func startEmulatorNavi() -> Bool { startedEmulator += 1; return true }
    func startGPSNavi() -> Bool { startedGPS += 1; return true }
    func getTrafficStatuses() -> [AMapNaviTrafficStatus]? { nil }
}
final class AMapNaviRideManager: NSObject {
    weak var delegate: AMapNaviRideManagerDelegate?
    var representatives: [AMapNaviRideDataRepresentable] = []
    var isUseInternalTTS: Bool?
    var allowsBackgroundLocationUpdates: Bool?
    var pausesLocationUpdatesAutomatically: Bool?
    var naviRoute: AMapNaviRoute?
    var calcStartPOI: AMapNaviPOIInfo?
    var calcEndPOI: AMapNaviPOIInfo?
    var calcStrategy: AMapNaviTravelStrategy?
    var calcCallback: ((AMapNaviRouteGroup?, NSError?) -> Void)?
    var stopNaviCalls = 0, pauseCalls = 0, resumeCalls = 0, recalculated = 0
    var emulatorSpeeds: [Int32] = []
    var startedEmulatorGroups: [AMapNaviRouteGroup] = []
    var startedGPSGroups: [AMapNaviRouteGroup] = []
    func addDataRepresentative(_ r: AMapNaviRideDataRepresentable) { representatives.append(r) }
    func removeDataRepresentative(_ r: AMapNaviRideDataRepresentable) { representatives.removeAll { $0 === r } }
    func independentCalculateRideRoute(withStart s: AMapNaviPOIInfo?, end e: AMapNaviPOIInfo,
                                       strategy: AMapNaviTravelStrategy,
                                       callback: ((AMapNaviRouteGroup?, NSError?) -> Void)?) -> Bool {
        calcStartPOI = s; calcEndPOI = e; calcStrategy = strategy; calcCallback = callback; return true
    }
    func stopNavi() { stopNaviCalls += 1 }
    func pauseNavi() { pauseCalls += 1 }
    func resumeNavi() { resumeCalls += 1 }
    func setEmulatorNaviSpeed(_ speed: Int32) { emulatorSpeeds.append(speed) }
    func startEmulatorNavi(_ group: AMapNaviRouteGroup) -> Bool { startedEmulatorGroups.append(group); return true }
    func startGPSNavi(_ group: AMapNaviRouteGroup) -> Bool { startedGPSGroups.append(group); return true }
    func recalculateRideRoute() -> Bool { recalculated += 1; return true }
}
final class AMapNaviPOIInfo: NSObject { var mid: String?; var locPoint: AMapNaviPoint? }

func makeRoute(id: Int, time: Int, length: Int, label: String) -> AMapNaviRoute {
    let r = AMapNaviRoute(); r.routeTime = time; r.routeLength = length
    let l = AMapNaviRouteLabel(); l.content = label; r.routeLabels = [l]
    let a = AMapNaviPoint.location(withLatitude: 31, longitude: 121)
    let b = AMapNaviPoint.location(withLatitude: 31.01, longitude: 121.01)
    r.routeCoordinates = [a!, b!]
    return r
}
func makeGroup() -> AMapNaviRouteGroup {
    let g = AMapNaviRouteGroup()
    let a = makeRoute(id: 1, time: 600, length: 3000, label: "推荐")
    let b = makeRoute(id: 2, time: 700, length: 2800, label: "少步行")
    g.naviRouteID = 1; g.naviRoute = a
    g.naviRouteIDs = [NSNumber(value: 1), NSNumber(value: 2)]
    g.naviRoutes = [NSNumber(value: 1): a, NSNumber(value: 2): b]
    return g
}
'''

tests = r'''
@main struct Tests {
    @MainActor static func main() {
        UserDefaults.standard.removeObject(forKey: "motor_plan_history_v1")
        let ble = BleLink.shared, feeder = MapFeeder.shared

        // 只比较两个 SDK 引擎共享的线上消息族：转向 / #e / #v / #x / #y / #O / A,0
        func turnFamily(_ msgs: [String]) -> [String] {
            msgs.filter { m in
                guard !m.hasPrefix("#"), m != "A,0", m != "C" else { return false }
                let parts = m.split(separator: ",")
                return m.first?.isLetter == true && Int(parts[1]) != nil
            }
        }
        func tripFamily(_ msgs: [String]) -> [String] { msgs.filter { $0.hasPrefix("#e,") } }
        func speedFamily(_ msgs: [String]) -> [String] { msgs.filter { $0.hasPrefix("#v,") } }
        func gpsFamily(_ msgs: [String]) -> [String] { msgs.filter { $0.hasPrefix("#x,") || $0.hasPrefix("#y,") } }
        func arrivalFamily(_ msgs: [String]) -> [String] {
            msgs.filter { $0.hasPrefix("#O") || $0 == "A,0" }
        }
        func expectedEta(at instant: Date, remainS: Int) -> Int {
            let eta = Calendar.current.date(byAdding: .second, value: remainS, to: instant) ?? instant
            let hh = Calendar.current.component(.hour, from: eta), mm = Calendar.current.component(.minute, from: eta)
            return hh * 100 + mm
        }
        func infoFixture(segment: Int, remain: Int, remainS: Int, road: String, next: String,
                         icon: AMapNaviIconType) -> AMapNaviInfo {
            let n = AMapNaviInfo()
            n.iconType = icon
            n.segmentRemainDistance = segment; n.routeRemainDistance = remain; n.routeRemainTime = remainS
            n.currentRoadName = road; n.nextRoadName = next
            return n
        }
        func locationFixture(_ kmh: Int, _ lat: Double, _ lng: Double) -> AMapNaviLocation {
            let l = AMapNaviLocation(); l.speed = kmh; l.heading = 90
            l.coordinate = AMapNaviPoint.location(withLatitude: CGFloat(lat), longitude: CGFloat(lng))
            return l
        }

        // ---------- 驾车引擎（先完整走一遍，捕获其全部线上输出） ----------
        let drive = NaviBridge.shared
        drive.plan(toLat: 31.2, lng: 121.5)
        let dm = AMapNaviDriveManager.sharedInstance()
        let driveRouteA = makeRoute(id: 1, time: 600, length: 3000, label: "推荐")
        let driveRouteB = makeRoute(id: 2, time: 700, length: 2800, label: "躲避拥堵")
        dm.naviRoutes = [NSNumber(value: 1): driveRouteA, NSNumber(value: 2): driveRouteB]
        dm.naviRouteIDs = [NSNumber(value: 1), NSNumber(value: 2)]
        dm.naviRouteID = 1
        dm.naviRoute = driveRouteA
        drive.mnRouteSuccessOld(dm)
        check(drive.routeReady && drive.routeOptions.count == 2, "drive engine previews both returned routes")
        drive.preferredSimulationSpeed = 60
        drive.start(emulate: true)
        check(drive.navigating && drive.emulating, "drive emulator navigation is armed")

        var from = ble.sent.count, slotFrom = TextImage.sentSlots.count
        let driveInfoAt = Date()
        drive.mnNaviInfo(dm, info: infoFixture(segment: 120, remain: 1500, remainS: 0, road: "测试路", next: "林荫道", icon: .leftTurn))
        let driveTurns = turnFamily(Array(ble.sent[from...]))
        let driveSlots = Array(TextImage.sentSlots[slotFrom...])
        let driveTrips = tripFamily(Array(ble.sent[from...]))
        from = ble.sent.count
        drive.mnNaviInfo(dm, info: infoFixture(segment: 120, remain: 1500, remainS: 0, road: "测试路", next: "林荫道", icon: .leftTurn))
        let driveRepeatTurns = turnFamily(Array(ble.sent[from...]))
        from = ble.sent.count
        drive.mnLocation(dm, location: locationFixture(18, 31.71, 121.99))
        let driveSpeeds1 = speedFamily(Array(ble.sent[from...]))
        from = ble.sent.count
        drive.mnLocation(dm, location: locationFixture(20, 31.72, 121.995))
        let driveSpeeds2 = speedFamily(Array(ble.sent[from...]))
        from = ble.sent.count
        drive.mnGps(dm, strength: 2); drive.mnGps(dm, strength: 2); drive.mnGps(dm, strength: 0)
        let driveGps = gpsFamily(Array(ble.sent[from...]))
        from = ble.sent.count
        drive.mnYaw(dm)
        let driveYawOn = Array(ble.sent[from...]).filter { $0.hasPrefix("#y") }
        from = ble.sent.count
        drive.mnNaviInfo(dm, info: infoFixture(segment: 140, remain: 1500, remainS: 0, road: "测试路", next: "林荫道", icon: .leftTurn))
        let driveYawOff = Array(ble.sent[from...]).filter { $0.hasPrefix("#y") }
        from = ble.sent.count
        drive.mnArrived(dm)
        let driveArrival = arrivalFamily(Array(ble.sent[from...]))
        check(!drive.navigating, "drive finishes its trip")

        // ---------- 骑行引擎（同样的读数序列，捕获其全部线上输出） ----------
        let ride = RideBridge.shared
        ride.plan(toLat: 31.2, lng: 121.5)
        let rm = NavigationCoordinator.shared.rideManager
        rm.calcCallback?(makeGroup(), nil)
        check(ride.routeReady && ride.routeOptions.count == 2, "ride engine previews both returned routes")
        ride.start(emulate: true)
        check(ride.navigating && ride.emulating, "ride emulator navigation is armed")

        from = ble.sent.count; slotFrom = TextImage.sentSlots.count
        let rideInfoAt = Date()
        ride.testNaviInfo(infoFixture(segment: 120, remain: 1500, remainS: 0, road: "测试路", next: "林荫道", icon: .leftTurn))
        let rideTurns = turnFamily(Array(ble.sent[from...]))
        let rideSlots = Array(TextImage.sentSlots[slotFrom...])
        let rideTrips = tripFamily(Array(ble.sent[from...]))
        from = ble.sent.count
        ride.testNaviInfo(infoFixture(segment: 120, remain: 1500, remainS: 0, road: "测试路", next: "林荫道", icon: .leftTurn))
        let rideRepeatTurns = turnFamily(Array(ble.sent[from...]))
        from = ble.sent.count
        ride.testNaviLocation(locationFixture(18, 31.71, 121.99))
        let rideSpeeds1 = speedFamily(Array(ble.sent[from...]))
        from = ble.sent.count
        ride.testNaviLocation(locationFixture(20, 31.72, 121.995))
        let rideSpeeds2 = speedFamily(Array(ble.sent[from...]))
        from = ble.sent.count
        ride.testGps(2); ride.testGps(2); ride.testGps(0)
        let rideGps = gpsFamily(Array(ble.sent[from...]))
        from = ble.sent.count
        ride.testYaw()
        let rideYawOn = Array(ble.sent[from...]).filter { $0.hasPrefix("#y") }
        from = ble.sent.count
        ride.testNaviInfo(infoFixture(segment: 150, remain: 1500, remainS: 0, road: "测试路", next: "林荫道", icon: .leftTurn))
        let rideYawOff = Array(ble.sent[from...]).filter { $0.hasPrefix("#y") }
        from = ble.sent.count
        ride.testArrived()
        let rideArrival = arrivalFamily(Array(ble.sent[from...]))
        check(!ride.navigating, "ride finishes its trip")

        // ---------- 逐族字节对比 ----------
        check(driveTurns == ["L,120"] && rideTurns == ["L,120"],
              "turn guidance is byte-identical for the same SDK info: \(driveTurns) vs \(rideTurns)")
        check(driveRepeatTurns.isEmpty && rideRepeatTurns.isEmpty,
              "identical turn guidance is not re-sent by either engine")
        check(driveSlots.map(encode) == rideSlots.map(encode),
              "road text and ETA footer use the same slots and rendering parameters")
        check(driveSlots.count == 2 && driveSlots[0].slot == 0 && driveSlots[0].text == "进入 林荫道"
              && driveSlots[0].maxW == 290 && driveSlots[0].size == 26 && driveSlots[0].minSize == 18,
              "slot 0 carries the road text with the established parameters")
        check(driveSlots[1].slot == 1 && driveSlots[1].maxW == 240 && driveSlots[1].size == 19
              && driveSlots[1].minSize == 15 && driveSlots[1].text.hasSuffix("到达"),
              "slot 1 carries the distance · ETA footer with the established parameters")
        check(driveSlots[1].text.hasPrefix("1.5km · ") && rideSlots[1].text.hasPrefix("1.5km · "),
              "both engines format the footer distance as 1.5km")
        // #e：字段逐个对齐；ETA 是各自 feed 时刻 + 剩余秒数的到达墙钟（同一分钟内则整串字节一致）
        check(driveTrips.count == 1 && rideTrips.count == 1, "each engine emits exactly one #e trip message")
        let dParts = driveTrips[0].split(separator: ",").map(String.init)
        let rParts = rideTrips[0].split(separator: ",").map(String.init)
        check(dParts.count == 4 && rParts.count == 4 && dParts[0] == "#e" && dParts[1] == "1500"
              && dParts[1] == rParts[1] && dParts[3] == "0" && rParts[3] == "0",
              "#e keeps the four-field layout with the same remaining metres and trailing 0")
        check(Int(dParts[2]) == expectedEta(at: driveInfoAt, remainS: 0)
              && Int(rParts[2]) == expectedEta(at: rideInfoAt, remainS: 0),
              "each engine's #e ETA is its own arrival wall-clock time")
        if Calendar.current.component(.minute, from: driveInfoAt) == Calendar.current.component(.minute, from: rideInfoAt) {
            check(driveTrips[0] == rideTrips[0],
                  "within the same minute the whole #e message is byte-identical: \(driveTrips[0]) vs \(rideTrips[0])")
        }
        check(driveSpeeds1 == ["#v,18"] && rideSpeeds1 == ["#v,18"]
              && driveSpeeds2 == ["#v,20"] && rideSpeeds2 == ["#v,20"],
              "speed follows the byte-identical #v format for both engines")
        check(driveGps == ["#x,1", "#x,0"] && rideGps == ["#x,1", "#x,0"],
              "gps state changes follow the byte-identical #x format without repeats")
        check(driveYawOn == ["#y,1"] && rideYawOn == ["#y,1"], "yaw raises the byte-identical #y,1 flag")
        check(driveYawOff == ["#y,0"] && rideYawOff == ["#y,0"], "fresh guidance lowers the #y flag on both engines")
        check(driveArrival.count == 2 && rideArrival.count == 2,
              "arrival settles exactly once on each engine")
        check(driveArrival == rideArrival,
              "the arrival trip summary and A,0 mark are byte-identical for the same trajectory: \(driveArrival) vs \(rideArrival)")
        check(driveArrival[0] =~ "^#O[0-9]+/1/20$", "the trip summary keeps the #O metres/minutes/maxSpeed fields")
        check(feeder.locations.count == 4, "both engines feed the along-route map with matched positions")

        // ---------- 独立引擎：真实 render 循环 → 同一族线上语法逐字段对比 ----------
        let session = WebMotorSession.shared
        let route = MotorRoute(request: MotorRequest(start: MotorPoint(lat: 30, lng: 104),
                                                     end: MotorPoint(lat: 30.0001, lng: 104.0001), bicycle: true),
                               points: [MotorPoint(lat: 30, lng: 104),
                                        MotorPoint(lat: 30.00005, lng: 104.00005),
                                        MotorPoint(lat: 30.0001, lng: 104.0001)],
                               steps: [MotorStep(instruction: "沿测试路骑行", road: "测试路", action: "直行",
                                                 end: 2, distance: 100)],
                               seconds: 90, detailedGuidance: false)
        // 先给骑行引擎喂入等价读数（直行 100 米、剩余 100 米、车速 60、GPS 正常）
        ride.plan(toLat: 30.001, lng: 104.001)
        let rideGroup = AMapNaviRouteGroup()
        let rideRoute = AMapNaviRoute(); rideRoute.routeTime = 90; rideRoute.routeLength = 100
        let ra = AMapNaviPoint.location(withLatitude: 30, longitude: 104)
        let rb = AMapNaviPoint.location(withLatitude: 30.0001, longitude: 104.0001)
        rideRoute.routeCoordinates = [ra!, rb!]
        rideGroup.naviRouteID = 1; rideGroup.naviRoute = rideRoute
        rideGroup.naviRouteIDs = [NSNumber(value: 1)]
        rideGroup.naviRoutes = [NSNumber(value: 1): rideRoute]
        rm.calcCallback?(rideGroup, nil)
        check(ride.routeReady && ride.selectedRouteID == 1, "the ride engine accepts the equivalent short route")
        ride.start(emulate: true)
        check(ride.navigating, "the equivalent ride navigation is armed")
        let rideFrom = ble.sent.count
        let rideCompareAt = Date()
        ride.testNaviInfo(infoFixture(segment: 100, remain: 100, remainS: 0, road: "测试路", next: "", icon: .straight))
        ride.testNaviLocation(locationFixture(20, 30.00005, 104.00005))   // 自行车模拟档默认 20
        ride.testGps(2); ride.testGps(0)     // #x 只在变化时发：先弱后恢复
        let rideMsgs = Array(ble.sent[rideFrom...])
        ride.stop()
        check(!ride.navigating, "the equivalent ride navigation steps aside for the independent engine")

        // 再启动独立引擎（真实 render 循环，起步同步渲染第一帧）
        let indFrom = ble.sent.count, indSlotFrom = TextImage.rendered.count
        session.start(route, simulate: true)
        let indStartAt = Date()
        check(session.running, "the independent engine starts")
        let indMsgs = Array(ble.sent[indFrom...])
        check(turnFamily(indMsgs).contains("S,100"),
              "the independent engine emits the turn as dir,metres for a straight 100 m step")
        check(turnFamily(rideMsgs).contains("S,100"),
              "ride emits the byte-identical turn for the equivalent straight step")
        check(session.speed == 20, "independent bicycle simulation normalizes to the 20 km/h bicycle gear")
        check(speedFamily(rideMsgs).contains("#v,20") && speedFamily(indMsgs).contains("#v,20"),
              "ride and the independent engine emit the byte-identical #v,20 for the bicycle gear")
        check(rideMsgs.contains("#x,1") && rideMsgs.contains("#x,0") && indMsgs.contains("#x,0"),
              "ride and the independent engine emit the byte-identical #x gps marks")
        let indTrips = tripFamily(indMsgs)
        let rideTrips2 = tripFamily(rideMsgs)
        check(indTrips.contains { $0.split(separator: ",").count == 4 && $0.hasSuffix(",0") },
              "the independent #e keeps the four-field format with the trailing 0")
        check(rideTrips2.contains { $0.split(separator: ",").count == 4 && $0.hasSuffix(",0") },
              "ride's #e has the same field count and trailing 0 as the independent engine's")
        if let indEta = indTrips.first.map({ Int($0.split(separator: ",")[2]) ?? -1 }),
           let rideEta = rideTrips2.first.map({ Int($0.split(separator: ",")[2]) ?? -1 }) {
            check(indEta == expectedEta(at: indStartAt, remainS: 90),
                  "the independent #e ETA is its arrival wall-clock time as HHmm digits: \(indEta)")
            check(rideEta == expectedEta(at: rideCompareAt, remainS: 0),
                  "ride's numeric #e ETA is the same arrival wall-clock encoding for the equivalent input: \(rideEta)")
        } else { check(false, "both engines must produce an #e message for the comparison") }
        let indRendered = TextImage.rendered[indSlotFrom...]
        check(indRendered.contains { $0.maxW == 290 && $0.size == 26 && $0.minSize == 18 },
              "the independent road text uses the same slot-0 rendering parameters")
        check(indRendered.contains { $0.maxW == 240 && $0.size == 19 && $0.minSize == 15 && $0.text.hasSuffix("到达") },
              "the independent footer uses the same slot-1 rendering parameters")
        // 独立引擎的到达也是 #O米/分钟/最高速 + A,0
        var sawIndependentArrival = false
        let deadline = Date().addingTimeInterval(6)
        while Date() < deadline {
            wait(0.2)
            if Array(ble.sent[indFrom...]).contains("A,0") { sawIndependentArrival = true; break }
        }
        let independentAll = Array(ble.sent[indFrom...])
        check(sawIndependentArrival, "the independent engine settles its arrival on the wire")
        check(independentAll.contains { $0 =~ "^#O[0-9]+/[0-9]+/[0-9]+$" },
              "the independent arrival summary keeps the same #O metres/minutes/maxSpeed grammar as ride")
        session.stop(sendCancel: false)
        UserDefaults.standard.removeObject(forKey: "motor_plan_history_v1")
        print("PASS ride BLE parity: ride messages are byte-identical to the drive engine and field-identical to the independent engine")
    }
}
'''


# Test-only hooks so the harness can drive the private ride relay handlers directly.
ride = ride.replace('    fileprivate func onNaviInfo(', '    func testNaviInfo(_ n: AMapNaviInfo?) { onNaviInfo(n) }\n    fileprivate func onNaviInfo(')
ride = ride.replace('    fileprivate func onLocation(', '    func testNaviLocation(_ l: AMapNaviLocation?) { onLocation(l) }\n    fileprivate func onLocation(')
ride = ride.replace('    fileprivate func onGps(', '    func testGps(_ strength: Int) { onGps(strength) }\n    fileprivate func onGps(')
ride = ride.replace('    fileprivate func onYaw()', '    func testYaw() { onYaw() }\n    fileprivate func onYaw()')
ride = ride.replace('    fileprivate func onArrived()', '    func testArrived() { onArrived() }\n    fileprivate func onArrived()')

# A tiny ~= regex helper used by the arrival-summary grammar checks.
helpers = r'''
infix operator =~
func =~ (lhs: String, rhs: String) -> Bool {
    lhs.range(of: rhs, options: .regularExpression) != nil
}
'''

with tempfile.TemporaryDirectory(prefix='motonav-ride-ble-parity-') as tmp:
    swift = Path(tmp) / 'main.swift'
    swift.write_text('enum MapPipelineTrace {static func event(_ name:String,_ fields:[String:Any]=[:]){}}\n' + stubs + arrival + geo + tunnel + idle + clock + speeds + '\n' + history + shape + tracker
                     + drive_callbacks + drive + ride + core + session + helpers + tests)
    env = dict(os.environ, CLANG_MODULE_CACHE_PATH=str(Path(tmp) / 'cache'), SWIFT_MODULECACHE_PATH=str(Path(tmp) / 'cache'))
    subprocess.run(['swiftc', '-parse-as-library', str(swift), '-o', str(Path(tmp) / 'check')], check=True, env=env)
    subprocess.run([str(Path(tmp) / 'check')], check=True, env=env)
