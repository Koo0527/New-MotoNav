import Foundation
let input = URL(fileURLWithPath: CommandLine.arguments[1])
let output = URL(fileURLWithPath: CommandLine.arguments[2])
let size = Int(CommandLine.arguments[3])!
let data = [UInt8](try Data(contentsOf: input))
precondition(size > 0 && data.count == size * size * 4)
let raw = stride(from: 0, to: data.count, by: 4).map { i in
    UInt32(data[i]) | UInt32(data[i+1]) << 8 | UInt32(data[i+2]) << 16 | UInt32(data[i+3]) << 24
}
let bg = MapGeo.backgroundLum(raw)
var cache = [UInt32: UInt8]()
let classified = raw.map { c -> UInt8 in
    if let known = cache[c] { return known }
    let value = MapGeo.classifyPixel(c, bg); cache[c] = value; return value
}
var recovered = classified
MapGeo.recoverGrayRoads(raw, background: bg, into: &recovered, w: size, h: size)
let smoothed = MapGeo.smoothGameRaster(recovered, w: size, h: size)
precondition(smoothed == MapGeo.classifyAmapBase(raw, w: size, h: size, style: 1), "Stage replay differs from production")
for (name, values) in [("classified", classified), ("recovered", recovered), ("smoothed", smoothed)] {
    try Data(values).write(to: output.appendingPathComponent(name + ".idx"))
}
let report: [String: Int] = ["backgroundLum": bg,
    "grayRoadChanges": zip(classified, recovered).filter { $0 != $1 }.count,
    "smoothingChanges": zip(recovered, smoothed).filter { $0 != $1 }.count]
print(String(data: try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), encoding: .utf8)!)
