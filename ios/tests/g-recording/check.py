from pathlib import Path
import tempfile,subprocess,os
root=Path(__file__).resolve().parents[2]
code=r'''
import Foundation
import Combine
class BleLink { static let shared=BleLink(); func sendOnce(_ s:String) {}; func sendGPhoneEntry(_ token:UInt32,_ enter:Bool) -> Bool { true }; func discardGPhoneEntry() {} }
func check(_ condition: @autoclosure ()->Bool,_ message:String) { if !condition() { print("FAIL: \(message)"); exit(1) } }
func wait(_ done:()->Bool) { let end=Date().addingTimeInterval(60); while !done() && Date()<end { RunLoop.current.run(until:Date().addingTimeInterval(0.005)) }; check(done(),"async timeout") }
func packet(_ token:UInt32,_ seq:UInt16,_ time:UInt32,_ lat:Int16=123,_ lon:Int16 = -456,_ flags:UInt8=1)->Data {
 var b:[UInt8]=[0xa7,1,flags]
 func put(_ value:UInt64,_ n:Int) { for i in 0..<n { b.append(UInt8(truncatingIfNeeded:value >> (i*8))) } }
 put(UInt64(seq),2);put(UInt64(time),4);put(UInt64(token),4);put(UInt64(UInt16(bitPattern:lat)),2);put(UInt64(UInt16(bitPattern:lon)),2)
 return Data(b)
}
func token(_ commands:[String])->UInt32 { UInt32(commands.last(where:{$0.hasSuffix(",20")})!.split(separator:",")[1],radix:16)! }
''' + (root/'MotoNav/GRecorder.swift').read_text() + (root/'MotoNav/GChartGeometry.swift').read_text() + r'''
let folder=FileManager.default.temporaryDirectory.appendingPathComponent("g-test-\(UUID())")
defer {try? FileManager.default.removeItem(at:folder)}
var commands:[String]=[]
var phoneCommands:[String]=[]
var queuedEntry: String?
let g=GRecorder(directory:folder,send:{commands.append($0)},phoneSend:{token,enter in
    let entry=String(format:"#GE,%08X,%d",token,enter ? 1:0)
    queuedEntry=entry; phoneCommands.append(entry); return true
},phoneDiscard:{queuedEntry=nil})
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
// Phone page entry is a separate, non-persistent command bound to the current stream token.
g.enterPhonePage();check(phoneCommands.isEmpty,"old firmware without GENT does not send phone entry")
g.setPhoneEntryCapability();g.enterPhonePage()
check(phoneCommands.last==String(format:"#GE,%08X,1",previewToken),"phone page entry binds current stream")
let phoneCount=phoneCommands.count
g.enterPhonePage();check(phoneCommands.count==phoneCount,"repeated phone entry is not resent")
g.leavePhonePage();check(phoneCommands.last==String(format:"#GE,%08X,0",previewToken),"leaving phone page clears request")
g.enterPhonePage();check(phoneCommands.last==String(format:"#GE,%08X,1",previewToken),"new page entry can request again")
let beforeRequest=phoneCommands.count
g.requestPhonePage()
let retryToken=token(commands)
check(retryToken != previewToken && phoneCommands.count==beforeRequest && queuedEntry==nil,"retry drops the backlogged old entry and rotates the stream")
g.receiveAck(String(format:"GS,%08X,1",previewToken))
check(phoneCommands.count==beforeRequest,"old stream acknowledgement cannot start calibration")
g.receiveAck(String(format:"GS,%08X,1",retryToken))
g.receiveAck(String(format:"GS,%08X,1",retryToken))
check(phoneCommands.count==beforeRequest+1 && phoneCommands.last==String(format:"#GE,%08X,1",retryToken),"only the current acknowledged retry sends an entry, once")
check(!g.liveAvailable && g.liveSamples.count==3,"retry hides the point but preserves the recent preview")
let lastPreviewTime=g.liveSamples.last!.elapsed
g.receive(packet(retryToken,0,100))
check(g.liveAvailable && g.liveSamples.last!.gap && g.liveSamples.last!.elapsed>lastPreviewTime,"new stream resumes the live trace after a gap")
g.setPreview(false);check(phoneCommands.last==String(format:"#GE,%08X,0",retryToken),"preview stop clears phone entry")
g.background();check(!g.recording,"preview stop never creates or stops a recording")
g.setPreview(true)
let waitingToken=token(commands)
g.receive(packet(waitingToken,0,1000,0,0,8))
check(!g.ready && g.canRequestPhonePage,"waiting samples cannot disable retry")
let beforeTimeout=phoneCommands.count
g.requestPhonePage(uptime:50)
let lateToken=token(commands)
check(!g.canRequestPhonePage,"retry waits for acknowledgement")
g.receiveAck(String(format:"GS,%08X,1",lateToken),uptime:53)
check(g.canRequestPhonePage && phoneCommands.count==beforeTimeout,"an acknowledgement at the deadline expires without sending")
g.requestPhonePage();let canceledToken=token(commands)
g.background()
g.receiveAck(String(format:"GS,%08X,1",canceledToken))
check(phoneCommands.count==beforeTimeout,"background cancels the unconfirmed retry")
g.sensorState(2)
// A token rotation invalidates the phone request without silently resending 1.
let phoneFolder=folder.appendingPathComponent("phone")
var phoneSends:[String]=[]
let phoneRecorder=GRecorder(directory:phoneFolder,send:{phoneSends.append($0)},phoneSend:{token,enter in phoneSends.append(String(format:"#GE,%08X,%d",token,enter ? 1:0)); return true})
phoneRecorder.setCapability();phoneRecorder.setPhoneEntryCapability();phoneRecorder.sensorState(2);wait{phoneRecorder.ready}
phoneRecorder.setPreview(true);let phoneFirst=token(phoneSends)
phoneRecorder.enterPhonePage();check(phoneSends.last==String(format:"#GE,%08X,1",phoneFirst),"phone entry uses first token")
let phoneEntriesBeforeRotate=phoneSends.filter{$0.hasPrefix("#GE")}.count
phoneRecorder.foreground(uptime:ProcessInfo.processInfo.systemUptime+16)
let phoneSecond=token(phoneSends)
check(phoneSecond != phoneFirst && phoneSends.filter{$0.hasPrefix("#GE")}.count==phoneEntriesBeforeRotate,"token change does not resend phone entry")
phoneRecorder.leavePhonePage();check(phoneSends.filter{$0.hasPrefix("#GE")}.count==phoneEntriesBeforeRotate,"stale phone entry cannot send leave")
phoneRecorder.enterPhonePage();check(phoneSends.last==String(format:"#GE,%08X,1",phoneSecond),"actual entry after token change uses new token")
phoneRecorder.setPreview(false);check(phoneSends.last(where:{$0.hasPrefix("#GE")})==String(format:"#GE,%08X,0",phoneSecond),"leaving after rotation clears new token")
// A connection reset must discard GENT support; old firmware receives no #GE
// until a new CAP,GENT,1 arrives on the replacement connection.
phoneRecorder.linkLost()
phoneRecorder.setCapability()
phoneRecorder.setPreview(true)
let resetToken=token(phoneSends)
let entriesBeforeReset=phoneSends.filter{$0.hasPrefix("#GE")}.count
phoneRecorder.enterPhonePage()
check(phoneSends.filter{$0.hasPrefix("#GE")}.count==entriesBeforeReset,"connection reset without GENT sends zero")
phoneRecorder.setPhoneEntryCapability()
phoneRecorder.enterPhonePage()
check(phoneSends.last(where:{$0.hasPrefix("#GE")})==String(format:"#GE,%08X,1",resetToken),"new capability on replacement connection sends once")
phoneRecorder.receive(packet(resetToken,0,900))
phoneRecorder.startManual()
let firstRecordingToken=token(phoneSends)
let recordedAt=Date()
phoneRecorder.receive(packet(firstRecordingToken,0,1000,2000,1200),now:recordedAt)
let retryRecordID=phoneRecorder.activeRecord?.id
check(retryRecordID != nil,"record exists before retry")
phoneRecorder.requestPhonePage()
let retryRecordingToken=token(phoneSends)
phoneRecorder.receiveAck(String(format:"GS,%08X,1",retryRecordingToken))
phoneRecorder.receive(packet(retryRecordingToken,0,1000,0,0,8),now:recordedAt.addingTimeInterval(0.1))
phoneRecorder.receive(packet(retryRecordingToken,1,1050,100,200),now:recordedAt.addingTimeInterval(3))
check(phoneRecorder.activeRecord?.id==retryRecordID && phoneRecorder.activeRecord?.sampleCount==2 &&
    phoneRecorder.activeRecord?.gaps==1 && phoneRecorder.activePeaks.right==2 && phoneRecorder.liveSamples.last?.gap==true,
    "retry preserves record identity and peaks, with a single gap and no invalid sample")
phoneRecorder.requestPhonePage()
let disconnectedToken=token(phoneSends)
let disconnectedEntries=phoneSends.filter{$0.hasPrefix("#GE")}.count
phoneRecorder.linkLost();phoneRecorder.setCapability();phoneRecorder.setPhoneEntryCapability()
phoneRecorder.receiveAck(String(format:"GS,%08X,1",disconnectedToken))
check(phoneSends.filter{$0.hasPrefix("#GE")}.count==disconnectedEntries,"reconnect never replays an unconfirmed retry")
phoneRecorder.stop();wait{phoneRecorder.records.count==1}
phoneRecorder.setPreview(false)
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
// Historical replay keeps independent gap rows as boundaries instead of dropping them.
struct TestRow: Codable { var sample: GSample?; var gap: String?; var utc: Date?; var elapsed: Double? }
func plot(_ samples: [GSample]) -> [GPlotPoint] {
    samples.map { GPlotPoint(time: $0.elapsed, lateral: $0.lateral, longitudinal: $0.longitudinal, valid: $0.valid, gap: $0.gap) }
}
func fixture(_ label: String, duration: Double, samples: [(Double, Double, Double, Bool)], gaps: [(Double, String)]) -> (GRecorder, GRecord) {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("g-fixture-\(label)-\(UUID())")
    try! FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let start = Date(timeIntervalSince1970: 5000)
    var record = GRecord(started: start)
    record.ended = start.addingTimeInterval(duration)
    record.duration = duration; record.sampleCount = samples.count; record.gaps = gaps.count
    try! JSONEncoder().encode(record).write(to: folder.appendingPathComponent(record.id.uuidString + ".json"))
    var rows: [(Double, TestRow)] = []
    for (index, value) in samples.enumerated() {
        rows.append((value.0, TestRow(sample: GSample(id: UInt64(index + 1), elapsed: value.0, utc: start.addingTimeInterval(value.0), lateral: value.1, longitudinal: value.2, gap: value.3), gap: nil, utc: nil, elapsed: nil)))
    }
    for gap in gaps {
        rows.append((gap.0, TestRow(sample: nil, gap: gap.1, utc: start.addingTimeInterval(gap.0), elapsed: gap.0)))
    }
    var lines = ""
    for (_, row) in rows.sorted(by: { $0.0 < $1.0 }) {
        lines += String(data: try! JSONEncoder().encode(row), encoding: .utf8)! + "\n"
    }
    try! lines.write(to: folder.appendingPathComponent(record.id.uuidString + ".jsonl"), atomically: true, encoding: .utf8)
    let loader = GRecorder(directory: folder, send: { _ in })
    loader.setCapability(); loader.sensorState(2)
    wait { loader.records.contains { $0.id == record.id } }
    return (loader, record)
}
func replay(_ loader: GRecorder, _ record: GRecord, from: Double = 0, to: Double? = nil, limit: Int = 2400) -> [GSample] {
    var loaded: [GSample]?
    loader.loadSamples(for: record, from: from, to: to ?? record.duration, limit: limit) { loaded = $0 }
    wait { loaded != nil }
    return loaded!
}
func replayWindow(_ loader: GRecorder, _ record: GRecord, from: Double = 0, to: Double? = nil, limit: Int = 2400) -> GReplayWindow {
    var loaded: GReplayWindow?
    loader.loadReplayWindow(for: record, from: from, to: to ?? record.duration, limit: limit) { loaded = $0 }
    wait { loaded != nil }
    return loaded!
}
let (openingLoader, openingRecord) = fixture("opening", duration: 4,
    samples: [(1, 0.1, 0.2, false), (1.05, 0.2, 0.3, false), (2, 0.3, 0.4, false)],
    gaps: [(0, "stream silence")])
let opening = replayWindow(openingLoader, openingRecord)
check(opening.missing.contains { $0.start <= 0.0001 && $0.end >= 0.9999 && !$0.startIsSample && $0.endIsSample }, "opening missing range retained")
check(GChartGeometry.selected(plot(opening.samples), missing: opening.missing, at: 0.5, maxDistance: .infinity) == nil, "opening gap hides old value")
check(GChartGeometry.selected(plot(opening.samples), missing: opening.missing, at: 1, maxDistance: .infinity) != nil, "opening gap releases at first sample")

let (middleLoader, middleRecord) = fixture("middle", duration: 5,
    samples: [(0, 0.1, 0.2, false), (1, 0.2, 0.3, false), (3, 0.3, 0.4, false), (4, 0.4, 0.5, false)],
    gaps: [(2, "stream silence")])
let middle = replayWindow(middleLoader, middleRecord)
check(middle.missing.contains { abs($0.start - 1) < 0.0001 && abs($0.end - 3) < 0.0001 && $0.startIsSample && $0.endIsSample }, "middle missing range spans last-to-next valid sample")
check(GChartGeometry.selected(plot(middle.samples), missing: middle.missing, at: 1.5, maxDistance: .infinity) == nil, "middle gap before marker hides old value")
check(GChartGeometry.selected(plot(middle.samples), missing: middle.missing, at: 2.5, maxDistance: .infinity) == nil, "middle gap after marker hides old value")
check(GChartGeometry.selected(plot(middle.samples), missing: middle.missing, at: 1, maxDistance: .infinity) != nil, "middle gap keeps both valid boundaries selectable")
check(GChartGeometry.selected(plot(middle.samples), missing: middle.missing, at: 3, maxDistance: .infinity) != nil, "middle gap releases at next sample")

let (trailingLoader, trailingRecord) = fixture("trailing", duration: 10,
    samples: [(0, 0.1, 0.2, false), (1, 0.2, 0.3, false)],
    gaps: [(10, "record ended")])
let trailing = replayWindow(trailingLoader, trailingRecord)
check(trailing.missing.contains { abs($0.start - 1) < 0.0001 && abs($0.end - 10) < 0.0001 && $0.startIsSample && !$0.endIsSample }, "trailing missing range reaches record end")
check(GChartGeometry.selected(plot(trailing.samples), missing: trailing.missing, at: 5, maxDistance: .infinity) == nil, "trailing gap hides last value")
check(GChartGeometry.selected(plot(trailing.samples), missing: trailing.missing, at: 10, maxDistance: .infinity) == nil, "record end never repeats old value")
check(GChartGeometry.selected(plot(trailing.samples), missing: trailing.missing, at: 1, maxDistance: .infinity) != nil, "trailing gap keeps last valid sample selectable")

let (endedLoader, endedTailRecord) = fixture("ended-no-gap", duration: 100,
    samples: [(42, 0.1, 0.2, false), (43, 0.2, 0.3, false)],
    gaps: [])
let ended = replayWindow(endedLoader, endedTailRecord, from: 40, to: 50)
check(ended.missing.contains { abs($0.start - 43) < 0.0001 && abs($0.end - 50) < 0.0001 && $0.startIsSample && !$0.endIsSample }, "record tail without a gap row is still missing")
check(GChartGeometry.selected(plot(ended.samples), missing: ended.missing, at: 49, maxDistance: .infinity) == nil, "record tail never repeats old value")
check(GChartGeometry.selected(plot(ended.samples), missing: ended.missing, at: 43, maxDistance: .infinity) != nil, "record tail keeps last sample selectable")
let (windowLoader, windowRecord) = fixture("window", duration: 10,
    samples: [(0, 0.1, 0.2, false), (1, 0.2, 0.3, false), (8, 0.3, 0.4, false), (9, 0.4, 0.5, false)],
    gaps: [(2, "stream silence")])
let window = replayWindow(windowLoader, windowRecord, from: 3, to: 10)
check(window.missing.contains { abs($0.start - 3) < 0.0001 && abs($0.end - 8) < 0.0001 && !$0.startIsSample && $0.endIsSample }, "window starts inside clipped gap")
check(GChartGeometry.selected(plot(window.samples), missing: window.missing, at: 4, maxDistance: .infinity) == nil, "window gap start hides old value")
check(GChartGeometry.selected(plot(window.samples), missing: window.missing, at: 8, maxDistance: .infinity) != nil, "window gap releases at next sample")

// Downsampling uses continuous valid sections: a gap flag must not smear over either side.
var segmented: [(Double, Double, Double, Bool)] = []
for i in 0..<20 { segmented.append((Double(i) * 0.01, i == 3 ? 1.2 : 0.1, i == 7 ? -1.1 : 0.2, false)) }
for i in 0..<20 { segmented.append((0.2 + Double(i) * 0.01, i == 5 ? -1.3 : 0.3, i == 10 ? 1.4 : -0.2, i == 0)) }
let (segmentLoader, segmentRecord) = fixture("segments", duration: 0.39, samples: segmented, gaps: [])
let reduced = replay(segmentLoader, segmentRecord, to: 0.39, limit: 48)
check(reduced.filter(\.gap).count == 1, "one boundary sample does not smear a gap across a bucket")
check(reduced.contains { $0.elapsed < 0.2 && !$0.gap } && reduced.contains { $0.elapsed > 0.2 && !$0.gap }, "both valid curves survive the gap")
check(reduced.contains { $0.lateral == 1.2 } && reduced.contains { $0.longitudinal == -1.1 }, "first segment extrema retained")
check(reduced.contains { $0.lateral == -1.3 } && reduced.contains { $0.longitudinal == 1.4 }, "second segment extrema retained")

// Window 40–50 s of a record that ends at 100 s with the last sample at 43 s.
let builderStart = Date(timeIntervalSince1970: 7000)
func builderSample(_ time: Double, _ lateral: Double = 0.1, _ longitudinal: Double = 0.2, gap: Bool = false) -> GSample {
    GSample(id: UInt64(time * 1000), elapsed: time, utc: builderStart.addingTimeInterval(time), lateral: lateral, longitudinal: longitudinal, gap: gap)
}
var tailBuilder = GReplayBuilder(from: 40, to: 50, limit: 2400, started: builderStart)
_ = tailBuilder.sample(builderSample(42))
_ = tailBuilder.sample(builderSample(43))
_ = tailBuilder.gap(at: 100, date: nil)
let tailWindow = tailBuilder.finish()
check(tailWindow.missing.count == 1 && abs(tailWindow.missing[0].start - 43) < 0.0001 && abs(tailWindow.missing[0].end - 50) < 0.0001 && !tailWindow.missing[0].endIsSample, "tail builder clips missing span to window")
check(GChartGeometry.selected(plot(tailWindow.samples), missing: tailWindow.missing, at: 49, maxDistance: .infinity) == nil, "tail builder hides old yellow dot")
check(GChartGeometry.selected(plot(tailWindow.samples), missing: tailWindow.missing, at: 43, maxDistance: .infinity) != nil, "tail builder keeps last valid sample selectable")

// Dense gaps exceed the detailed budget and must switch to bounded conservative merge.
var denseBuilder = GReplayBuilder(from: 0, to: 72, limit: 2400, started: builderStart)
for i in 0..<7200 {
    _ = denseBuilder.sample(builderSample(Double(i) * 0.01, i == 1234 ? 1.5 : 0.1, i == 2345 ? -1.4 : 0.2, gap: i > 0 && i % 5 == 0))
}
let denseWindow = denseBuilder.finish()
check(denseWindow.mergedGaps && denseWindow.samples.count + 2 * denseWindow.missing.count <= 2400, "dense gaps stay within fixed budget")
check(denseWindow.peaks.right >= 1.5 && denseWindow.peaks.braking >= 1.4, "dense merge keeps raw peaks")
var longBuilder = GReplayBuilder(from: 0, to: 10000, limit: 2400, started: builderStart)
for i in 0..<200000 { _ = longBuilder.sample(builderSample(Double(i) * 0.05, 0.1, 0.2)) }
let longWindow = longBuilder.finish()
check(longWindow.samples.count + 2 * longWindow.missing.count <= 2400 && longWindow.missing.isEmpty && !longWindow.mergedGaps, "long detail window remains bounded without false gaps")
var tightBuilder = GReplayBuilder(from: 0, to: 10, limit: 8, started: builderStart)
_ = tightBuilder.sample(builderSample(0, 0.1, 0.2))
_ = tightBuilder.sample(builderSample(1, 1.2, 0.2))
_ = tightBuilder.gap(at: 2)
_ = tightBuilder.sample(builderSample(3, 0.1, 0.2))
_ = tightBuilder.sample(builderSample(4, 0.1, -1.1))
_ = tightBuilder.gap(at: 5)
_ = tightBuilder.sample(builderSample(6, 0.1, 0.2))
_ = tightBuilder.sample(builderSample(7, 0.1, 0.2))
let tightWindow = tightBuilder.finish()
check(tightWindow.mergedGaps && tightWindow.samples.count + 2 * tightWindow.missing.count <= 8, "six samples plus two gaps trigger conservative merge within budget")
check(tightWindow.peaks.right >= 1.2 && tightWindow.peaks.braking >= 1.1, "conservative merge keeps raw peaks")
// Dense gaps in a real record: merge at full scale, restore detail when zoomed in.
var denseRows: [(Double, Double, Double, Bool)] = []
for i in 0..<7200 { let gap = i >= 2000 && i < 4000 && i % 2 == 0; denseRows.append((Double(i) * 0.01, i == 1234 ? 1.5 : 0.1, i == 2345 ? -1.4 : 0.2, gap)) }
let (denseLoader, denseRecord) = fixture("dense-recording", duration: 72, samples: denseRows, gaps: [])
let denseReplay = replayWindow(denseLoader, denseRecord, limit: 2400)
check(denseReplay.mergedGaps && denseReplay.samples.count + 2 * denseReplay.missing.count <= 2400, "dense record switches to bounded merge")
let denseSegments = GChartGeometry.segments(plot(denseReplay.samples), maxGap: .infinity)
check(denseSegments.count > 1, "merged display keeps gap breaks")
let crossesGap = denseReplay.missing.contains { range in
    denseSegments.contains { segment in
        segment.contains { $0.time < range.start } && segment.contains { $0.time > range.end }
    }
}
check(!crossesGap, "merged display never connects across a missing range")
let zoomReplay = replayWindow(denseLoader, denseRecord, from: 10, to: 11, limit: 2400)
check(!zoomReplay.mergedGaps && !zoomReplay.samples.isEmpty && zoomReplay.samples.count + 2 * zoomReplay.missing.count <= 2400, "zoomed window restores detailed replay within budget")
// The production singleton publishes live UI at 5 Hz, while tests above use
// the immediate default. Buffered samples must not be lost between publishes.
var slowCommands:[String]=[]
let slow=GRecorder(directory:folder.appendingPathComponent("slow"),send:{slowCommands.append($0)},livePublishInterval:0.2)
slow.setCapability();slow.sensorState(2);wait{slow.ready};slow.setPreview(true);let slowToken=token(slowCommands)
slow.receive(packet(slowToken,0,1000),now:date,uptime:100)
check(slow.liveSamples.count==1,"first live sample publishes immediately")
slow.receive(packet(slowToken,1,1050),now:date,uptime:100.05)
check(slow.liveSamples.count==1,"live UI is throttled between publish intervals")
slow.receive(packet(slowToken,2,1100),now:date,uptime:100.25)
check(slow.liveSamples.count==3,"throttled publish retains every buffered sample")
var waitingPublishes=0
let waitingChanges=slow.objectWillChange.sink { _ in waitingPublishes += 1 }
slow.receive(packet(slowToken,3,1150,0,0,8),now:date,uptime:100.27)
check(!slow.liveAvailable,"invalid sample hides the live point")
waitingPublishes=0
for i in 4...23 { slow.receive(packet(slowToken,UInt16(i),1150+UInt32(i-3)*50,0,0,8),now:date,uptime:100.28) }
check(waitingPublishes==0 && !slow.ready,"repeated waiting frames publish no view updates")
slow.sensorState(2)
check(!slow.liveAvailable,"a calibration status cannot bring back the old point")
slow.receive(packet(slowToken,24,2200,750,100),now:date,uptime:100.30)
check(slow.ready && slow.liveAvailable && slow.liveSamples.last?.lateral==0.75 && slow.liveSamples.last?.gap==true,"recovery publishes the first new point with a gap immediately")
withExtendedLifetime(waitingChanges){}
var flowCommands:[String]=[]
let flowWorker=DispatchQueue(label:"g-flow-test")
setenv("MOTONAV_GFLOW_FILE","1",1)
let flowRec=GRecorder(directory:folder.appendingPathComponent("flow"),send:{flowCommands.append($0)},livePublishInterval:0,worker:flowWorker)
unsetenv("MOTONAV_GFLOW_FILE")
flowRec.setCapability();flowRec.sensorState(2);wait{flowRec.ready}
flowRec.setPreview(true);let flowToken=token(flowCommands)
flowRec.receive(packet(flowToken,0,1000,100,200))
flowRec.receive(Data([0,1,2]))
flowRec.receive(packet(flowToken+1,1,1050))
flowRec.receive(packet(flowToken,0,1000))
flowRec.receive(packet(flowToken,1,1050,0,0,8))
flowRec.receive(packet(flowToken,2,1100,100,200))
check(flowRec.flow.rx==6,"GFLOW counts every A7 callback")
check(flowRec.flow.invalid==1,"GFLOW counts A7 parse failures")
check(flowRec.flow.tokenRejected==1,"GFLOW counts old-token rejection")
check(flowRec.flow.sequenceRejected==1,"GFLOW counts duplicate/older sequence rejection")
check(flowRec.flow.invalidFlags==1,"GFLOW counts invalid sensor flags")
check(flowRec.flow.accepted==2,"GFLOW counts valid preview samples")
flowRec.startManual();let flowRecordToken=token(flowCommands)
flowRec.receive(packet(flowRecordToken,0,1150,100,200))
flowRec.receive(packet(flowRecordToken,1,1200,100,200))
flowRec.stop()
wait{flowRec.flow.writtenSamples>=2}
check(flowRec.flow.recordAccepted==2,"GFLOW counts recording samples")
check(flowRec.flow.queuedSamples==2,"GFLOW counts queued record samples")
check(flowRec.flow.writtenSamples==2,"GFLOW proves accepted recording samples reached disk")
// The opt-in diagnostic must survive a detached device console, stay bounded,
// and never add diagnostic I/O to default recorders.
flowRec.checkSilence()
flowWorker.sync{}
let flowFile=folder.appendingPathComponent("flow/GFLOW.log")
check(FileManager.default.fileExists(atPath:flowFile.path),"opt-in GFLOW is available without a device console")
let flowText=try String(contentsOf:flowFile,encoding:.utf8)
check(flowText.contains("record=2") && flowText.contains("queued=2,written=2,failed=0"),"durable GFLOW includes actual recording and disk counts")
try Data(repeating:88,count:1_048_576).write(to:flowFile)
flowRec.checkSilence();flowWorker.sync{}
let boundedFlow=try Data(contentsOf:flowFile)
check(boundedFlow.count<1024 && boundedFlow.starts(with:Data("GFLOW,".utf8)),"GFLOW log truncates at one MiB and retains a fresh complete snapshot")
check(!FileManager.default.fileExists(atPath:folder.appendingPathComponent("GFLOW.log").path),"GFLOW file diagnostics are off by default")
print("PASS G recording: 72000 samples/hour, bounded live/history/blocked IO, lease silence recovery, trailing gaps, peaks, sequence/time wrap, invalid/gaps, reconnect, lifecycle, links, crash recovery, disk failure, replay windows, bounded dense-gap merge, phone entry lifecycle, token binding, 5 Hz live publication and phone GFLOW counters")
'''
with tempfile.TemporaryDirectory(prefix='motonav-g-tests-') as d:
 p=Path(d);(p/'main.swift').write_text(code)
 env=dict(os.environ,SWIFT_MODULECACHE_PATH=str(p/'swift'),CLANG_MODULE_CACHE_PATH=str(p/'clang'))
 subprocess.run(['swiftc','-O',str(p/'main.swift'),'-o',str(p/'test')],check=True,env=env)
 subprocess.run([str(p/'test')],check=True,env=env)
