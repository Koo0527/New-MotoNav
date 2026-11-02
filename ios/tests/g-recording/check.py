from pathlib import Path
import tempfile,subprocess,os
root=Path(__file__).resolve().parents[2]
code=r'''
import Foundation
import Combine
class BleLink { static let shared=BleLink(); func sendOnce(_ s:String) {} }
func check(_ condition: @autoclosure ()->Bool,_ message:String) { if !condition() { print("FAIL: \(message)"); exit(1) } }
func wait(_ done:()->Bool) { let end=Date().addingTimeInterval(60); while !done() && Date()<end { RunLoop.current.run(until:Date().addingTimeInterval(0.005)) }; check(done(),"async timeout") }
func packet(_ token:UInt32,_ seq:UInt16,_ time:UInt32,_ lat:Int16=123,_ lon:Int16 = -456,_ flags:UInt8=1)->Data {
 var b:[UInt8]=[0xa7,1,flags]
 func put(_ value:UInt64,_ n:Int) { for i in 0..<n { b.append(UInt8(truncatingIfNeeded:value >> (i*8))) } }
 put(UInt64(seq),2);put(UInt64(time),4);put(UInt64(token),4);put(UInt64(UInt16(bitPattern:lat)),2);put(UInt64(UInt16(bitPattern:lon)),2)
 return Data(b)
}
func token(_ commands:[String])->UInt32 { UInt32(commands.last(where:{$0.hasSuffix(",20")})!.split(separator:",")[1],radix:16)! }
''' + (root/'MotoNav/GRecorder.swift').read_text() + r'''
let folder=FileManager.default.temporaryDirectory.appendingPathComponent("g-test-\(UUID())")
defer {try? FileManager.default.removeItem(at:folder)}
var commands:[String]=[]
let g=GRecorder(directory:folder,send:{commands.append($0)})
g.setCapability();g.sensorState(2);wait{g.ready}
check(!g.recording,"manual not started implicitly")
g.setPreview(true);let previewToken=token(commands)
g.receive(packet(previewToken,0,1000),now:Date())
check(!g.recording && g.records.isEmpty && g.liveSamples.count==1,"live preview does not create a record")
let beforeRenew=commands.count
g.receive(packet(previewToken,1,1050,0,0,8),now:Date(),uptime:ProcessInfo.processInfo.systemUptime+6)
check(commands.count==beforeRenew+1 && commands.last!.hasSuffix(",20"),"received invalid callback renews lease after five seconds")
g.receive(packet(previewToken,2,1100,1000,2000),now:Date());g.receive(packet(previewToken,3,1150,500,1000),now:Date())
check(!g.liveSamples.last!.gap && g.liveSamples[g.liveSamples.count-2].gap && g.activePeaks.acceleration==2,"preview gap clears after first valid and peaks update")
g.setPreview(false);g.background();check(!g.recording,"preview stop never creates or stops a recording")
g.startManual();check(g.recording && g.canStopManual,"manual ready starts")
let t=token(commands), date=Date()
g.receive(packet(t,65535,UInt32.max-24),now:date,uptime:100)
g.receive(packet(t,0,25),now:date.addingTimeInterval(0.05),uptime:101)
check(g.liveSamples.count==2 && abs(g.liveSamples.last!.elapsed-0.05)<0.0001,"sequence and board time wrap")
g.receive(packet(t,0,25));g.receive(packet(t,65534,UInt32.max-74));g.receive(packet(t+1,1,75))
check(g.liveSamples.count==2,"duplicate stale wrong token discarded")
g.receive(packet(t,1,75,0,0,8));check(g.liveSamples.count==2,"invalid is not fabricated zero")
g.receive(packet(t,3,175),now:date.addingTimeInterval(0.2),uptime:106)
check(g.liveSamples.last!.gap,"invalid and sequence gaps break chart")
let ride=UUID();g.rideStarted(ride);check(g.activeRecord!.rideIDs.contains(ride),"manual record associates ride")
g.unlinkRide(ride);check(g.activeRecord!.rideIDs.isEmpty,"active record unlink preserves standalone recording")
g.rideStarted(ride)
g.rideFinished(ride);check(g.recording && g.canStopManual,"manual survives navigation end")
g.linkLost();g.setCapability();let next=token(commands)
check(next != t,"reconnect rotates token")
g.receive(packet(next,0,100),now:date.addingTimeInterval(5),uptime:110)
check(g.liveSamples.last!.gap && g.activeRecord!.sampleCount==4,"same record reconnect segment")
g.stop();wait{g.records.count==1};check(g.records[0].rideIDs==[ride],"ride association persisted")
g.unlinkRide(ride);wait{g.records[0].rideIDs.isEmpty};check(g.records.count==1,"ride deletion preserves standalone G")
let ride2=UUID();g.rideStarted(ride2);check(g.recording && g.canStopManual,"auto arms and allows explicit stop")
g.stop();g.rideStarted(ride2);check(!g.recording,"explicit stop suppresses auto restart within same ride")
g.rideFinished(ride2);check(!g.recording && g.records.count==1,"no empty automatic record")
g.startManual();g.rideStarted(ride2);g.stop();g.rideStarted(ride2);check(!g.recording,"stopped manual suppressed for same ride")
g.rideFinished(ride2)
// One hour of real 20 Hz callbacks, including extrema that uniform stride would miss.
g.startManual();let stress=token(commands)
for i in 0..<72000 {
 if i % 1000 == 0 { wait { g.pendingSampleCount < 1000 } }
 g.receive(packet(stress,UInt16(truncatingIfNeeded:i),UInt32(i*50),i==35117 ? 3000 : 123,i==55519 ? -4000 : 456),now:date.addingTimeInterval(Double(i)*0.05),uptime:Double(i)*0.05+200) }
check(g.liveSamples.count==1200,"one hour live memory bounded")
check(g.activeRecord!.sampleCount==72000 && g.activePeaks.right==3 && g.activePeaks.braking==4,"one hour no lost sample and peaks preserved")
g.stop();wait{g.records.count==2}
let record=g.records.first(where:{$0.sampleCount==72000})!
var loaded:[GSample]?;g.loadSamples(for:record,limit:2400){loaded=$0};wait{loaded != nil}
check(loaded!.count<=2406 && loaded!.contains{$0.lateral==3} && loaded!.contains{$0.longitudinal == -4},"bounded replay preserves both channel peaks")
loaded=nil;g.loadSamples(for:record,from:1700,to:1710,limit:2400){loaded=$0};wait{loaded != nil}
check(loaded!.allSatisfy{(1700...1710).contains($0.elapsed)} && !loaded!.isEmpty,"indexed time window")
let reopened=GRecorder(directory:folder,send:{_ in});reopened.setCapability();reopened.sensorState(2);wait{reopened.ready}
check(reopened.records.first(where:{$0.id==record.id})?.sampleCount==72000,"hour metadata restored")
loaded=nil;reopened.loadSamples(for:record,from:1700,to:1710){loaded=$0};wait{loaded != nil};check(!loaded!.isEmpty,"lazy recovered index")
// Recover a complete prefix, never parse the torn tail or mark it complete.
let crash=GRecord(started:date)
try JSONEncoder().encode(crash).write(to:folder.appendingPathComponent(crash.id.uuidString+".json"))
let row=Data("{\"sample\":\(String(data:try JSONEncoder().encode(GSample(id:1,elapsed:0,utc:date,lateral:1,longitudinal:2)),encoding:.utf8)!)}\n{\"sample\":".utf8)
try row.write(to:folder.appendingPathComponent(crash.id.uuidString+".jsonl"))
let recovered=GRecorder(directory:folder,send:{_ in});recovered.setCapability();recovered.sensorState(2);wait{recovered.ready}
check(recovered.records.contains{$0.id==crash.id && $0.interrupted && $0.sampleCount==1},"partial tail recovered interrupted")
// Silent lease expiry on the same BLE connection recovers without an incoming packet.
let recoverRide=UUID();g.rideStarted(recoverRide);let silenceToken=token(commands)
g.receive(packet(silenceToken,0,5000),now:Date())
let beforeSilence=commands.count
g.foreground(uptime:ProcessInfo.processInfo.systemUptime+16)
check(commands.count>beforeSilence && token(commands) != silenceToken && !g.ready && g.liveSamples.isEmpty,"foreground silent lease rotates token and clears stale availability")
g.sensorState(2);check(!g.ready,"GC readiness cannot hide stale sample age")
let fresh=token(commands);g.receive(packet(fresh,0,100),now:Date())
check(g.ready && g.liveSamples.count==1,"fresh lease accepts reset board sequence")
let endDate=Date().addingTimeInterval(600)
g.stop(now:endDate,uptime:ProcessInfo.processInfo.systemUptime+600);wait{g.records.count==3};g.background()
let endedRecord=g.records.first!
check(endedRecord.duration>=600 && endedRecord.duration>=endedRecord.ended!.timeIntervalSince(endedRecord.started)-0.001,"record duration retains long missing tail")
let tailJournal=try String(contentsOf:folder.appendingPathComponent(endedRecord.id.uuidString+".jsonl"),encoding:.utf8)
check(tailJournal.contains("record ended") && tailJournal.contains("elapsed") && tailJournal.contains("utc"),"trailing missing span has timestamped durable gap marker")
let blockedQueue=DispatchQueue(label:"g-test-blocked")
var blockedCommands:[String]=[]
let blocked=GRecorder(directory:folder.appendingPathComponent("blocked"),send:{blockedCommands.append($0)},worker:blockedQueue)
blocked.setCapability();blocked.sensorState(2);wait{blocked.ready};blocked.startManual();let blockedToken=token(blockedCommands)
blockedQueue.suspend()
for i in 0..<2100 { blocked.receive(packet(blockedToken,UInt16(i),UInt32(i*50)),now:date.addingTimeInterval(Double(i)*0.05)) }
check(blocked.pendingSampleCount<=2000 && !blocked.recording && !blocked.error.isEmpty,"blocked disk has bounded pending rows and visibly stops")
blocked.sensorState(2);check(!blocked.ready,"save failure cannot reenable readiness via later GC state")
blockedQueue.resume();wait{blocked.pendingSampleCount==0}
let bad=folder.appendingPathComponent("not-a-directory");try Data().write(to:bad)
let failure=GRecorder(directory:bad,send:{_ in});wait{!failure.error.isEmpty};check(!failure.recording,"storage failure visible and stopped")
let damaged=folder.appendingPathComponent("damaged")
var damageCommands:[String]=[]
let disk=GRecorder(directory:damaged,send:{damageCommands.append($0)});disk.setCapability();disk.sensorState(2);wait{disk.ready}
disk.startManual();let diskToken=token(damageCommands)
try FileManager.default.removeItem(at:damaged);try Data().write(to:damaged)
disk.receive(packet(diskToken,0,100),now:date)
wait{!disk.error.isEmpty};check(!disk.recording && !disk.ready,"active append failure visibly stops and disables restart")
disk.startManual();check(!disk.recording,"failed storage cannot silently resume")
check(commands.allSatisfy{$0.utf8.count<=20},"all G commands fit BLE20")
print("PASS G recording: 72000 samples/hour, bounded live/history/blocked IO, lease silence recovery, trailing gaps, peaks, sequence/time wrap, invalid/gaps, reconnect, lifecycle, links, crash recovery and disk failure")
'''
with tempfile.TemporaryDirectory(prefix='motonav-g-tests-') as d:
 p=Path(d);(p/'main.swift').write_text(code)
 env=dict(os.environ,SWIFT_MODULECACHE_PATH=str(p/'swift'),CLANG_MODULE_CACHE_PATH=str(p/'clang'))
 subprocess.run(['swiftc','-O',str(p/'main.swift'),'-o',str(p/'test')],check=True,env=env)
 subprocess.run([str(p/'test')],check=True,env=env)
