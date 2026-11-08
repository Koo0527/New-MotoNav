// 阶段一宿主验证：OpenFreeMap 矢量瓦片 → CPU 栅格 → 现有地图包。
// 三城市（固定公开样本）× 风格 1-9：生成包 + PNG 对照图 + 有效性断言，
// 输出 summary.json 供 check.py 断言与人工目视检查。
// 用法: vector-map <输出目录>（需联网）
import Foundation
import zlib

let cities: [(name: String, lat: Double, lng: Double)] = [
    ("beijing", 39.9075, 116.3975),
    ("shanghai", 31.2304, 121.4737),
    ("guangzhou", 23.1291, 113.2644),
]
let styles = Array(1...9)

// 目视检查用调色板（材质索引 → RGB；与固件色板无关，仅区分类别）
let debugPalette: [(UInt8, UInt8, UInt8)] = [
    (37, 38, 40),     // 0 地
    (166, 168, 168),  // 1 路
    (70, 105, 80),    // 2 绿
    (60, 100, 140),   // 3 水
    (100, 96, 90),    // 4 屋顶
    (150, 140, 125),  // 5 屋顶边
    (100, 96, 90),    // 6 屋顶
    (150, 140, 125),  // 7 屋顶
    (196, 150, 90),   // 8 暖路(暗)
    (228, 180, 120),  // 9 暖路(亮)
    (60, 60, 64),     // 10 protected
    (255, 220, 160),  // 11 暖路(最亮)
    (255, 0, 255), (255, 0, 255), (255, 0, 255), (255, 0, 255),
]

// MARK: - PNG（RGB8 无滤波，zlib IDAT）

func crc32Tag(_ bytes: [UInt8]) -> UInt32 {
    UInt32(crc32(0, bytes, uInt(bytes.count)))
}

func pngChunk(_ tag: String, _ payload: [UInt8]) -> [UInt8] {
    var out = [UInt8]()
    let n = UInt32(payload.count)
    out.append(UInt8(n >> 24 & 255)); out.append(UInt8(n >> 16 & 255))
    out.append(UInt8(n >> 8 & 255)); out.append(UInt8(n & 255))
    let tagBytes = Array(tag.utf8)
    out.append(contentsOf: tagBytes)
    out.append(contentsOf: payload)
    let crc = crc32Tag(tagBytes + payload)
    out.append(UInt8(crc >> 24 & 255)); out.append(UInt8(crc >> 16 & 255))
    out.append(UInt8(crc >> 8 & 255)); out.append(UInt8(crc & 255))
    return out
}

func writePNG(path: String, materials: [UInt8], width: Int, height: Int) {
    var raw = [UInt8]()
    raw.reserveCapacity(height * (1 + width * 3))
    for y in 0 ..< height {
        raw.append(0)   // filter: None
        let row = y * width
        for x in 0 ..< width {
            let c = debugPalette[Int(materials[row + x] & 15)]
            raw.append(c.0); raw.append(c.1); raw.append(c.2)
        }
    }
    var bound = compressBound(uLong(raw.count))
    var idat = [UInt8](repeating: 0, count: Int(bound))
    let status = raw.withUnsafeBufferPointer { inBuf in
        idat.withUnsafeMutableBufferPointer { outBuf -> Int32 in
            compress2(outBuf.baseAddress, &bound, inBuf.baseAddress, uLong(raw.count), Z_BEST_SPEED)
        }
    }
    precondition(status == Z_OK, "PNG 压缩失败")
    idat.removeSubrange(Int(bound)..<idat.count)

    var png: [UInt8] = [137, 80, 78, 71, 13, 10, 26, 10]
    var ihdr = [UInt8]()
    for shift in [24, 16, 8, 0] { ihdr.append(UInt8(width >> shift & 255)) }
    for shift in [24, 16, 8, 0] { ihdr.append(UInt8(height >> shift & 255)) }
    ihdr.append(contentsOf: [8, 2, 0, 0, 0])
    png.append(contentsOf: pngChunk("IHDR", ihdr))
    png.append(contentsOf: pngChunk("IDAT", idat))
    png.append(contentsOf: pngChunk("IEND", []))
    try? Data(png).write(to: URL(fileURLWithPath: path))
}

// MARK: - 主流程

guard CommandLine.arguments.count >= 2 else {
    FileHandle.standardError.write("用法: vector-map <输出目录>\n".data(using: .utf8)!)
    exit(2)
}
let outDir = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

var summary: [String: Any] = [:]
var rows: [[String: Any]] = []
var hardFailures: [String] = []

let client = VectorTileClient()
do {
    try client.loadTileJSON()
    summary["tileTemplate"] = client.template
    summary["tileVersion"] = client.dataVersion
    if !client.template.contains("{z}") || !client.template.contains("{y}") {
        hardFailures.append("TileJSON 模板缺占位符: \(client.template)")
    }
} catch {
    print("TileJSON 拉取失败: \(error)")
    exit(1)
}

let roadFloor = MapGeo.minMaterialPixels(w: 1200, h: 1200)
summary["roadPixelFloor"] = roadFloor

for (ci, city) in cities.enumerated() {
    let frame = MapGeo.Frame(refLat: city.lat, refLng: city.lng, id: 9101 + ci)
    for style in styles {
        var row: [String: Any] = [
            "city": city.name, "style": style,
        ]
        let t0 = Date()
        do {
            let r = try VectorMapRaster.build(
                client: client, frame: frame,
                centerLat: city.lat, centerLng: city.lng,
                style: style,
                includeBuildings: AmapCapturePolicy.supportsBuildings(style))
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            row["ms"] = ms
            row["tiles"] = r.tiles
            row["tileBytesSum"] = r.bytesIn
            row["roadPixels"] = r.roadPixels
            row["buildingPixels"] = r.buildingPixels
            row["degradedRoads"] = r.degradedRoads
            row["droppedBuildings"] = r.droppedBuildings
            row["baseBytes"] = r.base.count

            let baseValid = RasterPacket.valid(r.base)
            let baseMatches = MapStyleTransfer.matches(r.base, style: style)
            let hasContent = RasterPacket.hasMapContent(r.base)
            row["baseValid"] = baseValid
            row["baseMatches"] = baseMatches
            row["hasContent"] = hasContent
            if !baseValid { hardFailures.append("\(city.name) s\(style): 底图包无效(\(r.base.count)B)") }
            if !baseMatches { hardFailures.append("\(city.name) s\(style): 风格匹配失败") }
            if !hasContent { hardFailures.append("\(city.name) s\(style): 底图无内容") }
            if r.base.count > VectorMapRaster.maxBytes {
                hardFailures.append("\(city.name) s\(style): 底图超限(\(r.base.count)B)")
            }
            if r.roadPixels < roadFloor {
                hardFailures.append("\(city.name) s\(style): 道路像素 \(r.roadPixels) < 阈值 \(roadFloor)")
            }
            if r.degradedRoads {
                hardFailures.append("\(city.name) s\(style): 触发主路降级（480000 降级链不应在城市样本触发）")
            }

            let stem = "\(city.name)-s\(style)"
            if let decoded = RasterPacket.decode(r.base) {
                writePNG(path: outDir.appendingPathComponent("\(stem)-base.png").path,
                         materials: decoded, width: 1200, height: 1200)
                try? r.base.write(to: outDir.appendingPathComponent("\(stem)-base.bin"))
            }
            if let bld = r.buildings {
                row["buildingBytes"] = bld.count
                let bldValid = RasterPacket.valid(bld)
                let bldMatches = MapStyleTransfer.matches(bld, style: style)
                let isBld = RasterPacket.isBuilding(bld)
                row["bldValid"] = bldValid
                row["bldMatches"] = bldMatches
                row["bldIsBuilding"] = isBld
                if !bldValid { hardFailures.append("\(city.name) s\(style): 建筑包无效(\(bld.count)B)") }
                if !bldMatches { hardFailures.append("\(city.name) s\(style): 建筑包风格匹配失败") }
                if !isBld { hardFailures.append("\(city.name) s\(style): 建筑包缺 0x4000/屋顶标志") }
                if let decoded = RasterPacket.decode(bld) {
                    writePNG(path: outDir.appendingPathComponent("\(stem)-bld.png").path,
                             materials: decoded, width: 1200, height: 1200)
                    try? bld.write(to: outDir.appendingPathComponent("\(stem)-bld.bin"))
                }
            }
            let pad = city.name.padding(toLength: 10, withPad: " ", startingAt: 0)
            print("\(pad) s\(String(style).padding(toLength: 2, withPad: " ", startingAt: 0)) \(String(ms).padding(toLength: 5, withPad: " ", startingAt: 0))ms tiles=\(r.tiles) base=\(r.base.count)B roads=\(r.roadPixels) bld=\(r.buildingPixels)\(r.buildings == nil ? "" : " bldPkt=\(r.buildings!.count)")")
        } catch {
            row["error"] = "\(error)"
            hardFailures.append("\(city.name) s\(style): 生成失败 \(error)")
            print("\(city.name) s\(style) FAIL \(error)")
        }
        rows.append(row)
    }
}

summary["rows"] = rows
summary["hardFailures"] = hardFailures
summary["generatedAt"] = ISO8601DateFormatter().string(from: Date())
let json = try! JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys])
try! json.write(to: outDir.appendingPathComponent("summary.json"))

if hardFailures.isEmpty {
    print("PASS: \(rows.count) 组包全部有效")
} else {
    print("FAIL: \(hardFailures.count) 项")
    for f in hardFailures { print("  - \(f)") }
    exit(1)
}
