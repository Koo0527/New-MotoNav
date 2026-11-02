from pathlib import Path
import subprocess,tempfile
root=Path(__file__).resolve().parents[3]
main=r'''
import Foundation
func require(_ value:Bool){precondition(value)}
let root=URL(fileURLWithPath:CommandLine.arguments[1]);let cache=RouteMapCache(root:root)
let f=MapGeo.Frame(refLat:30,refLng:120,id:1),node=RouteMapPlan.Node(x:0,y:0,distance:0)
func write(_ data:Data,_ path:String)throws {let p=root.appendingPathComponent(path);try FileManager.default.createDirectory(at:p.deletingLastPathComponent(),withIntermediateDirectories:true);try data.write(to:p)}
func checksum(_ data:Data)->UInt64 {data.reduce(UInt64(14695981039346656037)){($0 ^ UInt64($1)) &* 1099511628211}}
var old=Data(repeating:0,count:90000)
for y in 20..<26 {for x in 20..<26 {old[y*300+x]=1}}
old[19*300+22]=1;old[5*300]=1
var patch=old,digest=checksum(old).littleEndian
withUnsafeBytes(of:&digest){patch.append(contentsOf:$0)}
let oldFolder="fast4m-v1-3/30.0_120.0/-1200_1200/"
try write(patch,oldFolder+"patch-0")
let c=cache.buildingCheckpoint(frame:f,source:3,node:node)
require(c.coverage.qualityVersion==2 && c.coverage.checkedMask==1)
require(c.patches[0]![19*300+22]==0 && c.patches[0]![5*300]==1)
require(try Data(contentsOf:root.appendingPathComponent(oldFolder+"patch-0"))==patch)
let currentFolder="fast4m-v2-3/30.0_120.0/-1200_1200/"
let migrated=root.appendingPathComponent(currentFolder+"patch-0")
let before=try Data(contentsOf:migrated)
require(cache.buildingCheckpoint(frame:f,source:3,node:node).patches[0]==c.patches[0])
require(try Data(contentsOf:migrated)==before)
var pixels=[UInt8](repeating:0,count:1440000);for i in 0..<1200 {pixels[1200+i]=1};pixels[50*1200+50]=5
let roof=MapGeo.encodeRaster(frameId:1,x0:-1200,y0:1200,w:1200,h:1200,mmPerPx:2000|RasterPacket.flag,idx:pixels)
let cov=BuildingCoverage(qualityVersion:1,checkedMask:15)
struct Saved:Codable {let bytes:Data;let coverage:BuildingCoverage;let checksum:UInt64}
var hashed=roof;hashed.append(contentsOf:"/1/15".utf8)
try write(JSONEncoder().encode(Saved(bytes:roof,coverage:cov,checksum:checksum(hashed))),oldFolder+"update.json")
require(cache.buildingUpdate(frame:f,source:3,node:node,style:3)?.coverage==cov)
try cache.storeBuildingUpdate(BuildingUpdate(bytes:roof,coverage:BuildingCoverage(checkedMask:1)),frame:f,source:3,node:node)
require(cache.buildingUpdate(frame:f,source:3,node:node,style:2)?.coverage.isComplete==true)
try cache.storeBuildingUpdate(BuildingUpdate(bytes:roof,coverage:BuildingCoverage(checkedMask:15)),frame:f,source:3,node:node)
require(cache.buildingUpdate(frame:f,source:3,node:node,style:1)?.coverage.qualityVersion==2)
try write(Data("broken".utf8),currentFolder+"update.json")
require(cache.buildingUpdate(frame:f,source:3,node:node,style:1)?.coverage==cov)
let base=MapDeliveryPolicy.compactBase(roof)
try write(base,"styles-v3-1/v1-3-base/30.0_120.0/0_0.bin")
require(cache.read(frame:f,source:3,buildings:false,node:node,style:1)==base)
require(cache.read(frame:f,source:3,buildings:false,node:node,style:1,allowLegacy:false)==nil)
try cache.store(base,frame:f,source:3,node:node,style:1)
require(FileManager.default.fileExists(atPath:root.appendingPathComponent("styles-v3-1/v1-3-base/30.0_120.0/0_0.bin").path))
require(FileManager.default.fileExists(atPath:root.appendingPathComponent("materials-v2-1/v1-3-base/30.0_120.0/0_0.bin").path))
print("PASS smoothing-cache: local v1 mask conversion, border preservation, no destructive migration, full fallback and corrupt v2 recovery")
'''.replace('require(try Data(contentsOf:root.appendingPathComponent(oldFolder+"patch-0"))==patch)','let unchanged=try Data(contentsOf:root.appendingPathComponent(oldFolder+"patch-0"));require(unchanged==patch)').replace('require(try Data(contentsOf:migrated)==before)','let twice=try Data(contentsOf:migrated);require(twice==before)')
with tempfile.TemporaryDirectory(dir='/private/tmp') as d:
 p=Path(d);(p/'main.swift').write_text(main)
 subprocess.run(['swiftc','-O','-module-cache-path',str(p/'modules'),*[str(root/'ios/MotoNav'/f'{n}.swift') for n in ['MapGeo','RasterProcessing','RouteMapPlan']],str(p/'main.swift'),'-o',str(p/'test')],check=True)
 subprocess.run([str(p/'test'),str(p/'cache')],check=True)
