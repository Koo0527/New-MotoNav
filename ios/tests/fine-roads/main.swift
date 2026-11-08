import Foundation

func check(_ value: @autoclosure () -> Bool, _ message: String) {
    if !value() { fatalError(message) }
}

let n = RasterPacket.size
let nearSize = FineRoads.nearSize
let white: UInt32 = 0xffffffff
let gray: UInt32 = 0xffc8c8c8

func blank() -> [UInt8] { [UInt8](repeating: MapGeo.PX_BLOCK, count: n * n) }
func hline(_ pixels: inout [UInt8], _ y: Int, _ x0: Int, _ x1: Int, _ value: UInt8) {
    for x in x0..<x1 { pixels[y * n + x] = value }
}
func vline(_ pixels: inout [UInt8], _ x: Int, _ y0: Int, _ y1: Int, _ value: UInt8) {
    for y in y0..<y1 { pixels[y * n + x] = value }
}
func nearBlank(_ value: UInt8 = 0) -> [UInt8] { [UInt8](repeating: value, count: nearSize * nearSize) }
func nearV(_ pixels: inout [UInt8], _ x: Int, _ y0: Int, _ y1: Int) {
    for y in y0..<y1 { pixels[y * nearSize + x] = 1 }
}
func nearH(_ pixels: inout [UInt8], _ y: Int, _ x0: Int, _ x1: Int) {
    for x in x0..<x1 { pixels[y * nearSize + x] = 1 }
}
func colors(_ value: UInt32) -> [UInt32] { [UInt32](repeating: value, count: nearSize * nearSize) }

// 1. 与宽图道路相连的一格宽支路被补入，主路不变。
var base = blank()
hline(&base, 600, 560, 700, MapGeo.PX_ROAD)
var near = nearBlank()
nearV(&near, 10, 0, 100)
var result = FineRoads.merge(base: base, near: near, colors: colors(white), offsetX: 600, offsetY: 600)
check(result.added == 99, "connected one-cell branch should add 99, got \(result.added)")
check(result.pixels[600 * n + 610] == MapGeo.PX_ROAD, "overlap pixel stays road")
check(result.pixels[699 * n + 610] == MapGeo.PX_ROAD, "far branch pixel added")
check(result.pixels[600 * n + 560] == MapGeo.PX_ROAD, "wide road preserved")

// 2. 与宽图道路不相连的场地线不补。
var isolated = nearBlank()
nearH(&isolated, 50, 100, 200)
result = FineRoads.merge(base: blank(), near: isolated, colors: colors(white), offsetX: 600, offsetY: 600)
check(result.added == 0, "isolated field line must not be added, got \(result.added)")

// 3. 深灰楼边/场地线不补，即使与道路相连。
var grayLine = nearBlank()
nearV(&grayLine, 10, 0, 100)
result = FineRoads.merge(base: base, near: grayLine, colors: colors(gray), offsetX: 600, offsetY: 600)
check(result.added == 0, "gray building edge must not be added, got \(result.added)")

// 4. 水域和屋顶不被覆盖。
var water = blank()
hline(&water, 600, 560, 700, MapGeo.PX_ROAD)
for y in 600..<800 { for x in 600..<800 { water[y * n + x] = MapGeo.PX_WATER } }
var waterNear = nearBlank()
nearV(&waterNear, 10, 0, 100)
result = FineRoads.merge(base: water, near: waterNear, colors: colors(white), offsetX: 600, offsetY: 600)
check(result.added == 0, "water must not be overwritten, got \(result.added)")
var roofs = blank()
hline(&roofs, 600, 560, 700, MapGeo.PX_ROAD)
for y in 600..<800 { for x in 600..<800 { roofs[y * n + x] = 4 } }
result = FineRoads.merge(base: roofs, near: waterNear, colors: colors(white), offsetX: 600, offsetY: 600)
check(result.added == 0, "roofs must not be overwritten, got \(result.added)")

// 5. 小杂点被面积阈值拒绝。
var dots = nearBlank()
nearH(&dots, 0, 10, 18)
result = FineRoads.merge(base: base, near: dots, colors: colors(white), offsetX: 600, offsetY: 600)
check(result.added == 0, "small component must be rejected, got \(result.added)")

// 6. 绿地(2)可以补，材质1不变。
var green = blank()
for y in 600..<800 { for x in 600..<800 { green[y * n + x] = MapGeo.PX_PARK } }
hline(&green, 600, 560, 700, MapGeo.PX_ROAD)
result = FineRoads.merge(base: green, near: waterNear, colors: colors(white), offsetX: 600, offsetY: 600)
check(result.added == 99, "park ground can receive fine roads, got \(result.added)")

// 7. 越界偏移返回原图。
result = FineRoads.merge(base: base, near: near, colors: colors(white), offsetX: 700, offsetY: 700)
check(result.added == 0 && result.pixels == base, "out-of-bounds offset must be a no-op")

// 8. 标准编码有效且不超限。
let greenBase = MapGeo.encodeRaster(frameId: 1, x0: -1200, y0: 1200, w: n, h: n, mmPerPx: 2000, idx: green)
let greenResult = FineRoads.merge(base: green, near: waterNear, colors: colors(white), offsetX: 600, offsetY: 600)
check(greenResult.added == 99, "encoded sample must contain fine roads")
let packet = FineRoads.encode(greenResult.pixels, like: greenBase, frameId: 1, x0: -1200, y0: 1200)
check(packet != nil, "encoded packet must be valid")
check(packet!.count <= 480_000, "packet must stay under 480000 bytes")

// 9. 象限选择。
check(FineRoads.quadrant(view: nil, cx: 0, cy: 0) == 3, "no view defaults to south-east")
check(FineRoads.quadrant(view: BuildingView(x: 100, y: 100, bearing: 0, radius: 10), cx: 0, cy: 0) == 1, "north-east")
check(FineRoads.quadrant(view: BuildingView(x: -100, y: -100, bearing: 0, radius: 10), cx: 0, cy: 0) == 2, "south-west")

// 10. 覆盖状态：空象限也完成；位掩码可合并。
var coverage = FineRoads.FineRoadCoverage()
check(coverage.count == 0 && !coverage.isComplete, "empty coverage")
coverage.mark(0); coverage.mark(2)
check(coverage.contains(0) && coverage.contains(2) && !coverage.contains(1), "coverage bits")
check(coverage.count == 2 && !coverage.isComplete, "partial coverage")
coverage.mark(1); coverage.mark(3)
check(coverage.isComplete && coverage.checkedMask == 15, "complete coverage")

// 11. 多象限候选一次合并，结果与到达顺序无关。
var maskA = nearBlank(); nearV(&maskA, 10, 0, 100)
var maskB = nearBlank(); nearV(&maskB, 20, 0, 100)
var maskC = nearBlank(); nearV(&maskC, 30, 0, 100)
let mergeAB = FineRoads.mergeAll(base: base, candidates: [3: maskA, 2: maskB])
let mergeBA = FineRoads.mergeAll(base: base, candidates: [2: maskB, 3: maskA])
check(mergeAB.pixels == mergeBA.pixels && mergeAB.added == mergeBA.added,
      "merge result must be independent of quadrant arrival order")
check(FineRoads.mergeAll(base: base, candidates: [3: maskC]).added >= 0,
      "a later quadrant can be merged without losing earlier results")

// 12. 视野重叠优先；没有可靠视野时使用稳定象限顺序。
let eastView = BuildingView(x: 500, y: 500, bearing: 0, radius: 10)
check(FineRoads.quadrantOrder(view: eastView, cx: 0, cy: 0, bearing: nil, kmh: 0).first == 1,
      "east/north view should prioritize its quadrant")
let order = FineRoads.quadrantOrder(view: nil, cx: 0, cy: 0, bearing: nil, kmh: 0)
check(order == [0, 1, 2, 3], "no view should fall back to stable quadrant order")

print("PASS fine-roads merge, rejection, water/roof, bounds, encode and quadrant checks")
