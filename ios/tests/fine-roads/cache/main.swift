import Foundation

func check(_ value: @autoclosure () -> Bool, _ message: String) {
    if !value() { fatalError(message) }
}

let root = FileManager.default.temporaryDirectory.appendingPathComponent("motonav-fine-cache-" + UUID().uuidString)
let cache = RouteMapCache(root: root)
let frame = MapGeo.Frame(refLat: 25.02, refLng: 102.67, id: 7)
let node = RouteMapPlan.Node(x: 0, y: 0, distance: 0)
let n = RasterPacket.size
var base = [UInt8](repeating: MapGeo.PX_BLOCK, count: n * n)
for x in 500..<700 { base[600 * n + x] = MapGeo.PX_ROAD }
var enhanced = base
for y in 601..<700 { enhanced[y * n + 610] = MapGeo.PX_ROAD }
let basePacket = RoadPalette.encode(frameId: frame.id, x0: -1200, y0: 1200, w: n, h: n, indices: base)
let enhancedPacket = RoadPalette.encode(frameId: frame.id, x0: -1200, y0: 1200, w: n, h: n, indices: enhanced)
check(RasterPacket.valid(basePacket) && RasterPacket.valid(enhancedPacket), "sample packets must be valid")
check(RouteMapCache.fineVersion == FineRoads.version, "cache and producer versions must match")

try cache.store(basePacket, frame: frame, source: 3, node: node, style: 1)
try cache.store(enhancedPacket, frame: frame, source: 3, node: node, style: 1, fine: RouteMapCache.fineVersion)
check(cache.read(frame: frame, source: 3, buildings: false, node: node, style: 1) == enhancedPacket,
      "fine packet must be preferred while the original base is retained")
check(cache.covering(frame: frame, source: 3, style: 1, x: 0, y: 0, kmh: 30)?.bytes == enhancedPacket,
      "covering lookup must also prefer the fine packet")

// Coverage and candidate masks travel with the same block/base digest.
let digest = FineRoads.baseDigest(basePacket)
try cache.storeFineState(RouteMapCache.FineState(qualityVersion: FineRoads.version,
    checkedMask: 0b0011, masks: [:], revision: 2, baseDigest: digest),
    frame: frame, source: 3, node: node, style: 1)
let state = cache.readFineState(frame: frame, source: 3, node: node, style: 1, baseDigest: digest)
check(state?.checkedMask == 0b0011 && state?.revision == 2, "fine coverage state roundtrip")
check(cache.readFineState(frame: frame, source: 3, node: node, style: 1, baseDigest: "other") == nil,
      "base digest mismatch must reject coverage")
do {
    try cache.storeFineState(RouteMapCache.FineState(qualityVersion: FineRoads.version,
        checkedMask: 0b0001, masks: [:], revision: 3, baseDigest: digest),
        frame: frame, source: 3, node: node, style: 1)
    check(false, "lower coverage must be rejected")
} catch { }

// Remove only the fine file; the original wide base must still be readable.
var fineURL: URL?
if let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) {
    for case let url as URL in e where url.lastPathComponent.contains("-fine\(RouteMapCache.fineVersion).bin") {
        fineURL = url
    }
}
check(fineURL != nil, "fine cache file must exist")
try FileManager.default.removeItem(at: fineURL!)
check(cache.read(frame: frame, source: 3, buildings: false, node: node, style: 1) == basePacket,
      "original base must remain after the fine file is removed")
try? FileManager.default.removeItem(at: root)
print("PASS fine-road cache: versioned fine file preferred, original base retained")
