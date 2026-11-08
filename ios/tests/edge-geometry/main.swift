import Foundation
setbuf(stdout, nil)
let output = URL(fileURLWithPath: CommandLine.arguments[1])
func fixture(_ name: String, _ width: Int = 35, _ height: Int = 35, _ sample: (Int,Int)->UInt8) throws {
    let pixels = (0..<height).flatMap { y in (0..<width).map { sample($0,y) } }
    guard let edge = MapEdgeGeometry.build(pixels: pixels, width: width, height: height) else { fatalError(name) }
    try edge.write(to: output.appendingPathComponent(name + ".edge"))
    try Data(pixels).write(to: output.appendingPathComponent(name + ".raw"))
}
try fixture("solid") { _,_ in 2 }
try fixture("vertical") { x,_ in x < 16 ? 0 : 1 }
try fixture("horizontal") { _,y in y < 16 ? 0 : 3 }
try fixture("diagonal") { x,y in x < y ? 2 : 3 }
try fixture("slanted") { x,y in Double(x) * cos(Double.pi/6) + Double(y) * sin(Double.pi/6) < 20 ? 0 : 1 }
try fixture("corner") { x,y in x >= 16 && y >= 16 ? 1 : 0 }
try fixture("courtyard") { x,y in x >= 5 && x < 30 && y >= 5 && y < 30 && !(x >= 12 && x < 23 && y >= 12 && y < 23) ? 1 : 0 }
try fixture("neck") { x,y in (x >= 3 && x < 13 && y >= 8 && y < 27) || (x >= 22 && x < 32 && y >= 8 && y < 27) || (x >= 13 && x < 22 && y == 17) ? 1 : 0 }
try fixture("junction") { x,y in x < 16 ? 0 : y < 16 ? 1 : 2 }
try fixture("building") { x,_ in x < 15 ? 0 : x == 15 ? 5 : 4 }
try fixture("parkbuilding") { x,_ in x < 15 ? 2 : x == 15 ? 7 : 6 }
try fixture("building-road") { x,_ in x < 15 ? 1 : x == 15 ? 5 : 4 }
try fixture("building-water") { x,_ in x < 15 ? 3 : x == 15 ? 5 : 4 }
try fixture("parkbuilding-road") { x,_ in x < 15 ? 1 : x == 15 ? 7 : 6 }
try fixture("parkbuilding-water") { x,_ in x < 15 ? 3 : x == 15 ? 7 : 6 }
try fixture("padding",17,19) { x,_ in x < 16 ? 0 : 1 }
precondition(MapEdgeGeometry.build(pixels: [],width:0,height:1) == nil)
precondition(MapEdgeGeometry.build(pixels: [8],width:1,height:1) == nil)
precondition(MapEdgeGeometry.build(pixels: [0],width:Int.max,height:2) == nil)
precondition(MapEdgeGeometry.build(pixels: [0,1],width:1,height:1) == nil)
precondition(MapEdgeGeometry.build(pixels: [UInt8](repeating:0,count:1616*1616),width:1616,height:1616) == nil)
let dense = (0..<(768*768)).map { UInt8(($0 % 768 / 2) & 1) }
precondition(MapEdgeGeometry.build(pixels:dense,width:768,height:768) == nil)
print("Swift edge fixtures and budget checks passed")

let packetDense = (0..<(512*512)).map { UInt8(($0 % 512 / 2) & 1) }
let compressed = MapEdgeGeometry.build(pixels:packetDense,width:512,height:512)
precondition(compressed != nil && compressed![5] == 1)
try compressed!.write(to: output.appendingPathComponent("compressed.edge"))
try Data(packetDense).write(to: output.appendingPathComponent("compressed.raw"))
for kind in ["solid", "sparse", "dense"] {
    let side = 1200
    let pixels = (0..<(side*side)).map { i -> UInt8 in
        let x = i % side, y = i / side
        if kind == "solid" { return 0 }
        if kind == "sparse" { return x >= 500 && x < 520 || y >= 700 && y < 720 ? 1 : 0 }
        return UInt8((x / 2) & 1)
    }
    let start = ProcessInfo.processInfo.systemUptime
    let edge = MapEdgeGeometry.build(pixels:pixels,width:side,height:side)
    let elapsed = (ProcessInfo.processInfo.systemUptime-start)*1000
    let count = edge.map { data in (0..<4).reduce(UInt32(0)) { $0 | UInt32(data[16+$1]) << ($1*8) } }
    print("1200x1200 \(kind): \(elapsed) ms, edgeCount=\(String(describing: count)), bytes=\(String(describing: edge?.count))")
    if kind == "dense" { precondition(edge == nil) } else { precondition(edge != nil) }
}
func dictionaryFixture(side: Int, dense: Bool) -> [UInt8] {
    var pixels = (0..<(side*side)).map { i -> UInt8 in
        dense && i / side < 250 ? UInt8((i % side / 2) & 1) : 0
    }
    let pairs: [(UInt8,UInt8)] = (0..<7).flatMap { a in ((a+1)..<8).map { (UInt8(a),UInt8($0)) } }
    let columns = side / 4
    let patchRows = (pairs.count * 512 + columns - 1) / columns
    let startY = dense ? side - patchRows * 4 : 0
    for (pairIndex, pair) in pairs.enumerated() { for pattern in 0..<512 {
        let tile = pairIndex * 512 + pattern
        let x = tile % columns * 4, y = startY + tile / columns * 4
        for dy in 0..<3 { for dx in 0..<3 {
            pixels[(y+dy)*side+x+dx] = pattern & (1 << (dy*3+dx)) == 0 ? pair.0 : pair.1
        } }
    } }
    return pixels
}
let rarePixels = dictionaryFixture(side:1000,dense:true)
let rare = MapEdgeGeometry.buildReport(pixels:rarePixels,width:1000,height:1000)
print("dictionary rare fixture:", rare.statistics)
precondition(rare.data != nil && rare.statistics.discardedRareEdges > 0)
precondition(rare.statistics.discardedRareEdges <= rare.statistics.candidateCount / 100)
try rare.data!.write(to: output.appendingPathComponent("dictionary-pruned.edge"))
try Data(rarePixels).write(to: output.appendingPathComponent("dictionary-pruned.raw"))
let refused = MapEdgeGeometry.buildReport(pixels:dictionaryFixture(side:480,dense:false),width:480,height:480,basePacketBytes:450000)
precondition(refused.data == nil && refused.statistics.fallbackReason == "dictionary needs more than 1% rare-edge removal")
let interiors: [UInt8] = (0..<(1200*1200)).map { i in
    let stripe = (i % 1200) / 2
    return UInt8(4 + (stripe & 1))
}
let pruned = MapEdgeGeometry.buildReport(pixels:interiors,width:1200,height:1200)
precondition(pruned.data != nil && pruned.statistics.discardedInteriorEdges == pruned.statistics.candidateCount)
precondition(pruned.statistics.edgeCount == 0)
precondition(MapEdgeGeometry.build(pixels:[0],width:1,height:1,basePacketBytes:479999) == nil)
// Captured before lookup optimization: all ordered material pairs and all binary stencils.
var patterns = Data(), firstPairPackets = Data()
for a in 0..<7 { for b in (a+1)..<8 { for pattern in 0..<512 {
    let pixels = (0..<9).map { UInt8(pattern & (1 << $0) == 0 ? a : b) }
    let packet = MapEdgeGeometry.build(pixels:pixels,width:3,height:3)!
    patterns.append(UInt8(packet.count)); patterns.append(0); patterns.append(packet)
    if a == 0 && b == 1 { firstPairPackets.append(packet) }
} } }
try patterns.write(to: output.appendingPathComponent("patterns.packets"))
try firstPairPackets.write(to: output.appendingPathComponent("pattern-packets.bin"))
