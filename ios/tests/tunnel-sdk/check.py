"""Exercise production tunnel SDK adaptation without an SDK, device or user settings."""
from pathlib import Path
import os
import re
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
bridge = (root / "MotoNav/NaviBridge.swift").read_text()
webmotor = (root / "MotoNav/WebMotor.swift").read_text()


def method(source, signature):
    start = source.index(signature)
    opening = source.index("{", start)
    depth = 1
    end = opening + 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start:end]


state = "\n".join(re.findall(
    r"^    private var (?:tunnelRouteKey|tunnelPath|lastTunnelFix)\b[^\n]*", bridge, re.M
))
assert len(state.splitlines()) == 3, "update harness state extraction after bridge changes"
adapter = method(bridge, "private func updateTunnel(").replace("private func", "func", 1)
distance = method(bridge, "static func distM(")
validation = method(webmotor, "static func valid(")

source = r'''
import Foundation
var failures = 0
func check(_ value: Bool, _ message: String) {
    if !value { failures += 1; print("FAIL: \(message)") }
}
// DTOs retain every SDK property read by the production method.
struct Point { var latitude: Double; var longitude: Double }
enum LinkType: Int { case null = -1, normal = 0, fairway = 1, underPass = 2, bridge = 3, elevatedRd = 4, future = 5 }
final class SDKLink {
    var length = 100
    var linkType: LinkType = .normal
    var coordinates: [Point]? = [Point(latitude: 31, longitude: 121), Point(latitude: 31.0005, longitude: 121)]
}
final class SDKSegment { var links: [SDKLink]? = [] }
final class AMapNaviRoute {
    var routeUID = "route-1"
    var routeLength = 500
    var routeSegments: [SDKSegment]? = []
}
final class AMapNaviDriveManager {
    var naviRoute: AMapNaviRoute?
    var naviRouteID = 1
}
final class AMapNaviLocation {
    var timestamp: Date? = Date().addingTimeInterval(-1)
    var accuracy = 5.0
    var isMatchNaviPath = true
    var coordinate: Point? = Point(latitude: 31, longitude: 121)
    var currentSegmentIndex = 0
    var currentLinkIndex = 0
    var currentPointIndex = 0
}
final class Settings {
    static let shared = Settings()
    var samples: [TunnelEvidence] = []
    var policy = TunnelDimmingPolicy()
    var now = 0.0
    func updateTunnel(_ evidence: TunnelEvidence) {
        samples.append(evidence)
        _ = policy.update(evidence, now: now)
    }
}
''' + '\nenum MotorRequest {\n' + validation + '\n}\nfinal class BridgeHarness {\n' + state + '\n' + distance + '\n' + adapter + '\n}\n' + r'''
func fixture(tunnel: Bool = false, nextTunnel: Bool = false) -> (BridgeHarness, AMapNaviLocation, AMapNaviDriveManager, SDKLink) {
    Settings.shared.samples = []
    Settings.shared.policy.reset()
    Settings.shared.now = 0
    let link = SDKLink(); link.linkType = tunnel ? .underPass : .normal
    let segment = SDKSegment(); segment.links = [link]
    if nextTunnel { let next = SDKLink(); next.linkType = .underPass; segment.links!.append(next) }
    let route = AMapNaviRoute(); route.routeSegments = [segment]
    let manager = AMapNaviDriveManager(); manager.naviRoute = route
    return (BridgeHarness(), AMapNaviLocation(), manager, link)
}
func last(_ expected: TunnelEvidence, _ message: String) {
    check(Settings.shared.samples.last == expected, message)
}

do {
    let (bridge, fix, manager, _) = fixture(tunnel: true)
    bridge.updateTunnel(fix, manager: manager)
    last(.inside, "fresh matched current tunnel gives inside")
    let count = Settings.shared.samples.count
    bridge.updateTunnel(fix, manager: manager)
    check(Settings.shared.samples.count == count, "duplicate timestamp emits no second evidence")
    fix.timestamp = fix.timestamp!.addingTimeInterval(-0.1)
    bridge.updateTunnel(fix, manager: manager)
    check(Settings.shared.samples.count == count, "older timestamp emits no evidence")
}
do {
    let (bridge, fix, manager, _) = fixture(nextTunnel: true)
    bridge.updateTunnel(fix, manager: manager)
    last(.approaching, "real geometry within 80m before following tunnel")
}
do {
    let (bridge, fix, manager, link) = fixture(nextTunnel: true)
    link.length = 200
    link.coordinates![1].latitude = 31.001
    bridge.updateTunnel(fix, manager: manager)
    last(.outside, "real geometry farther than 80m stays outside")
}
do {
    let (bridge, fix, manager, link) = fixture(nextTunnel: true)
    link.length = 200
    link.coordinates![1].latitude = 31.001
    fix.currentPointIndex = 1
    bridge.updateTunnel(fix, manager: manager)
    last(.outside, "final point still measures real distance from fix instead of forcing zero")
}
do {
    let (bridge, fix, manager, link) = fixture()
    link.length = 20
    bridge.updateTunnel(fix, manager: manager)
    last(.unknown, "geometry much longer than SDK link cannot give false outside")
}
do {
    let (bridge, fix, manager, _) = fixture()
    bridge.updateTunnel(fix, manager: manager)
    last(.outside, "fresh matched normal link without following tunnel gives outside")
}
// SDK invalid types must hold an existing dim state, including unknown lookahead.
for invalidType in [LinkType.null, .future] {
    for lookahead in [false, true] {
        let (bridge, fix, manager, current) = fixture()
        if lookahead {
            let next = SDKLink(); next.linkType = invalidType
            manager.naviRoute!.routeSegments![0].links!.append(next)
        } else { current.linkType = invalidType }
        Settings.shared.updateTunnel(.inside)
        Settings.shared.now = 1
        Settings.shared.updateTunnel(.outside)
        for time in 2...6 {
            Settings.shared.now = Double(time)
            fix.timestamp = Date().addingTimeInterval(-1 + Double(time) * 0.01)
            bridge.updateTunnel(fix, manager: manager)
            last(.unknown, "invalid SDK type remains unknown for current and lookahead")
            check(Settings.shared.policy.isDimmed, "unknown SDK type cannot confirm exit after three seconds")
        }
        manager.naviRoute!.routeSegments![0].links = [SDKLink()]
        manager.naviRouteID += 1
        for time in 7...10 {
            Settings.shared.now = Double(time)
            fix.timestamp = Date().addingTimeInterval(-1 + Double(time) * 0.01)
            bridge.updateTunnel(fix, manager: manager)
            last(.outside, "valid SDK link restores outside evidence")
            check(Settings.shared.policy.isDimmed == (time < 10), "unknown must cancel the old pending exit timer")
        }
    }
}
for validType in [LinkType.normal, .fairway, .bridge, .elevatedRd] {
    let (bridge, fix, manager, current) = fixture()
    current.linkType = validType
    bridge.updateTunnel(fix, manager: manager)
    last(.outside, "documented non-tunnel SDK types remain valid outside evidence")
}
let invalidFixes: [(String, (AMapNaviLocation) -> Void)] = [
    ("missing timestamp", { $0.timestamp = nil }),
    ("stale timestamp", { $0.timestamp = Date().addingTimeInterval(-6) }),
    ("future timestamp", { $0.timestamp = Date().addingTimeInterval(6) }),
    ("negative accuracy", { $0.accuracy = -1 }),
    ("poor accuracy", { $0.accuracy = 51 }),
    ("NaN accuracy", { $0.accuracy = .nan }),
    ("infinite accuracy", { $0.accuracy = .infinity }),
    ("unmatched path", { $0.isMatchNaviPath = false }),
    ("missing coordinate", { $0.coordinate = nil }),
    ("invalid latitude", { $0.coordinate!.latitude = 91 }),
    ("NaN longitude", { $0.coordinate!.longitude = .nan }),
    ("negative segment", { $0.currentSegmentIndex = -1 }),
    ("missing segment", { $0.currentSegmentIndex = 1 }),
    ("negative link", { $0.currentLinkIndex = -1 }),
    ("missing link", { $0.currentLinkIndex = 1 })
]
for (name, mutate) in invalidFixes {
    let (bridge, fix, manager, _) = fixture(tunnel: true)
    mutate(fix)
    bridge.updateTunnel(fix, manager: manager)
    last(.unknown, name + " must not give positive tunnel evidence")
}
let invalidGeometry: [(String, (AMapNaviLocation, SDKLink) -> Void)] = [
    ("negative point", { fix, _ in fix.currentPointIndex = -1 }),
    ("missing point", { fix, _ in fix.currentPointIndex = 2 }),
    ("nil polyline", { _, link in link.coordinates = nil }),
    ("empty polyline", { _, link in link.coordinates = [] }),
    ("NaN next point", { _, link in link.coordinates![1].latitude = .nan }),
    ("infinite next point", { _, link in link.coordinates![1].longitude = .infinity }),
    ("invalid next latitude", { _, link in link.coordinates![1].latitude = 100 }),
    ("invalid next longitude", { _, link in link.coordinates![1].longitude = 200 })
]
for (name, mutate) in invalidGeometry {
    let (bridge, fix, manager, link) = fixture()
    mutate(fix, link)
    bridge.updateTunnel(fix, manager: manager)
    last(.unknown, name + " must not give false outside")
}
for changedKey in ["id", "uid", "length"] {
    let (bridge, fix, manager, _) = fixture(tunnel: true)
    bridge.updateTunnel(fix, manager: manager)
    last(.inside, "cache initially tunnel")
    let normal = SDKLink()
    manager.naviRoute!.routeSegments![0].links = [normal]
    switch changedKey {
    case "id": manager.naviRouteID += 1
    case "uid": manager.naviRoute!.routeUID = "route-2"
    default: manager.naviRoute!.routeLength += 1
    }
    fix.timestamp = fix.timestamp!.addingTimeInterval(0.1)
    bridge.updateTunnel(fix, manager: manager)
    last(.outside, "changed route " + changedKey + " refreshes cached tunnel links")
    check(Settings.shared.samples.suffix(2).first == .unknown, "route change cancels old confirmation before new evidence")
}
do {
    let (bridge, fix, manager, _) = fixture()
    manager.naviRoute = nil
    bridge.updateTunnel(fix, manager: manager)
    last(.unknown, "missing route cannot produce outside")
}
if failures > 0 { exit(1) }
print("PASS tunnel-sdk: production adapter freshness, path/indices/geometry, repeated fixes, route cache")
'''

with tempfile.TemporaryDirectory(prefix="motonav-tunnel-sdk-") as directory:
    output = Path(directory)
    (output / "main.swift").write_text(source)
    env = dict(os.environ)
    env.setdefault("SWIFT_MODULECACHE_PATH", "/private/tmp/motonav-swift-module-cache")
    env.setdefault("CLANG_MODULE_CACHE_PATH", "/private/tmp/motonav-clang-module-cache")
    subprocess.run(["swiftc", "-warnings-as-errors", str(root / "MotoNav/TunnelDimming.swift"),
                    str(output / "main.swift"), "-o", str(output / "test")], check=True, env=env)
    subprocess.run([str(output / "test")], check=True, env=env)
