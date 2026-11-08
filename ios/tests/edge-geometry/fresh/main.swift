// Offline upper bound: retain original sampled occupancy; no new transport codec.
import Foundation
func compose(_ mask: [UInt8], base: [UInt8], width: Int, height: Int) -> [UInt8] {
    precondition(mask.count == base.count && mask.count == width*height)
    var out=base
    for y in 0..<height { for x in 0..<width {
        let p=y*width+x
        guard mask[p]==1 && (base[p]==0 || base[p]==2) else {continue}
        let edge=x==0 || y==0 || x==width-1 || y==height-1 || mask[p-1]==0 || mask[p+1]==0 || mask[p-width]==0 || mask[p+width]==0
        out[p]=(edge ? 5:4)|(base[p]&2)
    }}
    return out
}
// Small topology/priority self-check on a courtyard, separated buildings and a neck.
var fixture=[UInt8](repeating:0,count:81)
for y in 1...7 {for x in 1...7 {fixture[y*9+x]=1}}
fixture[4*9+4]=0
for y in 0..<9 {fixture[y*9+6]=0}
var testBase=[UInt8](repeating:0,count:81);testBase[10]=1;testBase[11]=3;testBase[12]=2
let tested=compose(fixture,base:testBase,width:9,height:9)
precondition(tested[10]==1 && tested[11]==3 && tested[12]>=6 && tested[40]==0)
precondition((0..<9).allSatisfy {tested[$0*9+6]==0})
// Keep the 4m body outside a two-cell band around the original 3x3 boundary.
// Refuse the experiment if this local repair cannot exactly recover source topology.
func preserveBoundary(_ source:[UInt8], coarse:[UInt8]) -> [UInt8]? {
    var repaired=coarse, boundary=[Int]()
    for y in 0..<600 {for x in 0..<600 {
        let p=y*600+x
        var mixed=false
        for yy in max(0,y-1)...min(599,y+1) {for xx in max(0,x-1)...min(599,x+1) {
            if source[yy*600+xx] != source[p] {mixed=true}
        }}
        if mixed {boundary.append(p)}
    }}
    for p in boundary {let x=p%600,y=p/600
        for yy in max(0,y-2)...min(599,y+2) {for xx in max(0,x-2)...min(599,x+2) {
            repaired[yy*600+xx]=source[yy*600+xx]
        }}
    }
    return repaired==source ? repaired:nil
}
var neck=[UInt8](repeating:0,count:81)
for y in 2...4 {for x in 1...3 {neck[y*9+x]=1};for x in 5...7 {neck[y*9+x]=1}}
neck[3*9+4]=1
let neckResult=compose(neck,base:[UInt8](repeating:0,count:81),width:9,height:9)
precondition(neckResult[3*9+4]>=4 && neckResult[2*9+4]==0 && neckResult[4*9+4]==0)
let args=CommandLine.arguments,folder=args[1],output=args[2]
let inputBase=try Data(contentsOf:URL(fileURLWithPath:folder+"/production-base.bin"))
let base=RasterPacket.decode(inputBase)!
let normalizedBase=MapGeo.encodeRaster(frameId:1,x0:0,y0:0,w:1200,h:1200,mmPerPx:2000,idx:base)
var patches=[Int:Data](),original=[UInt8](repeating:0,count:1440000),tileStats=[[String:Any]]()
var capturedMask=0,rejectedMask=0,candidateValid=true
for q in 0..<4 {
    let path=folder+"/building-\(q)-sampled-2m.argb32le"
    guard FileManager.default.fileExists(atPath:path) else {continue}
    capturedMask |= 1<<q
    let bytes=try Data(contentsOf:URL(fileURLWithPath:path));precondition(bytes.count==600*600*4)
    let raw=bytes.withUnsafeBytes { b in (0..<360000).map {UInt32(littleEndian:b.loadUnaligned(fromByteOffset:$0*4,as:UInt32.self))} }
    let mask=raw.map {AmapBuildings.marked($0) ? UInt8(1):0}
    try Data(mask).write(to:URL(fileURLWithPath:output+"/tile-\(q)-original.mask"))
    let start=ProcessInfo.processInfo.systemUptime
    do { patches[q]=try FastBuildings.simplify(raw) } catch {
        rejectedMask |= 1<<q
        tileStats.append(["quadrant":q,"productionRejected":error.localizedDescription]);continue
    }
    tileStats.append(["quadrant":q,"simplifyMs":(ProcessInfo.processInfo.systemUptime-start)*1000])
    let patch=[UInt8](patches[q]!)
    var coarse=[UInt8](repeating:0,count:360000)
    for y in 0..<600 {for x in 0..<600 {coarse[y*600+x]=patch[(y/2)*300+x/2]}}
    let repairStarted=ProcessInfo.processInfo.systemUptime
    let retained=preserveBoundary(mask,coarse:coarse)
    tileStats[tileStats.count-1]["boundaryRestoresSourceExactly"] = retained != nil
    if retained == nil {candidateValid=false}
    tileStats[tileStats.count-1]["boundaryRepairMs"]=(ProcessInfo.processInfo.systemUptime-repairStarted)*1000
    for y in 0..<600 {for x in 0..<600 {original[(q/2*600+y)*1200+q%2*600+x]=retained?[y*600+x] ?? 0}}
    try patches[q]!.write(to:URL(fileURLWithPath:output+"/tile-\(q)-4m.mask"))
}
let start=ProcessInfo.processInfo.systemUptime
let currentPacket=FastBuildings.packet(base:normalizedBase,patches:patches)
let packetMs=(ProcessInfo.processInfo.systemUptime-start)*1000
let originalComposeStart=ProcessInfo.processInfo.systemUptime
let candidate=compose(original,base:base,width:1200,height:1200)
let candidatePacket=MapGeo.encodeRaster(frameId:1,x0:0,y0:0,w:1200,h:1200,mmPerPx:2000|RasterPacket.flag,idx:candidate)
let composeMs=(ProcessInfo.processInfo.systemUptime-originalComposeStart)*1000
let current=RasterPacket.decode(currentPacket)!
precondition(zip(base,candidate).allSatisfy {b,c in (b != 1 && b != 3) || b==c})
var reports=[[String:Any]]()
var variants=[("current",current,currentPacket)]
if candidateValid {variants.append(("candidate",candidate,candidatePacket))}
for (name,pixels,packet) in variants {
    try Data(pixels).write(to:URL(fileURLWithPath:output+"/\(name).raw"))
    try packet.write(to:URL(fileURLWithPath:output+"/\(name).bin"))
    var runs=[Double](),last:MapEdgeGeometry.Result? = nil
    for _ in 0..<3 {
        let t=ProcessInfo.processInfo.systemUptime
        let result=MapEdgeGeometry.buildReport(pixels:pixels,width:1200,height:1200,basePacketBytes:packet.count)
        runs.append((ProcessInfo.processInfo.systemUptime-t)*1000)
        last=result
    }
    let result=last!
    if let edge=result.data {try edge.write(to:URL(fileURLWithPath:output+"/\(name).edge"))}
    let stats=try JSONSerialization.jsonObject(with:JSONEncoder().encode(result.statistics))
    reports.append(["variant":name,"baseBytes":packet.count,"geometryRunsMs":runs,"statistics":stats,"tailAvailable":result.data != nil])
}
if reports.contains(where: {($0["tailAvailable"] as? Bool)==false}) {
    // Display-only empty EDGE lets the production renderer show nearest fallback.
    let empty=MapEdgeGeometry.build(pixels:[UInt8](repeating:0,count:1440000),width:1200,height:1200)!
    try empty.write(to:URL(fileURLWithPath:output+"/nearest-preview-only.edge"))
}
let acceptedMask=patches.keys.reduce(0) {$0 | (1 << $1)}
var sourceMatchesCurrent:Any=NSNull()
if let captured=try? Data(contentsOf:URL(fileURLWithPath:folder+"/production-building.bin")) {
    sourceMatchesCurrent = captured.dropFirst(16)==currentPacket.dropFirst(16)
}
let report:[String:Any]=["capturedMask":capturedMask,"acceptedMask":acceptedMask,"rejectedMask":rejectedMask,"missingMask":15 ^ capturedMask,"fullFourTileCurrent":acceptedMask==15,"candidateBoundaryValid":candidateValid,"sourceProductionBuildingBodyMatchesCurrent":sourceMatchesCurrent,"tiles":tileStats,"currentPacketMs":packetMs,"candidateComposeAndPacketMs":composeMs,"variants":reports]
print(String(data:try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]),encoding:.utf8)!)
