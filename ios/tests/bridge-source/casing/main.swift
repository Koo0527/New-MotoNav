import Foundation
let n=Int(CommandLine.arguments[3])!
let bytes=[UInt8](try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
precondition(bytes.count == n*n*4)
let raw=stride(from:0,to:bytes.count,by:4).map { i in UInt32(bytes[i]) | UInt32(bytes[i+1])<<8 | UInt32(bytes[i+2])<<16 | UInt32(bytes[i+3])<<24 }
let out=URL(fileURLWithPath:CommandLine.arguments[2])
_ = MapGeo.smoothGameRaster([1,1,1,1,0,1,1,1,1],w:3,h:3)
let start=Date()
let baseline=MapGeo.classifyAmapBase(raw,w:n,h:n,style:2)
let baseMS=Date().timeIntervalSince(start)*1000
try Data(baseline).write(to:out.appendingPathComponent("baseline.idx"))
var report:[String:Any]=["baselineMS":baseMS]
for (name,local) in [("color",false),("local",true)] {
    let t=Date(), mask=MapGeo.sourceCasing(raw,w:n,h:n,local:local)
    let detectMS=Date().timeIntervalSince(t)*1000
    let pipelineT=Date()
    let bg=MapGeo.backgroundLum(raw)
    var cache=[UInt32:UInt8]()
    var classified=raw.map { c -> UInt8 in
        if let v=cache[c] {return v}; let v=MapGeo.classifyPixel(c,bg);cache[c]=v;return v
    }
    for p in mask.indices where mask[p] != 0 {classified[p]=0}
    var recovered=classified
    MapGeo.recoverGrayRoads(raw,background:bg,into:&recovered,w:n,h:n)
    let final=MapGeo.smoothGameRaster(recovered,w:n,h:n,protected:mask)
    let pipelineMS=detectMS+Date().timeIntervalSince(pipelineT)*1000
    let unprotected=MapGeo.smoothGameRaster(recovered,w:n,h:n)
    precondition(final.allSatisfy {$0<=3})
    precondition(mask.indices.allSatisfy {mask[$0] == 0 || final[$0] == 0})
    for (stage,values) in [("mask",mask),("classified",classified),("recovered",recovered),("unprotected",unprotected),("final",final)] {
        try Data(values).write(to:out.appendingPathComponent(name+"-"+stage+".idx"))
    }
    if CommandLine.arguments.count > 4 {
        let scene=URL(fileURLWithPath:CommandLine.arguments[4])
        var patches=[Int:Data]()
        for q in 0..<4 {
            let b=[UInt8](try Data(contentsOf:scene.appendingPathComponent("building-\(q)-sampled-2m.argb32le")))
            let tile=stride(from:0,to:b.count,by:4).map {i in UInt32(b[i]) | UInt32(b[i+1])<<8 | UInt32(b[i+2])<<16 | UInt32(b[i+3])<<24}
            patches[q]=try FastBuildings.simplify(tile)
            try patches[q]!.write(to:out.appendingPathComponent("building-\(q).mask"))
        }
        let base=MapGeo.encodeRaster(frameId:1,x0:-1200,y0:1200,w:n,h:n,mmPerPx:2000,idx:final)
        let packet=FastBuildings.packet(base:base,patches:patches)
        precondition(RasterPacket.valid(packet))
        let built=RasterPacket.decode(packet)!
        try Data(built).write(to:out.appendingPathComponent(name+"-buildingfull.idx"))
        try packet.write(to:out.appendingPathComponent(name+"-buildingfull.bin"))
        let overwritten=mask.indices.filter {mask[$0] != 0 && built[$0] >= 4}
        report[name+"BuildingOverlay"]=["overwrittenCasing":overwritten.count,"examples":Array(overwritten.prefix(12)).map{[$0%n,$0/n]},"roofPixels":built.filter{$0>=4}.count]
    }
    report[name]=["detectMS":detectMS,"pipelineComputeMS":pipelineMS,
        "marked":mask.filter{$0 != 0}.count,"swallowedWithoutProtection":mask.indices.filter{mask[$0] != 0 && unprotected[$0] == 1}.count,
        "roadBefore":baseline.filter{$0 == 1}.count,"roadAfter":final.filter{$0 == 1}.count]
}
// A flat dark road must survive; white/gray roads must never become warm casing.
for c:UInt32 in [0xffdeA652,0xffb4b4b4,0xffffffff,0xfff7df84] {
    let flat=[UInt32](repeating:c,count:49)
    precondition(MapGeo.sourceCasing(flat,w:7,h:7,local:true).allSatisfy{$0 == 0})
}
// Thin observed warm line is eligible; an absent line is never synthesized.
var synthetic=[UInt32](repeating:0xfff7c36b,count:81)
for x in 1...7 {synthetic[4*9+x]=0xffdea652}
let mask=MapGeo.sourceCasing(synthetic,w:9,h:9,local:true)
precondition(mask[4*9+4] == 1 && mask[3*9+4] == 0)
print(String(data:try JSONSerialization.data(withJSONObject:report,options:[.sortedKeys]),encoding:.utf8)!)
