import Foundation

/// 阶段一：OpenFreeMap MVT → 1200²×2米/像素 材质索引栅格 → 现有地图包。
///
/// 坐标链（图源入口只转换一次）：瓦片局部整数 → WGS84（Web Mercator 逆变换）
/// → MapGeo.wgsToGcj（与定位、路线一致）→ Frame 米 → 像素。
/// 输出复用现有打包：风格 1-3 直接产 RoadPalette 语义材质索引（道路分色保留），
/// 风格 5 仅 0/1，风格 4/6-9 用普通 0-3 格式；480000 字节上限带降级链。
enum VectorMapRaster {
    static let zoom = 14
    static let size = 1200                 // 与 RasterPacket.size 一致
    static let mpp = 2.0                   // 米/像素
    static let half = 1200.0               // 半边（与 AmapSdkRaster 一致）
    static let maxBytes = 480_000
    static let keepLayers: Set<String> = ["transportation", "building", "water", "waterway", "landcover", "landuse"]

    typealias Pt = (Double, Double)
    typealias Ring = [Pt]
    /// 一个（多）面要素的全部环；偶奇填充处理孔洞。
    typealias Rings = [Ring]

    enum Failure: Error, CustomStringConvertible {
        case unsupportedStyle(Int)
        case noTiles
        case cancelled
        case packetTooLarge(Int)
        var description: String {
            switch self {
            case .unsupportedStyle(let s): return "风格\(s)不走矢量图源"
            case .noTiles: return "未取得任何瓦片"
            case .cancelled: return "已取消"
            case .packetTooLarge(let n): return "降级后仍超上限(\(n)B)"
            }
        }
    }

    struct Result {
        let base: Data                 // 底图包（无建筑）
        let buildings: Data?           // 建筑包（含屋顶索引；仅风格 1-3 且成功时非空）
        let tiles: Int                 // 下载瓦片数
        let bytesIn: Int               // 下载字节数合计
        let roadPixels: Int            // 道路像素数（空区域判据）
        let buildingPixels: Int
        let degradedRoads: Bool        // 主路类别已降级为普通道路
        let droppedBuildings: Bool     // 建筑包超限被丢弃
    }

    // MARK: - 道路分级（宽度固定：高速/干道16、主路12、次路8、普通6、步行3 米）

    enum RoadKind: Int, Comparable {
        case path = 0, minor, secondary, primary, major
        static func < (a: RoadKind, b: RoadKind) -> Bool { a.rawValue < b.rawValue }
        var widthPx: Double {
            switch self {
            case .major: return 16 / mpp
            case .primary: return 12 / mpp
            case .secondary: return 8 / mpp
            case .minor: return 6 / mpp
            case .path: return 3 / mpp
            }
        }
        /// 风格 1-3 语义材质：主路最亮(11)、主/次干道 9、次路 8 由分级写入；普通/步行 1。
        var semanticMaterial: UInt8 {
            switch self {
            case .major: return 11
            case .primary, .secondary: return 9
            case .minor, .path: return 1
            }
        }
        static func from(class cls: String?, subclass: String?) -> RoadKind? {
            let link = (subclass ?? "").hasSuffix("_link")
            var kind: RoadKind
            switch cls ?? "" {
            case "motorway", "trunk": kind = .major
            case "primary": kind = .primary
            case "secondary", "tertiary": kind = .secondary
            case "minor", "service", "raceway", "busway", "bus_guideway": kind = .minor
            case "track", "path", "pedestrian", "footway", "cycleway", "bridleway", "steps": kind = .path
            case "rail", "transit", "ferry", "aerialway": return nil   // 不当普通道路
            default: return nil
            }
            if link {
                switch kind {
                case .major: kind = .primary
                case .primary: kind = .secondary
                case .secondary: kind = .minor
                default: break
                }
            }
            return kind
        }
    }

    // MARK: - 场景（像素坐标）

    private struct Scene {
        var water: [Rings] = []
        var waterways: [(pts: [Pt], widthPx: Double)] = []
        var green: [Rings] = []
        var buildings: [Rings] = []
        var roads: [(kind: RoadKind, pts: [Pt], order: Int)] = []
    }

    private static func orderKey(brunnel: String?, layer: Int) -> Int {
        let b: Int
        switch brunnel ?? "" {
        case "tunnel": b = 0
        case "bridge": b = 2
        default: b = 1
        }
        return b * 100 + (max(-5, min(5, layer)) + 5) * 10
    }

    // MARK: - 主入口（同步；调用方在后台串行队列）

    static func build(client: VectorTileClient,
                      frame: MapGeo.Frame,
                      centerLat: Double, centerLng: Double,
                      style: Int,
                      includeBuildings: Bool,
                      isCancelled: @escaping () -> Bool = { false },
                      onRoadsReady: ((Data) -> Void)? = nil,
                      stageProbe: ((String) -> Void)? = nil) throws -> Result {
        guard (1...9).contains(style) else { throw Failure.unsupportedStyle(style) }
        let semantic = AmapCapturePolicy.supportsBuildings(style)   // 1-3
        let minimal = style == 5
        let cx = frame.x(centerLng), cy = frame.y(centerLat)
        let x0 = Int((cx - half).rounded()), y0 = Int((cy + half).rounded())

        // 块四角（米）→ GCJ 经纬度 → WGS → z14 瓦片范围（floor 各角即覆盖）
        var txMin = Int.max, txMax = Int.min, tyMin = Int.max, tyMax = Int.min
        let n = pow(2.0, Double(zoom))
        let span = 2 * Int(half)
        for corner in [(x0, y0), (x0 + span, y0), (x0, y0 - span), (x0 + span, y0 - span)] {
            let g = MapGeo.gcjToWgs(frame.lat(Double(corner.1)), frame.lng(Double(corner.0)))
            let tx = Int(floor((g.lng + 180.0) / 360.0 * n))
            let latRad = g.lat * .pi / 180.0
            let ty = Int(floor((1.0 - log(tan(latRad) + 1.0 / cos(latRad)) / .pi) / 2.0 * n))
            txMin = min(txMin, tx); txMax = max(txMax, tx)
            tyMin = min(tyMin, ty); tyMax = max(tyMax, ty)
        }

        var scene = Scene()
        var tiles = 0, bytesIn = 0
        for ty in tyMin ... tyMax {
            for tx in txMin ... txMax {
                if isCancelled() { throw Failure.cancelled }
                let data = try client.fetchTile(z: zoom, x: tx, y: ty, shouldCancel: isCancelled)
                bytesIn += data.count
                let tile = try MVTTile.decode(data, keepLayers: keepLayers)
                accumulate(tile, tx: tx, ty: ty, frame: frame, x0: x0, y0: y0, into: &scene)
                tiles += 1
            }
        }
        guard tiles > 0 else { throw Failure.noTiles }

        // 栅格化：水 → 绿（只盖空地）→ 道路；建筑只进 fullGrid 且不覆盖道路/水
        var grid = [UInt8](repeating: 0, count: size * size)
        if !minimal {
            for rings in scene.water { fillPolys(rings, &grid, value: 3) }
            for (pts, width) in scene.waterways {
                stroke(pts, width: width, &grid, value: 3)
            }
            for rings in scene.green { fillPolys(rings, &grid, value: 2, over: [0]) }
        }
        var roadPixels = 0
        for road in scene.roads.sorted(by: { $0.order == $1.order ? $0.kind < $1.kind : $0.order < $1.order }) {
            let v: UInt8 = semantic ? road.kind.semanticMaterial : 1
            roadPixels += stroke(road.pts, width: road.kind.widthPx, &grid, value: v)
        }

        if isCancelled() { throw Failure.cancelled }

        // 打包 + 480000 降级链：底图超限 → 语义主路降级为普通 → 仍超限 → 失败
        var degraded = false
        var basePacket = encode(grid, semantic: semantic, frame: frame, x0: x0, y0: y0)
        if !okPacket(basePacket, frame: frame, x0: x0, y0: y0) {
            if semantic {
                for p in grid.indices where grid[p] == 8 || grid[p] == 9 || grid[p] == 11 { grid[p] = 1 }
                degraded = true
                basePacket = encode(grid, semantic: semantic, frame: frame, x0: x0, y0: y0)
            }
            if !okPacket(basePacket, frame: frame, x0: x0, y0: y0) {
                throw Failure.packetTooLarge(basePacket.count)
            }
        }
        // 道路优先：底图一敲定立即回调（落缓存 + 上屏），建筑处理全部在其后；
        // 建筑失败/取消只影响建筑包，不撤回已交付的道路底图。
        onRoadsReady?(basePacket)
        stageProbe?("roads-encoded")

        // 建筑（仅风格 1-3）：底图拷贝在降级之后进行，保证建筑包与已交付底图一致；
        // 全块掩码 → 边界 → 只画在地(0)/绿(2)上；不覆盖道路。
        var buildingPixels = 0
        var fullGrid = grid
        if semantic, includeBuildings, !scene.buildings.isEmpty, !isCancelled() {
            var mask = [UInt8](repeating: 0, count: size * size)
            for rings in scene.buildings { fillPolys(rings, &mask, value: 1) }
            for py in 0 ..< size {
                for px in 0 ..< size {
                    let p = py * size + px
                    guard mask[p] == 1, fullGrid[p] == 0 || fullGrid[p] == 2 else { continue }
                    let edge = px == 0 || px == size - 1 || py == 0 || py == size - 1
                        || mask[p - 1] == 0 || mask[p + 1] == 0
                        || mask[p - size] == 0 || mask[p + size] == 0
                    fullGrid[p] = edge ? 5 : UInt8(4 | (Int(fullGrid[p]) & 2))
                    buildingPixels += 1
                }
            }
        }
        stageProbe?("buildings-encoded")

        var buildingPacket: Data? = nil
        var droppedBuildings = false
        if buildingPixels > 0 {
            let full = encode(fullGrid, semantic: semantic, frame: frame, x0: x0, y0: y0)
            if okPacket(full, frame: frame, x0: x0, y0: y0) {
                buildingPacket = full
            } else {
                droppedBuildings = true   // 先去除建筑，保留底图
            }
        }

        return Result(base: basePacket, buildings: buildingPacket, tiles: tiles,
                      bytesIn: bytesIn, roadPixels: roadPixels, buildingPixels: buildingPixels,
                      degradedRoads: degraded, droppedBuildings: droppedBuildings)
    }

    private static func okPacket(_ d: Data, frame: MapGeo.Frame, x0: Int, y0: Int) -> Bool {
        d.count > 16 && d.count <= maxBytes && RasterPacket.valid(d, frame: frame.id, x: x0, y: y0)
    }

    private static func encode(_ grid: [UInt8], semantic: Bool, frame: MapGeo.Frame, x0: Int, y0: Int) -> Data {
        if semantic {
            return RoadPalette.encode(frameId: frame.id, x0: x0, y0: y0, w: size, h: size, indices: grid)
        }
        return MapGeo.encodeRaster(frameId: frame.id, x0: x0, y0: y0, w: size, h: size, mmPerPx: 2000, idx: grid)
    }

    // MARK: - 瓦片累积（局部整数 → WGS84 → GCJ → 像素）

    private static func accumulate(_ tile: MVTTile, tx: Int, ty: Int,
                                  frame: MapGeo.Frame, x0: Int, y0: Int,
                                  into scene: inout Scene) {
        let n = pow(2.0, Double(zoom))
        func toPixel(_ gx: Int, _ gy: Int, extent: Int) -> Pt {
            let lon = (Double(tx) + Double(gx) / Double(extent)) / n * 360.0 - 180.0
            let latDeg = atan(sinh(.pi * (1.0 - 2.0 * (Double(ty) + Double(gy) / Double(extent)) / n))) * 180.0 / .pi
            let g = MapGeo.wgsToGcj(latDeg, lon)
            return ((frame.x(g.lng) - Double(x0)) / mpp, (Double(y0) - frame.y(g.lat)) / mpp)
        }
        func conv(_ pts: [(Int, Int)], extent: Int) -> [Pt] {
            pts.map { toPixel($0.0, $0.1, extent: extent) }
        }
        func rings(_ f: MVTTile.Feature, extent: Int) -> Rings {
            f.polygons.map { conv($0, extent: extent) }
        }

        if let water = tile.layers["water"] {
            for f in water.features where f.type == 3 {
                scene.water.append(rings(f, extent: water.extent))
            }
        }
        if let waterway = tile.layers["waterway"] {
            for f in waterway.features where f.type == 2 {
                let cls = waterway.attr(f, "class") ?? ""
                let width: Double
                switch cls {
                case "river": width = 12 / mpp
                case "canal": width = 8 / mpp
                case "stream": width = 4 / mpp
                default: continue
                }
                for line in f.lines { scene.waterways.append((conv(line, extent: waterway.extent), width)) }
            }
        }
        for name in ["landcover", "landuse"] {
            guard let layer = tile.layers[name] else { continue }
            for f in layer.features where f.type == 3 {
                let cls = layer.attr(f, "class") ?? ""
                let isGreen = name == "landcover"
                    ? (cls == "wood" || cls == "grass" || cls == "forest")
                    : (cls == "park")
                guard isGreen else { continue }
                scene.green.append(rings(f, extent: layer.extent))
            }
        }
        if let building = tile.layers["building"] {
            for f in building.features where f.type == 3 {
                scene.buildings.append(rings(f, extent: building.extent))
            }
        }
        if let road = tile.layers["transportation"] {
            for f in road.features where f.type == 2 {
                guard let kind = RoadKind.from(class: road.attr(f, "class"),
                                               subclass: road.attr(f, "subclass")) else { continue }
                let order = orderKey(brunnel: road.attr(f, "brunnel"),
                                     layer: Int(road.attr(f, "layer") ?? "0") ?? 0)
                for line in f.lines { scene.roads.append((kind, conv(line, extent: road.extent), order)) }
            }
        }
    }

    // MARK: - 栅格化（像素中心采样）

    /// 偶奇扫描线填充：rings 为同一要素的全部环（孔洞由偶奇规则处理）。
    /// over 非空时只覆盖列出的现有值。
    private static func fillPolys(_ rings: Rings, _ grid: inout [UInt8],
                                  value: UInt8, over: [UInt8]? = nil) {
        struct Edge { let x0: Double, y0: Double, inv: Double, y1: Double }
        var edges: [Edge] = []
        edges.reserveCapacity(rings.reduce(0) { $0 + $1.count })
        for ring in rings {
            guard ring.count >= 3 else { continue }
            for i in 0 ..< ring.count {
                let a = ring[i], b = ring[(i + 1) % ring.count]
                guard a.1 != b.1 else { continue }   // 水平边跳过
                let (p, q) = a.1 < b.1 ? (a, b) : (b, a)
                edges.append(Edge(x0: p.0, y0: p.1, inv: (q.0 - p.0) / (q.1 - p.1), y1: q.1))
            }
        }
        guard edges.count >= 2 else { return }
        let overSet = over.map(Set.init)
        for py in 0 ..< size {
            let y = Double(py) + 0.5
            var xs = [Double]()
            xs.reserveCapacity(8)
            for e in edges where e.y0 <= y && y < e.y1 {
                xs.append(e.x0 + (y - e.y0) * e.inv)
            }
            guard xs.count >= 2 else { continue }
            xs.sort()
            let row = py * size
            var i = 0
            while i + 1 < xs.count {
                let lo = xs[i], hi = xs[i + 1]
                i += 2
                let pLo = max(0, Int(floor(lo - 0.5))), pHi = min(size - 1, Int(ceil(hi)))
                if pLo > pHi { continue }
                for px in pLo ... pHi {
                    let c = Double(px) + 0.5
                    guard c >= lo && c < hi else { continue }
                    let p = row + px
                    if let allowed = overSet, !allowed.contains(grid[p]) { continue }
                    grid[p] = value
                }
            }
        }
    }

    /// 折线描边：逐段 bbox 内像素中心到线段距离 ≤ 半宽（圆头）。
    /// 返回本次新写入（像素值变化）的次数，作道路量级指示。
    @discardableResult
    private static func stroke(_ pts: [Pt], width: Double,
                               _ grid: inout [UInt8], value: UInt8) -> Int {
        guard pts.count >= 2, width > 0 else { return 0 }
        let r = width / 2, r2 = r * r
        var written = 0
        for i in 0 ..< (pts.count - 1) {
            let ax = pts[i].0, ay = pts[i].1, bx = pts[i + 1].0, by = pts[i + 1].1
            let loX = max(0, Int(floor(min(ax, bx) - r - 0.5)))
            let hiX = min(size - 1, Int(ceil(max(ax, bx) + r + 0.5)))
            let loY = max(0, Int(floor(min(ay, by) - r - 0.5)))
            let hiY = min(size - 1, Int(ceil(max(ay, by) + r + 0.5)))
            guard loX <= hiX, loY <= hiY else { continue }
            let dx = bx - ax, dy = by - ay
            let len2 = dx * dx + dy * dy
            for py in loY ... hiY {
                let y = Double(py) + 0.5
                let row = py * size
                for px in loX ... hiX {
                    let x = Double(px) + 0.5
                    let t: Double = len2 < 1e-12 ? 0
                        : max(0, min(1, ((x - ax) * dx + (y - ay) * dy) / len2))
                    let ex = x - (ax + t * dx), ey = y - (ay + t * dy)
                    if ex * ex + ey * ey <= r2 {
                        let p = row + px
                        if grid[p] != value { grid[p] = value; written += 1 }
                    }
                }
            }
        }
        return written
    }
}
