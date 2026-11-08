import Foundation
func check(_ b:Bool) {precondition(b)}
let root=URL(fileURLWithPath:CommandLine.arguments[1])
let output=root.appendingPathComponent("output/map-edge-bridge/road-multitone-export")
try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
let scenes=["fresh-mingbo/06-mingbo","fresh-default-five/01-dense","fresh-default-five/02-low-density","fresh-default-five/03-diagonal","fresh-default-five/04-interchange","fresh-default-five/05-waterfront"]
var report=[[String:Any]]()
for scene in scenes {
 let folder=root.appendingPathComponent("output/map-edge-bridge/\(scene)")
 let dest=output.appendingPathComponent(String(scene.split(separator:"/").last!))
 try FileManager.default.createDirectory(at:dest,withIntermediateDirectories:true)
 let old=try Data(contentsOf:folder.appendingPathComponent("production-building.bin"))
 check(RasterPacket.valid(old))
 let source=try Data(contentsOf:folder.appendingPathComponent("base-sampled-2m.argb32le"))
 let indices=RoadPalette.classify(source.withUnsafeBytes {Array($0.bindMemory(to:UInt32.self))},w:1200,h:1200)
 let header=[UInt8](old)
 let base=RoadPalette.encode(frameId:RasterPacket.u16(header,0),x0:RasterPacket.i32(header,2),y0:RasterPacket.i32(header,6),w:1200,h:1200,indices:indices)
 var patches=[Int:Data]()
 var patchErrors=[String]()
 for q in 0..<4 {
  do {
   let raw=try Data(contentsOf:folder.appendingPathComponent("building-\(q)-sampled-2m.argb32le"))
   patches[q]=try FastBuildings.simplify(raw.withUnsafeBytes {Array($0.bindMemory(to:UInt32.self))})
  } catch {patchErrors.append("q\(q): \(error)")}
 }
 let built=AmapBuildings.carry(FastBuildings.packet(base:base,patches:patches),known:old)
 check(RasterPacket.valid(built) && RoadPalette.hasRoofs(built))
 let decoded=RasterPacket.decode(built)!
 for p in indices.indices where indices[p]==10 {check(decoded[p]==10)}
 for (name,data) in [("roads.bin",base),("roads.idx",Data(indices)),("building.bin",built),("building.idx",Data(decoded)),("old-building.bin",old),("legacy-building.bin",RoadPalette.forWire(built,paletteVersion:0,buildingsSupported:true)),("legacy-plain.bin",RoadPalette.forWire(built,paletteVersion:0,buildingsSupported:false))] {if name.hasSuffix(".bin") {check(RasterPacket.valid(data));check(data.count<=480000)};try data.write(to:dest.appendingPathComponent(name))}
 check(Array(base.prefix(14))==Array(old.prefix(14)))
 report.append(["scene":scene,"buildingPatchCount":patches.count,"buildingPatchErrors":patchErrors,"buildingOldCarry":true,"roadsBytes":base.count,"buildingBytes":built.count,"oldBuildingBytes":old.count,"legacyBuildingBytes":RoadPalette.forWire(built,paletteVersion:0,buildingsSupported:true).count,"legacyPlainBytes":RoadPalette.forWire(built,paletteVersion:0,buildingsSupported:false).count,"roofPixels":decoded.filter{(4...7).contains($0)}.count,"semantic":RoadPalette.isPacket(built),"hasRoofs":RoadPalette.hasRoofs(built),"flags":RasterPacket.u16(Array(built),14),"oldFlags":RasterPacket.u16(Array(old),14),"framePoseUnchanged":true])
 print("exported \(scene) \(built.count)")
}
try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("swift-export.json"))
