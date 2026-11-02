from pathlib import Path
import subprocess, tempfile
root=Path(__file__).resolve().parents[3]
swift=r'''
import Foundation
final class MapSampleReport {
 static let shared=MapSampleReport()
 func capture(raw:[UInt32],indices:[UInt8],palette:[Int]?=nil,packet:Data,w:Int,h:Int,style:Int) {}
}
enum MapPipelineTrace { static func event(_ name:String,_ fields:[String:Any]) {} }
final class AmapCaptureHost {
 struct Shot {let pixels:[UInt32];let withoutBuildings:[UInt32]?;let width:Int;let height:Int;let left:Double;let top:Double;let right:Double;let bottom:Double;let north:Double;let south:Double}
 static let shared=AmapCaptureHost()
 var sizes=[Int](),calls=[Int](),empty=Set<Int>(),fail:Int?=nil,cancelled=false,active=0,peak=0,cancelAfterShot=false,anomaly=false
 func cancel() {}
 func capture(_ f:MapGeo.Frame,x:Int,y:Int,size:Int,satellite:Bool,style:Int,completion:(Result<Shot,Error>)->Void) {
  sizes.append(size)
  active+=1;peak=max(peak,active);defer{active-=1}
  let i=(y == 1200 ? 0:2)+(x == -1200 ? 0:1);calls.append(i)
  if fail == i { completion(.failure(MapProcessingError.invalid("fake failure")));return }
  var pixels=[UInt32](repeating:0xffeeeeee,count:600*600)
  if !empty.contains(i) { for y in 20..<40 { for x in 20..<40 { pixels[y*600+x]=0xffff00ff } } }
  if anomaly {pixels=[UInt32](repeating:0xffff00ff,count:600*600)}
  if cancelAfterShot {cancelled=true}
  completion(.success(Shot(pixels:pixels,withoutBuildings:nil,width:600,height:600,left:0,top:0,right:600,bottom:600,north:0.001,south:0)))
 }
}
let frame=MapGeo.Frame(refLat:0,refLng:0,id:1)
let base=MapGeo.encodeRaster(frameId:1,x0:-1200,y0:1200,w:1200,h:1200,mmPerPx:2000,idx:[UInt8](repeating:0,count:1200*1200))
let host=AmapCaptureHost.shared
let node=RouteMapPlan.Node(x:0,y:0,distance:0)
func cache()->RouteMapCache { RouteMapCache(root:URL(fileURLWithPath:CommandLine.arguments[1]).appendingPathComponent(UUID().uuidString)) }
func build(_ cache:RouteMapCache,yield:(()->Bool)?=nil,ready:((BuildingUpdate)->Void)?=nil,prepared:Data?=base,onBase:((Data)->Void)?=nil) throws -> RasterResult {
 try AmapSdkRaster.build(frame,cx:0,cy:0,includeBuildings:true,shouldCancel:{host.cancelled},onBaseReady:onBase,preparedBase:prepared,onBuildingReady:ready,shouldYield:yield,cache:cache)
}
func reset(){host.calls=[];host.sizes=[];host.empty=[];host.fail=nil;host.cancelled=false;host.cancelAfterShot=false;host.anomaly=false}
func oldCache(mask:UInt8) throws -> RouteMapCache {
 let root=URL(fileURLWithPath:CommandLine.arguments[1]).appendingPathComponent(UUID().uuidString)
 let folder=root.appendingPathComponent("fast4m-v1-3/0.0_0.0/-1200_1200")
 try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
 let coverage=BuildingCoverage(qualityVersion:1,checkedMask:mask)
 var digestBytes=base;digestBytes.append(contentsOf:"/1/\(mask)".utf8)
 let digest=digestBytes.reduce(UInt64(14695981039346656037)){($0 ^ UInt64($1)) &* 1099511628211}
 struct Saved:Codable {let bytes:Data;let coverage:BuildingCoverage;let checksum:UInt64}
 try JSONEncoder().encode(Saved(bytes:base,coverage:coverage,checksum:digest)).write(to:folder.appendingPathComponent("update.json"))
 return RouteMapCache(root:root)
}
func tests() throws {
 reset();let stalePartial=try oldCache(mask:1)
 do {_=try build(stalePartial,yield:{true},prepared:nil)} catch MapProcessingError.invalid(_) {}
 assert(host.sizes == [1200],"old partial road base must be recaptured before producing v2")
 reset();let staleFull=try oldCache(mask:15)
 var bases=0
 let oldComplete=try build(staleFull,prepared:nil,onBase:{_ in bases += 1})
 assert(bases==0,"legacy fallback must not be published as newly processed base")
 assert(host.sizes.isEmpty && oldComplete.coverage?.qualityVersion==1,"old full update remains usable fallback")

 reset();let c=cache();var callbacks=[Int]()
 let r=try build(c,ready:{_ in callbacks.append(host.calls.count)})
 assert(callbacks == [1,4] && r.coverage!.isComplete && host.calls.count==4 && host.peak==1)
 reset();host.empty=[FastBuildings.order(cx:0,cy:0,view:nil)[0]];callbacks=[]
 _=try build(cache(),ready:{_ in callbacks.append(host.calls.count)})
 assert(callbacks == [2,4])
 reset();host.empty=Set(0..<4);callbacks=[]
 let empty=try build(cache(),ready:{_ in callbacks.append(host.calls.count)})
 assert(callbacks == [4] && empty.coverage!.isComplete && !RasterPacket.isBuilding(empty.bytes))
 reset();callbacks=[]
 let roadsOnly=MapGeo.encodeRaster(frameId:1,x0:-1200,y0:1200,w:1200,h:1200,mmPerPx:2000,idx:[UInt8](repeating:1,count:1440000))
 let clipped=try build(cache(),ready:{_ in callbacks.append(host.calls.count)},prepared:roadsOnly)
 assert(callbacks == [4] && !RasterPacket.isBuilding(clipped.bytes) && clipped.coverage!.isComplete)
 reset();let resumed=cache()
 let partial=try build(resumed,yield:{host.calls.count==1})
 assert(partial.coverage!.checkedMask.nonzeroBitCount==1)
 let before=host.calls[0];host.calls=[]
 host.empty=Set(0..<4);callbacks=[]
 let full=try build(resumed,ready:{_ in callbacks.append(host.calls.count)})
 assert(full.coverage!.isComplete && host.calls.count==3 && !host.calls.contains(before))
 assert(callbacks == [0,3])
 reset();callbacks=[]
 let reused=try build(resumed,ready:{_ in callbacks.append(host.calls.count)})
 assert(host.calls.isEmpty && reused.fromCache==1 && callbacks == [0])
 reset();let invalid=cache();host.anomaly=true
 let bad=try build(invalid)
 assert(bad.coverage?.checkedMask==0 && invalid.buildingCheckpoint(frame:frame,source:3,node:node).coverage.checkedMask==0)
 reset();let failed=cache();host.fail=FastBuildings.order(cx:0,cy:0,view:nil)[1]
 _=try build(failed)
 assert(failed.buildingCheckpoint(frame:frame,source:3,node:node).coverage.checkedMask.nonzeroBitCount==1)
 reset();_=try build(failed);assert(host.calls.count==3)
 reset();host.cancelled=true
 do {_=try build(cache());assert(false)}catch MapProcessingError.cancelled {}
 assert(host.calls.isEmpty)
 reset();let interrupted=cache();host.cancelAfterShot=true
 do {_=try build(interrupted);assert(false)}catch MapProcessingError.cancelled {}
 assert(host.calls.count==1 && interrupted.buildingCheckpoint(frame:frame,source:3,node:node).coverage.checkedMask==0)
 reset();_=try build(interrupted);assert(host.calls.count==4)
 print("PASS capture: first/full callbacks, four pairs, empty completion, yield/resume, failure/resume, cancellation, serial capture")
}
let done=DispatchSemaphore(value:0)
DispatchQueue.global().async { do {try tests()}catch{fatalError("\(error)")};done.signal() }
while done.wait(timeout:.now()) != .success {RunLoop.main.run(until:Date().addingTimeInterval(0.01))}
'''
with tempfile.TemporaryDirectory() as d:
 p=Path(d);(p/'main.swift').write_text(swift)
 sources=['MapGeo','RasterProcessing','RouteMapPlan','MapStyles','SatelliteRaster','AmapSdkRaster']
 subprocess.run(['swiftc','-module-cache-path',str(p/'modules'),'-swift-version','5',*[str(root/'ios/MotoNav'/f'{s}.swift') for s in sources],str(p/'main.swift'),'-o',str(p/'check')],check=True)
 subprocess.run([str(p/'check'),str(p/'cache')],check=True)
