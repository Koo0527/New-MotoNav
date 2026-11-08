import Foundation
let root=URL(fileURLWithPath:CommandLine.arguments[1])
let out=URL(fileURLWithPath:CommandLine.arguments[2])
var report=[[String:Any]]()
for scene in ["fresh-mingbo/06-mingbo","fresh-default-five/04-interchange"] {
 let source=try Data(contentsOf:root.appendingPathComponent("output/map-edge-bridge/\(scene)/base-sampled-2m.argb32le"))
 let raw=source.withUnsafeBytes{Array($0.bindMemory(to:UInt32.self))}
 let expected=try Data(contentsOf:root.appendingPathComponent("output/map-edge-bridge/road-palette-qa/\(scene.split(separator:"/").last!)/roads.idx"))
 var times=[Double]()
 for _ in 0..<4 {
  let start=DispatchTime.now().uptimeNanoseconds
  let ids=RoadPalette.classify(raw,w:1200,h:1200)
  times.append(Double(DispatchTime.now().uptimeNanoseconds-start)/1e6)
  precondition(Data(ids)==expected,"QA semantic masks stale")
 }
 report.append(["scene":scene,"optimizedProductionSwiftClassifyHostMilliseconds":times])
}
try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:out.appendingPathComponent("swift-host-timing.json"))
