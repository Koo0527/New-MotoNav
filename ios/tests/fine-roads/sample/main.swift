import Foundation

// Reproduction harness for the accepted Mingbo sample. Reads the archived
// 1200 x 1200 wide grid plus the south-east 600 x 600 near quadrant, runs the
// production FineRoads merge, and writes the enhanced material grid and packets.
let args = CommandLine.arguments
precondition(args.count >= 3, "usage: sample <input-dir> <output-dir>")
let input = URL(fileURLWithPath: args[1])
let output = URL(fileURLWithPath: args[2])
try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

let n = RasterPacket.size
let nearSize = FineRoads.nearSize
let base = [UInt8](try Data(contentsOf: input.appendingPathComponent("base/game.idx")))
let near = [UInt8](try Data(contentsOf: input.appendingPathComponent("near600.idx")))
let colorsData = try Data(contentsOf: input.appendingPathComponent("near600.argb32le"))
precondition(base.count == n * n && near.count == nearSize * nearSize)
precondition(colorsData.count == nearSize * nearSize * 4)
let colors: [UInt32] = colorsData.withUnsafeBytes { Array($0.bindMemory(to: UInt32.self)) }

let started = Date()
let nearIndices = MapGeo.classifyFineRoads(colors, w: nearSize, h: nearSize)
let merged = FineRoads.merge(base: base, near: nearIndices, colors: colors, offsetX: 600, offsetY: 600,
                             window: (740, 830, 930, 1000))
let elapsed = Date().timeIntervalSince(started)

func packet(_ indices: [UInt8]) -> Data {
    RoadPalette.encode(frameId: 1, x0: -1200, y0: 1200, w: n, h: n, indices: indices)
}
let oldPacket = packet(base)
let newPacket = packet(merged.pixels)
precondition(RasterPacket.valid(oldPacket) && RasterPacket.valid(newPacket))

try Data(merged.pixels).write(to: output.appendingPathComponent("enhanced.idx"))
try oldPacket.write(to: output.appendingPathComponent("base.bin"))
try newPacket.write(to: output.appendingPathComponent("enhanced.bin"))

var before = [Int](repeating: 0, count: 16), after = before
for v in base { before[Int(v & 15)] += 1 }
for v in merged.pixels { after[Int(v & 15)] += 1 }
let summary: [String: Any] = [
    "metresPerPixel": 2,
    "quadrant": 3,
    "offsetX": 600,
    "offsetY": 600,
    "added": merged.added,
    "rejected": merged.rejected,
    "elapsedMs": Int(elapsed * 1000),
    "baseBytes": oldPacket.count,
    "enhancedBytes": newPacket.count,
    "deltaBytes": newPacket.count - oldPacket.count,
    "baseMaterials": before,
    "enhancedMaterials": after,
    "valid": RasterPacket.valid(newPacket),
]
let json = try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys])
try json.write(to: output.appendingPathComponent("summary.json"))
print(String(data: json, encoding: .utf8)!)
