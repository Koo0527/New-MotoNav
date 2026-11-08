import Foundation

/// 高德宽底图的单次局部近景补路。
///
/// 只在当前地图块内选一个 1200 m 象限取一张无建筑近景，把近景中与宽图道路
/// 连通的浅色细路补到宽图的地面(0)/绿地(2)上。主路、材质、水域、屋顶和
/// 建筑完成位图都不改动；补路不参与算路，也不改变通行限制。
enum FineRoads {
    /// 缓存/诊断版本。近景补路结果写在独立缓存文件中，原宽图保留。
    static let version = 2
    static let nearSize = 600
    /// 近景道路到宽图既有道路的最大间距（格，2 m/格）。
    static let joinDistance = 2
    /// 小于此面积的孤立近景道路不参与补路（约 64 m²）。
    static let minimumComponent = 16
    /// 只补浅色细路；更深的灰线多为楼边、场地线或高架路面。
    static let minimumLum = 230
    /// 百分比；白色道路的饱和度接近 0。
    static let maximumSaturation = 14

    struct Result {
        let pixels: [UInt8]
        let added: Int
        let rejected: Int
    }

    /// Per-block fine-road coverage. Empty quadrants are complete too; a packet
    /// containing roads is never used as proof that the other quadrants were seen.
    struct FineRoadCoverage: Codable, Equatable {
        var qualityVersion = FineRoads.version
        var checkedMask: UInt8 = 0
        func contains(_ quadrant: Int) -> Bool {
            (0..<4).contains(quadrant) && checkedMask & (1 << UInt8(quadrant)) != 0
        }
        mutating func mark(_ quadrant: Int) {
            guard (0..<4).contains(quadrant) else { return }
            checkedMask |= 1 << UInt8(quadrant)
        }
        var isComplete: Bool { checkedMask == 0b1111 }
        var count: Int { (0..<4).filter(contains).count }
    }

    struct Update {
        let coverage: FineRoadCoverage
        let pixels: [UInt8]
        let added: Int
        let rejected: Int
        let revision: Int
    }

    /// Stable digest of the original wide packet. Coverage/masks are only valid
    /// for the same base; a different wide capture must not inherit them.
    static func baseDigest(_ data: Data) -> String {
        var hash: UInt64 = 14695981039346656037
        for byte in data { hash = (hash ^ UInt64(byte)) &* 1099511628211 }
        return String(hash, radix: 16)
    }

    /// Color-filtered near-road candidates before component filtering. Keeping
    /// this mask lets a later adjacent quadrant re-evaluate a component that was
    /// previously rejected only because its neighbor was missing.
    static func candidateMask(near: [UInt8], colors: [UInt32]?) -> [UInt8] {
        let count = nearSize * nearSize
        guard near.count == count, colors == nil || colors?.count == count else {
            return [UInt8](repeating: 0, count: count)
        }
        var candidate = [UInt8](repeating: 0, count: count)
        for i in near.indices where near[i] == MapGeo.PX_ROAD {
            if let colors {
                let c = colors[i]
                let r = Int((c >> 16) & 255), g = Int((c >> 8) & 255), b = Int(c & 255)
                let mx = max(r, max(g, b)), mn = min(r, min(g, b))
                let lum = (r * 30 + g * 59 + b * 11) / 100
                let sat = mx == 0 ? 0 : (mx - mn) * 100 / mx
                guard lum >= minimumLum, sat <= maximumSaturation else { continue }
            }
            candidate[i] = 1
        }
        return candidate
    }

    /// Merge all available quadrants in one pass. Components can cross quadrant
    /// seams, and the result is independent of arrival order.
    static func mergeAll(base: [UInt8], candidates: [Int: [UInt8]]) -> Result {
        let width = RasterPacket.size
        guard base.count == width * width else {
            return Result(pixels: base, added: 0, rejected: 0)
        }
        var merged = [UInt8](repeating: 0, count: width * width)
        for (quadrant, mask) in candidates where (0..<4).contains(quadrant) {
            guard mask.count == nearSize * nearSize else { continue }
            let qx = (quadrant % 2) * nearSize, qy = (quadrant / 2) * nearSize
            for y in 0..<nearSize {
                for x in 0..<nearSize where mask[y * nearSize + x] != 0 {
                    merged[(qy + y) * width + qx + x] = 1
                }
            }
        }
        var visited = [UInt8](repeating: 0, count: merged.count)
        var component: [Int] = []
        component.reserveCapacity(512)
        var out = base
        var added = 0, rejected = 0
        base.withUnsafeBufferPointer { b in
            out.withUnsafeMutableBufferPointer { o in
                func touchesRoad(_ bx: Int, _ by: Int) -> Bool {
                    let y0 = max(0, by - joinDistance), y1 = min(width, by + joinDistance + 1)
                    let x0 = max(0, bx - joinDistance), x1 = min(width, bx + joinDistance + 1)
                    for y in y0..<y1 {
                        let row = y * width
                        for x in x0..<x1 where isRoad(b[row + x]) { return true }
                    }
                    return false
                }
                for start in merged.indices where merged[start] == 1 && visited[start] == 0 {
                    component.removeAll(keepingCapacity: true)
                    component.append(start)
                    visited[start] = 1
                    var head = 0, eligible = false
                    while head < component.count {
                        let p = component[head]; head += 1
                        let x = p % width, y = p / width
                        if touchesRoad(x, y) { eligible = true }
                        for dy in -1...1 {
                            let ny = y + dy
                            guard ny >= 0, ny < width else { continue }
                            for dx in -1...1 where dx != 0 || dy != 0 {
                                let nx = x + dx
                                guard nx >= 0, nx < width else { continue }
                                let q = ny * width + nx
                                if merged[q] == 1 && visited[q] == 0 {
                                    visited[q] = 1
                                    component.append(q)
                                }
                            }
                        }
                    }
                    guard component.count >= minimumComponent, eligible else {
                        rejected += component.count
                        continue
                    }
                    for p in component {
                        if b[p] == MapGeo.PX_BLOCK || b[p] == MapGeo.PX_PARK {
                            o[p] = MapGeo.PX_ROAD
                            added += 1
                        }
                    }
                }
            }
        }
        return Result(pixels: out, added: added, rejected: rejected)
    }

    /// 当前视野所在象限；0 左上、1 右上、2 左下、3 右下。
    /// 没有视野时取右下，与已认可的明波样片一致。
    static func quadrant(view: BuildingView?, cx: Double, cy: Double) -> Int {
        guard let view, view.x.isFinite, view.y.isFinite else { return 3 }
        let east = view.x >= cx, north = view.y >= cy
        return (north ? 0 : 2) + (east ? 1 : 0)
    }

    /// 当前视野附近的小补丁窗口（宽图格坐标，右/下不含）：以视野中心为中心，
    /// 默认 384 m 见方，裁剪到所选 1200 m 象限内。没有视野时取象限中心。
    static let windowHalf = 96
    static func viewport(view: BuildingView?, x0: Int, y0: Int, quadrant: Int) -> (Int, Int, Int, Int) {
        let qx = (quadrant % 2) * 600, qy = (quadrant / 2) * 600
        var px = qx + 300, py = qy + 300
        if let view, view.x.isFinite, view.y.isFinite {
            px = Int(((view.x - Double(x0)) / 2).rounded())
            py = Int(((Double(y0) - view.y) / 2).rounded())
        }
        px = min(qx + 600, max(qx, px))
        py = min(qy + 600, max(qy, py))
        return (max(qx, px - windowHalf), max(qy, py - windowHalf),
                min(qx + 600, px + windowHalf), min(qy + 600, py + windowHalf))
    }

    /// Current-view-first, then forward quadrant order. View overlap is scored
    /// above lookahead overlap so a visible quadrant is never skipped for a
    /// merely projected one. Ties use distance and quadrant id for stability.
    static func quadrantOrder(view: BuildingView?, cx: Double, cy: Double,
                              bearing: Double?, kmh: Int) -> [Int] {
        let quadrants: [(Double, Double, Double, Double)] = [
            (cx - 1200, cy, cx, cy + 1200),
            (cx, cy, cx + 1200, cy + 1200),
            (cx - 1200, cy - 1200, cx, cy),
            (cx, cy - 1200, cx + 1200, cy)
        ]
        func overlap(_ r: (Double, Double, Double, Double),
                     _ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double) -> Double {
            max(0, min(r.2, x1) - max(r.0, x0)) * max(0, min(r.3, y1) - max(r.1, y0))
        }
        let current: (Double, Double, Double, Double)? = view.map {
            ($0.x - $0.radius, $0.y - $0.radius, $0.x + $0.radius, $0.y + $0.radius)
        }
        var ahead: (Double, Double, Double, Double)?
        if let view, let bearing, bearing.isFinite, kmh >= 4 {
            let a = bearing * .pi / 180
            let d = max(0, min(450, 1200 - view.radius - 180))
            let x = view.x + sin(a) * d, y = view.y + cos(a) * d
            ahead = (x - view.radius, y - view.radius, x + view.radius, y + view.radius)
        }
        let scored = (0..<4).map { q -> (Int, Double, Double) in
            let ca = current.map { overlap(quadrants[q], $0.0, $0.1, $0.2, $0.3) } ?? 0
            let aa = ahead.map { overlap(quadrants[q], $0.0, $0.1, $0.2, $0.3) } ?? 0
            let d = hypot((quadrants[q].0 + quadrants[q].2) / 2 - (view?.x ?? cx),
                          (quadrants[q].1 + quadrants[q].3) / 2 - (view?.y ?? cy))
            return (q, ca * 1_000_000 + aa, d)
        }
        // A view that overlaps no quadrant must not trigger an off-screen capture.
        let candidates = view == nil ? scored : scored.filter { $0.1 > 0 }
        return candidates.sorted { a, b in
            if a.1 != b.1 { return a.1 > b.1 }
            if a.2 != b.2 { return a.2 < b.2 }
            return a.0 < b.0
        }.map { $0.0 }
    }

    /// - Parameters:
    ///   - base: 1200² 宽图材质（0/1/2/3，风格 1-3 可含 8/9/10/11）
    ///   - near: 近景分类（0/1/2/3），尺寸 nearWidth × nearHeight
    ///   - colors: 同尺寸近景源色 0xRRGGBB，用于排除灰色楼边/场地线；nil 时信任分类
    ///   - offsetX/offsetY: 近景左上角在宽图块内的格偏移
    ///   - window: 只补这个宽图矩形（右/下不含）；nil 时补完整个近景区域
    static func merge(base: [UInt8], near: [UInt8], colors: [UInt32]?,
                      width: Int = RasterPacket.size,
                      nearWidth: Int = nearSize, nearHeight: Int = nearSize,
                      offsetX: Int, offsetY: Int,
                      window: (Int, Int, Int, Int)? = nil) -> Result {
        guard width == RasterPacket.size, base.count == width * width,
              near.count == nearWidth * nearHeight,
              colors == nil || colors?.count == nearWidth * nearHeight,
              offsetX >= 0, offsetY >= 0,
              offsetX + nearWidth <= width, offsetY + nearHeight <= width else {
            return Result(pixels: base, added: 0, rejected: 0)
        }

        // 1. 近景候选：分类为道路，且源色是浅色/低饱和。
        var candidate = [UInt8](repeating: 0, count: nearWidth * nearHeight)
        for i in near.indices where near[i] == MapGeo.PX_ROAD {
            if let colors {
                let c = colors[i]
                let r = Int((c >> 16) & 255), g = Int((c >> 8) & 255), b = Int(c & 255)
                let mx = max(r, max(g, b)), mn = min(r, min(g, b))
                let lum = (r * 30 + g * 59 + b * 11) / 100
                let sat = mx == 0 ? 0 : (mx - mn) * 100 / mx
                guard lum >= minimumLum, sat <= maximumSaturation else { continue }
            }
            candidate[i] = 1
        }

        // 2. 近景道路 8-连通组件；只保留与宽图道路连通且面积足够的组件。
        //    连通判据只检查组件像素周围 joinDistance 格，避免全图膨胀。
        var visited = [UInt8](repeating: 0, count: candidate.count)
        var component: [Int] = []
        component.reserveCapacity(256)
        var added = 0, rejected = 0
        var out = base
        base.withUnsafeBufferPointer { b in
        out.withUnsafeMutableBufferPointer { o in
            func touchesRoad(_ bx: Int, _ by: Int) -> Bool {
                let y0 = max(0, by - joinDistance), y1 = min(width, by + joinDistance + 1)
                let x0 = max(0, bx - joinDistance), x1 = min(width, bx + joinDistance + 1)
                for y in y0..<y1 {
                    let row = y * width
                    for x in x0..<x1 where isRoad(b[row + x]) { return true }
                }
                return false
            }
            for start in candidate.indices where candidate[start] == 1 && visited[start] == 0 {
                component.removeAll(keepingCapacity: true)
                component.append(start)
                visited[start] = 1
                var head = 0, eligible = false
                while head < component.count {
                    let p = component[head]
                    head += 1
                    let x = p % nearWidth, y = p / nearWidth
                    if touchesRoad(offsetX + x, offsetY + y) { eligible = true }
                    for dy in -1...1 {
                        let ny = y + dy
                        guard ny >= 0, ny < nearHeight else { continue }
                        for dx in -1...1 where dx != 0 || dy != 0 {
                            let nx = x + dx
                            guard nx >= 0, nx < nearWidth else { continue }
                            let q = ny * nearWidth + nx
                            if candidate[q] == 1 && visited[q] == 0 {
                                visited[q] = 1
                                component.append(q)
                            }
                        }
                    }
                }
                guard component.count >= minimumComponent, eligible else {
                    rejected += component.count
                    continue
                }
                for p in component {
                    let bx = offsetX + p % nearWidth, by = offsetY + p / nearWidth
                    if let window, !(bx >= window.0 && bx < window.2 && by >= window.1 && by < window.3) { continue }
                    let q = by * width + bx
                    if base[q] == MapGeo.PX_BLOCK || base[q] == MapGeo.PX_PARK {
                        o[q] = MapGeo.PX_ROAD
                        added += 1
                    }
                }
            }
        }
        }
        return Result(pixels: out, added: added, rejected: rejected)
    }

    @inline(__always)
    static func isRoad(_ value: UInt8) -> Bool {
        value == MapGeo.PX_ROAD || value == 8 || value == 9 || value == 11
    }

    /// 近景补路后的底图包；编码失败或超限时返回 nil，调用方保留原宽图。
    static func encode(_ pixels: [UInt8], like base: Data, frameId: Int, x0: Int, y0: Int) -> Data? {
        let packet: Data
        if RoadPalette.isPacket(base) {
            packet = RoadPalette.encode(pixels, like: base)
        } else {
            packet = MapGeo.encodeRaster(frameId: frameId, x0: x0, y0: y0,
                                         w: RasterPacket.size, h: RasterPacket.size, mmPerPx: 2000,
                                         idx: pixels)
        }
        guard packet.count <= 480_000,
              RasterPacket.valid(packet, frame: frameId, x: x0, y: y0) else { return nil }
        return packet
    }
}
