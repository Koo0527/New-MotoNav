#!/usr/bin/env python3
"""Exercise production offline orchestration with deterministic SDK/platform boundaries."""
import pathlib, subprocess, tempfile
root=pathlib.Path(__file__).resolve().parents[3]
source=(root/'ios/MotoNav/RouteOfflineMaps.swift').read_text().replace('import UIKit','').replace('RouteMapCache.shared','testCache')
code='''import Foundation
final class Settings {static let shared=Settings();var theme=1}
final class UIApplication {enum State {case active,background};static let shared=UIApplication();var applicationState=State.active}
enum MapFeeder {static let SRC_AMAP=3}
let cacheRoot=URL(fileURLWithPath:NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
let testCache=RouteMapCache(root:cacheRoot)
let release=DispatchSemaphore(value:0)
var calls:[Bool]=[]
var yieldMode=false,yieldEntered=false,yieldResult=false
enum AmapSdkRaster {
struct Output {let bytes:Data}
static func build(_ frame:MapGeo.Frame,cx:Double,cy:Double,includeBuildings:Bool,shouldCancel:()->Bool,onBaseReady:(Data)->Void,onBuildingStatus:(String)->Void,style:Int,preparedBase:Data?,buildingView:BuildingView?,onBuildingReady:(BuildingUpdate)->Void,shouldYield:()->Bool) throws -> Output {
 DispatchQueue.main.sync {calls.append(includeBuildings)}
 if yieldMode && includeBuildings {
  DispatchQueue.main.sync {yieldEntered=true}
  _=release.wait(timeout:.now()+5)
  let yielded=shouldYield()
  DispatchQueue.main.sync {yieldResult=yielded}
  throw MapProcessingError.cancelled
 }
 let base=MapGeo.encodeRaster(frameId:frame.id,x0:Int(cx-1200),y0:Int(cy+1200),w:1200,h:1200,mmPerPx:2000,idx:[UInt8](repeating:1,count:1440000))
 if !includeBuildings {onBaseReady(base);return Output(bytes:base)}
 onBuildingReady(BuildingUpdate(bytes:base,coverage:BuildingCoverage(checkedMask:1)))
 _=release.wait(timeout:.now()+5)
 onBuildingReady(BuildingUpdate(bytes:base,coverage:BuildingCoverage(checkedMask:15)))
 return Output(bytes:base)
}}
func until(_ condition:()->Bool) {let end=Date().addingTimeInterval(8);while !condition() && Date()<end {_ = RunLoop.current.run(mode:.default,before:Date().addingTimeInterval(0.01))};precondition(condition())}
'''
cases='''
let frame=MapGeo.Frame(refLat:30,refLng:120,id:1)
let plan=try RouteMapPlan([(x:0.0,y:0.0),(x:10.0,y:0.0)])
var seen:[UInt8]=[]
var maps:RouteOfflineMaps!
maps=RouteOfflineMaps(frame:frame,plan:plan,source:3,buildings:true,foregroundBusy:{false},onReady:{node in if let update=maps.readUpdate(node) {seen.append(update.coverage.checkedMask)}},onStatus:{_ in})
precondition(maps.reuseStyle(2,source:3,buildings:true))
precondition(!maps.reuseStyle(5,source:3,buildings:true))
precondition(!maps.reuseStyle(2,source:4,buildings:true))
UIApplication.shared.applicationState = .background
maps.start()
_ = RunLoop.current.run(mode:.default,before:Date().addingTimeInterval(0.15))
precondition(calls.isEmpty)
UIApplication.shared.applicationState = .active
until {seen.contains(1)}
precondition(calls.first == false && calls.contains(true))
precondition(!seen.contains(15))
release.signal()
until {seen.contains(15)}
maps.close()
let before=seen.count
_ = RunLoop.current.run(mode:.default,before:Date().addingTimeInterval(0.1))
precondition(seen.count == before)
var lateCount=0
let secondFrame=MapGeo.Frame(refLat:30,refLng:120,id:2)
var second:RouteOfflineMaps!
second=RouteOfflineMaps(frame:secondFrame,plan:plan,source:3,buildings:true,foregroundBusy:{false},onReady:{node in
 if second.readUpdate(node)?.coverage.checkedMask == 1 {lateCount += 1}
},onStatus:{_ in})
second.start()
until {lateCount > 0}
second.close()
let closedCount=lateCount
release.signal()
let finish=Date().addingTimeInterval(0.25)
while Date()<finish {_ = RunLoop.current.run(mode:.default,before:Date().addingTimeInterval(0.01))}
precondition(lateCount == closedCount)
precondition(second.readUpdate(plan.nodes[0])?.coverage.checkedMask == 1)
let yieldFrame=MapGeo.Frame(refLat:30,refLng:120,id:3)
let yieldPlan=try RouteMapPlan([(x:0.0,y:0.0),(x:4000.0,y:0.0)])
precondition(yieldPlan.nodes.count >= 3)
for node in yieldPlan.nodes {
 let base=MapGeo.encodeRaster(frameId:yieldFrame.id,x0:Int(node.x-1200),y0:Int(node.y+1200),w:1200,h:1200,mmPerPx:2000,idx:[UInt8](repeating:1,count:1440000))
 try testCache.store(base,frame:yieldFrame,source:3,node:node,style:1)
 if node == yieldPlan.nodes[0] {
  let roof=FastBuildings.packet(base:base,patches:[0:Data(repeating:1,count:90000)])
  try testCache.storeBuildingUpdate(BuildingUpdate(bytes:roof,coverage:BuildingCoverage(checkedMask:1)),frame:yieldFrame,source:3,node:node)
 }
}
yieldMode=true
let yielding=RouteOfflineMaps(frame:yieldFrame,plan:yieldPlan,source:3,buildings:true,foregroundBusy:{false},onReady:{_ in},onStatus:{_ in})
yielding.update(1,display:0)
yielding.start()
until {yieldEntered}
yielding.update(2,display:2)
release.signal()
until {yieldResult}
yielding.close()
try? FileManager.default.removeItem(at:cacheRoot)
print("production offline progressive/background/reuse lifecycle passed")
'''
with tempfile.TemporaryDirectory() as temp:
 main=pathlib.Path(temp)/'main.swift';main.write_text(code+source+cases)
 exe=pathlib.Path(temp)/'check'
 subprocess.run(['swiftc','-module-cache-path',str(pathlib.Path(temp)/'modules'),*[str(root/'ios/MotoNav'/p) for p in ['MapGeo.swift','RasterProcessing.swift','RouteMapPlan.swift']],str(main),'-o',str(exe)],check=True)
 subprocess.run([str(exe)],check=True)
