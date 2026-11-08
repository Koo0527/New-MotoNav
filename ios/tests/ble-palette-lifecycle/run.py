"""Run production notification prefix and lifecycle reset statements with boundary fakes."""
from pathlib import Path
import re, subprocess, tempfile
root=Path(__file__).resolve().parents[2]
source=(root/'MotoNav/BleLink.swift').read_text()
def body(signature):
    start=source.index(signature); start=source.index('{',start)+1
    depth=1; i=start
    while depth:
        if source[i]=='{': depth+=1
        elif source[i]=='}': depth-=1
        i+=1
    return source[start:i-1]
callback=body('func peripheral(_ p: CBPeripheral, didUpdateValueFor ch: CBCharacteristic, error: Error?)')
callback=callback[:callback.index('        if s == "CAP,BLD,1"')]
ack_start=source.index('        if parts.first == "K"')
ack_end=source.index('        if parts.first == "S"', ack_start)
ack_block=source[ack_start:ack_end]
# Keep the actual assignments and the readiness transition from each production lifecycle body.
def reset_fragment(signature):
    b=body(signature)
    lines=[]
    for line in b.splitlines():
        for statement in line.split(';'):
            statement=statement.strip()
            if statement in ('isReady = false','roadPaletteVersion = 0','verified = false','resetGMotion()'):
                lines.append(statement)
    assert 'roadPaletteVersion = 0' in lines or 'isReady = false' in lines, signature
    return '\n'.join(lines)
observer=body('@Published var isReady = false')
greset=body('private func resetGMotion()')
fragments=[reset_fragment(x) for x in ('private func attach(_ p: CBPeripheral)', 'func centralManagerDidUpdateState(_ c: CBCentralManager)', 'func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?)', 'func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?)', 'func disconnect()')]
header='''import Foundation
class CBPeripheral {}
class CBCharacteristic { var value:Data? }
class Settings { static let shared=Settings(); var authenticated=0; func deviceAuthenticated(){authenticated += 1};func pushAll(){};func deviceDisconnected(){} }
class MapFeeder {static let shared=MapFeeder();var palette=0;var all=0;var auth=0;var acks=0;var rejects=0;func onRoadPaletteCapability(){palette += 1};func onAuthenticated(){auth += 1};func resendAll(){all += 1};func onAck(type:Int,id:Int){acks += 1};func onReject(type:Int,id:Int){rejects += 1};func onReceiptTimeout(id:Int){rejects += 1}}
class GRecorder {static let shared=GRecorder();var caps=0;var packets=0;func receive(_ d:Data){packets += 1};func setCapability(){caps += 1};func receiveAck(_ s:String){};func linkLost(){};func setPhoneEntryCapability(){};func resetPhoneEntry(){}}
class MusicBridge {static let shared=MusicBridge();func receiveAMS(_ d:Data){};func syncMode(){};func refresh(force:Bool){}}
class Motion {var caps=0;var resets=0;func setCapability(){caps += 1};func reset(){resets += 1}}
class Probe {func reset(){}}
class Receipt {struct P{let id:Int};var resets=0;var current:P?;func begin(id:Int,tail:Data){current=P(id:id)};func reset(){resets += 1;current=nil};func acknowledge(id:Int){if current?.id==id{current=nil}}}
class Meter {var rate:Double?=nil;func finish(id:Int,at:Double)->(bytes:Int,seconds:Double)?{nil};func cancel(){}}
class BulkQ {func acknowledge(type:Int,id:Int){}}
enum MapPipelineTrace {static func event(_ name:String,_ fields:[String:Any]=[:]){}}
class Link {
 var peripheral:CBPeripheral?;var txChar:CBCharacteristic?;var verified=false;var roadPaletteVersion=0;var buildingProbe=Probe();var gMotion=Motion()
 var mapReceipt=Receipt();var mapMeter=Meter();var bulkQ=BulkQ()
 var isReady=false { READY_OBSERVER }
 struct Queued {let key:String};var queue=[Queued]()
 func resetGMotion(){ GM_RESET };func syncPhoneClock(force:Bool){};func requestBuildingCapability(){};func sendOnce(_ s:String){}
 func failCurrentMap(_ id:Int){guard let p=mapReceipt.current,p.id==id else{return};mapReceipt.reset();mapMeter.cancel();MapFeeder.shared.onReject(type:3,id:id)}
 var mediaHIDSupported=false;var mediaLyricsSupported=false
 func receive(_ p:CBPeripheral,_ ch:CBCharacteristic,_ error:Error?) {
'''
tests='''
func check(_ ok: @autoclosure ()->Bool,_ msg:String){precondition(ok(),msg)}
let l=Link(),p=CBPeripheral(),ch=CBCharacteristic();l.peripheral=p;l.txChar=ch;l.isReady=true
func send(_ s:String){ch.value=Data(s.utf8);l.receive(p,ch,nil)}
let other=CBCharacteristic();other.value=Data("CAP,MPAL,2".utf8);l.receive(p,other,nil);check(!l.verified && l.roadPaletteVersion==0,"non-notification characteristic ignored")
send("CAP,MPAL,0");check(!l.verified && l.roadPaletteVersion==0,"invalid capability cannot authenticate")
send("CAP,MPAL,2");check(l.verified && l.roadPaletteVersion==2 && MapFeeder.shared.palette==1 && Settings.shared.authenticated==1,"first v2 restores auth and activates once")
check(MapFeeder.shared.all==0,"auth must not resend the map before capability settles")
check(MapFeeder.shared.auth==1,"auth enters the capability-gated map resend path once")
send("CAP,MPAL,1");send("CAP,MPAL,2");check(l.roadPaletteVersion==2 && MapFeeder.shared.palette==1,"old or repeated capability cannot downgrade or resend")
send("CAP,GMOT,1");check(l.gMotion.caps==1 && l.roadPaletteVersion==2,"motion capability unaffected")
ch.value=Data([0xa7,1]);l.receive(p,ch,nil);check(GRecorder.shared.packets==1,"G recording data unaffected")
for i in 0..<5 {l.roadPaletteVersion=2;l.verified=true;l.isReady=true;let before=l.gMotion.resets;l.queue=[.init(key:"#GM"),.init(key:"#NAV")];l.lifecycle(i);check(l.roadPaletteVersion==0,"lifecycle clears palette");check(l.gMotion.resets>before && l.queue.map { $0.key }==["#NAV"],"lifecycle clears motion and stale GM while preserving other commands")}
l.verified=false;l.isReady=true;send("CAP,MPAL,1");check(l.roadPaletteVersion==1 && l.verified,"reconnect v1 accepted")
l.mapReceipt.begin(id:7,tail:Data([1]))
l.receiveMap("K,3,7");check(MapFeeder.shared.acks==1,"current K reaches the map feeder")
l.mapReceipt.begin(id:8,tail:Data([1]))
let oldRejects=MapFeeder.shared.rejects
l.receiveMap("N,3,7");check(l.mapReceipt.current?.id==8 && l.mapReceipt.resets==0 && MapFeeder.shared.rejects==oldRejects,"late N must not clear the current receipt")
l.receiveMap("N,3,8");check(l.mapReceipt.current==nil && l.mapReceipt.resets==1 && MapFeeder.shared.rejects==oldRejects+1,"current N clears and reports the current map")
l.mapReceipt.begin(id:9,tail:Data([1]))
let oldAcks=MapFeeder.shared.acks
l.receiveMap("K,3,8");check(l.mapReceipt.current?.id==9 && MapFeeder.shared.acks==oldAcks,"late K must not acknowledge the current receipt")
l.mapReceipt.begin(id:10,tail:Data([1]))
l.receiveMap("N,3,10");check(l.mapReceipt.current==nil && MapFeeder.shared.rejects==oldRejects+2,"current N before the tail ATT callback still fails the current map")
print("PASS production BLE notification prefix and lifecycle reset statements")
'''
methods='\n'.join('case %d: %s'%(i,';'.join(fragments[i].splitlines())) for i in range(len(fragments)))
header=header.replace('READY_OBSERVER',observer).replace('GM_RESET',greset)
code=header+callback+'\n}\nfunc receiveMap(_ s:String) {\nlet parts = s.split(separator: ",").map(String.init)\n'+ack_block+'\n}\nfunc lifecycle(_ i:Int){switch i {\n'+methods+'\ndefault: break\n}}\n}\n'+(root/'MotoNav/BleHandshakeClock.swift').read_text()+tests
with tempfile.TemporaryDirectory() as d:
    path=Path(d);(path/'main.swift').write_text(code)
    subprocess.run(['swiftc','-module-cache-path',str(path/'modules'),str(path/'main.swift'),'-o',str(path/'check')],check=True)
    subprocess.run([str(path/'check')],check=True)
