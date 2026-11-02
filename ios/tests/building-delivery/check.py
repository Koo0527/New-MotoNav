#!/usr/bin/env python3
"""Run actual handoff and preparation policy with progressive packet metadata."""
import pathlib, subprocess, tempfile
root = pathlib.Path(__file__).resolve().parents[3]
swift = '''import Foundation
func check(_ value: Bool) { precondition(value) }
var handoff = MapHandoffBuffer()
func packet(_ mask: UInt8) -> MapHandoffBuffer.Packet {
 .init(bytes:Data([mask]),cx:0,cy:0,sat:false,type:1,info:"",source:3,style:1,coverage:BuildingCoverage(checkedMask:mask))
}
let first=packet(1), full=packet(15)
check(!first.coverage!.isComplete)
handoff.stage(full)
check(handoff.take(x:0,y:0,kmh:0,style:1,transferPending:true)==nil)
check(handoff.pending?.coverage?.isComplete == true)
check(handoff.take(x:0,y:0,kmh:0,style:1,transferPending:false)?.coverage?.isComplete == true)
handoff.stage(first);handoff.stage(full)
check(handoff.pending?.coverage?.checkedMask == 15)
handoff.stage(first)
check(handoff.take(x:0,y:0,kmh:0,style:5,transferPending:false)==nil)
check(handoff.pending == nil)
let empty=BuildingUpdate(bytes:Data(),coverage:BuildingCoverage(checkedMask:15))
check(empty.coverage.isComplete)
let next=RouteMapPreparationPolicy.next(base:[true,true],complete:[false,false],display:0,target:1,buildings:true,kmh:0,available:[true,true],partialReady:[false,false])
check(next?.index == 0 && next?.buildings == true)
print("building delivery behavior passed")
'''
with tempfile.TemporaryDirectory() as temp:
    main = pathlib.Path(temp)/'main.swift'
    main.write_text(swift)
    exe = pathlib.Path(temp)/'check'
    subprocess.run(['swiftc', '-module-cache-path',str(pathlib.Path(temp)/'modules'), *[str(root/'ios/MotoNav'/p) for p in ['MapGeo.swift','RasterProcessing.swift','RouteMapPlan.swift']], str(main), '-o',str(exe)],check=True)
    subprocess.run([str(exe)],check=True)
# Execute the production acceptChunk body with deterministic transport/UI boundaries.
source = (root/'ios/MotoNav/MapFeeder.swift').read_text()
method = source[source.index('    private func acceptChunk('):source.index('    private func fetchChunk(')].replace('private func acceptChunk','func acceptChunk')
method = method.replace('MapStyleTransfer', 'FakeStyleTransfer').replace('MapDeliveryPolicy','FakeDeliveryPolicy').replace('AmapCapturePolicy','FakeCapturePolicy').replace('RasterPacket','FakeRasterPacket')
stubs = '''
enum FakeRasterPacket {static func isBuilding(_ b:Data)->Bool {b.first == 4};static func hasMapContent(_ b:Data)->Bool {true}}
struct Pose {var x:Double=0;var y:Double=0;var kmh:Int=0}
final class Settings {static let shared=Settings();var theme=1}
final class BleLink {static let shared=BleLink();var pending=true;func bulkPending(type:Int,id:Int)->Bool {pending}}
enum MapPipelineTrace {static func event(_ name:String,_ fields:[String:Any]) {}}
enum FakeStyleTransfer {static func matches(_ b:Data,style:Int)->Bool {true}}
enum FakeDeliveryPolicy {static func compactBase(_ b:Data)->Data {Data([0])}}
enum FakeCapturePolicy {static func supportsBuildings(_ style:Int)->Bool {false}}
final class Feeder {
static let SRC_AMAP=3
var enabled=true,buildingMode=true,haveChunk=true,chunkAcked=false,chunkBuildingsComplete=false,chunkSat=false
var allow=false
var pose:Pose?=Pose(),chunkCoverage:BuildingCoverage?,chunkBytes:Data?=Data([0]),chunkStyle:Int?=1
var deferredRoofs:MapHandoffBuffer.Packet?,upgradeBase:(MapHandoffBuffer.Packet,Int)?
var handoff=MapHandoffBuffer(),chunkType=1,chunkId=1,nextChunkId=1,chunkRoadBytes=0
var chunkCx=0.0,chunkCy=0.0,buildingInfo="",status="",chunkInfo=""
func roofDeliveryAllowed(_ b:Data,cx:Double,cy:Double)->Bool {allow}
var sent:[Data]=[]
func sendChunk() {sent.append(chunkBytes!)}
'''
cases = '''
let f=Feeder()
f.acceptChunk(Data([4,4]),cx:100,cy:0,sat:false,type:1,info:"",src:3,coverage:BuildingCoverage(checkedMask:15))
precondition(f.handoff.pending?.coverage?.isComplete == true)
precondition(f.deferredRoofs?.coverage?.isComplete == true)
f.chunkAcked=true;BleLink.shared.pending=false
let staged=f.handoff.take(x:0,y:0,kmh:0,style:1,transferPending:false)!
f.acceptChunk(staged.bytes,cx:staged.cx,cy:staged.cy,sat:false,type:1,info:"",src:3,coverage:staged.coverage)
precondition(!f.chunkBuildingsComplete)
f.allow=true;f.chunkAcked=true
f.acceptChunk(Data([4]),cx:100,cy:0,sat:false,type:1,info:"",src:3,coverage:BuildingCoverage(checkedMask:1))
// A queued full observation must survive a later low-progress callback.
precondition(!f.chunkBuildingsComplete)
precondition(f.deferredRoofs?.coverage?.checkedMask == 15)
f.chunkAcked=true;BleLink.shared.pending=false
f.acceptChunk(Data([4,4]),cx:100,cy:0,sat:false,type:1,info:"",src:3,coverage:BuildingCoverage(checkedMask:15))
precondition(f.chunkBuildingsComplete && f.chunkCoverage?.checkedMask == 15)
let g=Feeder();g.allow=true;g.chunkAcked=true;BleLink.shared.pending=false
g.acceptChunk(Data([4]),cx:0,cy:0,sat:false,type:1,info:"",src:3,coverage:BuildingCoverage(checkedMask:1))
precondition(g.sent == [Data([4])])
BleLink.shared.pending=true;g.allow=false
g.acceptChunk(Data([4,4]),cx:0,cy:0,sat:false,type:1,info:"",src:3,coverage:BuildingCoverage(checkedMask:15))
precondition(g.sent == [Data([4])])
g.chunkAcked=true;g.allow=true;BleLink.shared.pending=false
let final=g.handoff.take(x:0,y:0,kmh:0,style:1,transferPending:false)!
g.acceptChunk(final.bytes,cx:0,cy:0,sat:false,type:1,info:"",src:3,coverage:final.coverage)
precondition(g.sent == [Data([4]),Data([4,4])])
precondition(g.chunkBuildingsComplete)
g.acceptChunk(Data([4]),cx:0,cy:0,sat:false,type:1,info:"",src:3,coverage:BuildingCoverage(checkedMask:1))
precondition(g.chunkBuildingsComplete && g.sent == [Data([4]),Data([4,4])])
print("production acceptChunk slow-link regression passed")
'''
with tempfile.TemporaryDirectory() as temp:
    main=pathlib.Path(temp)/'main.swift'
    main.write_text('import Foundation\n'+stubs+method+'\n}\n'+cases)
    exe=pathlib.Path(temp)/'feeder'
    subprocess.run(['swiftc','-module-cache-path',str(pathlib.Path(temp)/'modules'),*[str(root/'ios/MotoNav'/p) for p in ['MapGeo.swift','RasterProcessing.swift','RouteMapPlan.swift']],str(main),'-o',str(exe)],check=True)
    subprocess.run([str(exe)],check=True)
