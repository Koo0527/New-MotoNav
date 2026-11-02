"""Exercise production Settings with isolated defaults and external device/SDK stubs."""
from pathlib import Path
import os
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
settings = (root / 'MotoNav/Settings.swift').read_text().split('/// 当天日出、日落时间')[0]
# Redirect every preference access, including stored-property initializers, away from user data.
settings = settings.replace('UserDefaults.standard', 'testDefaults')
policy = (root / 'MotoNav/TunnelDimming.swift').read_text()
capture_policy = (root / 'MotoNav/RasterProcessing.swift').read_text().split('enum AmapCapturePolicy {', 1)[1].split('\n}', 1)[0]
capture_policy = 'enum AmapCapturePolicy {' + capture_policy.split('    static func completed(', 1)[0] + '}\n'
code = r'''
import Foundation
import Combine
import CoreLocation
let suite = "motonav-tunnel-tests-\(UUID().uuidString)"
let testDefaults = UserDefaults(suiteName: suite)!
func check(_ value: Bool, _ message: String) {
    if !value { print("FAIL: \(message)"); exit(1) }
}
func wait(_ seconds: Double) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }
final class GRecorder { static let shared=GRecorder(); func sensorState(_ state:Int) {} }
final class BleLink {
    static let shared = BleLink()
    var isReady = true
    var verified = true
    var commands: [(String, Date)] = []
    func sendOnce(_ text: String) { send(text) }
    func discardLegacyDisplayCommands() {}
    func send(_ text: String) { commands.append((text, Date())) }
    var brightness: [Int] { commands.compactMap { $0.0.hasPrefix("#b,") ? Int($0.0.dropFirst(3)) : nil } }
}
final class MapFeeder { static let SRC_AMAP=3; static let shared=MapFeeder(); func resetChunk() {}; func resendAll() {} }
enum MapStyleTransfer { static func command(_ style:Int)->String { "#t,\(style),1" } }
final class MapSampleReport { static let shared=MapSampleReport(); func failIfWaiting(_ text:String) {} }
enum MapDefaults { static func buildings()->Bool { false }; static func source(_ ud:UserDefaults)->Int { 3 } }
final class MusicBridge { static let shared=MusicBridge(); func syncMode() {}; func syncLyrics(force:Bool) {}; func refresh(force:Bool) {} }
final class AMapServices { static let instance=AMapServices(); static func shared()->AMapServices { instance }; var apiKey="" }
final class SearchService { static let shared=SearchService(); func rebuildAPI() {} }
final class NaviBridge { static let shared=NaviBridge(); var lastLocation:CLLocation?; func rebuildManager() {} }
final class LocationService { static let shared=LocationService(); var location:CLLocation? }
enum SunTimes { static var day=true; static func isDaytime(lat:Double?,lng:Double?)->(day:Bool,desc:String) { (day,"test sun") } }
''' + capture_policy + policy + settings + r'''
defer { testDefaults.removePersistentDomain(forName: suite) }
if CommandLine.arguments.count>1 { testDefaults.set(Int(CommandLine.arguments[1])!,forKey:"map_theme") }
let s=Settings.shared, b=BleLink.shared
s.deviceAuthenticated(); wait(1.1)
if CommandLine.arguments.count>1 {
    let saved=Int(CommandLine.arguments[1])!
    check(s.theme==saved,"saved style remains selected after launch")
    check(Settings.themeOrder.count==12 && Set(Settings.themeOrder)==Set(0..<12),"all twelve firmware styles are selectable once")
    s.theme=saved
    check(b.commands.last?.0=="#t,\(saved),1","each style invalidates prior firmware map data")
    s.mapOn=true; s.buildings=true
    s.syncBuildingContinuity()
    check(b.commands.last?.0 == ((1...3).contains(saved) ? "#BC,1" : "#BC,0"), "building continuity follows supported style")
    s.buildings=false; s.syncBuildingContinuity()
    check(b.commands.last?.0=="#BC,0", "building switch disables continuity")
    testDefaults.removePersistentDomain(forName:suite)
    exit(0)
}
check(s.tunnelAuto && !s.tunnelDimmed,"fresh install enables automatic detection without dimming")
s.brightAuto=false; s.brightness=230; s.brightNight=60; s.nightMode=1
wait(0.2); s.applyDayNight(force:true); b.commands=[]
s.updateTunnel(.inside,now:0)
check(s.tunnelDimmed && s.paletteNight && s.brightnessInUse==60,"inside uses night palette and effective brightness")
wait(0.115)
check(b.brightness==[198],"first fade step is at most 32")
s.updateTunnel(.unknown,now:0.1)
wait(0.1)
check(b.brightness.last==166 && s.tunnelDimmed,"unknown holds dim state without restarting fade")
s.pushAll()
check(b.brightness.last==60,"reconnect pushes effective target immediately")
let afterReconnect=b.brightness.count
wait(0.25)
check(b.brightness.count==afterReconnect,"reconnect cancels old fade")
check(s.brightness==230 && s.brightNight==60 && s.nightMode==1,"tunnel preserves stored preferences")
check(testDefaults.integer(forKey:"bright")==230 && testDefaults.integer(forKey:"night_mode")==1,"tunnel never persists effective values")
s.toggleTunnelMode()
check(!s.tunnelDimmed && !s.paletteNight,"manual shortcut explicitly exits automatic dimming")
s.updateTunnel(.inside,now:0.2)
check(!s.tunnelDimmed,"automatic inside evidence respects manual exit")
s.updateTunnel(.outside,now:1); s.updateTunnel(.outside,now:2); s.updateTunnel(.outside,now:3); s.updateTunnel(.outside,now:4)
s.updateTunnel(.inside,now:5)
check(s.tunnelDimmed,"confirmed exit clears override for later tunnel")
s.tunnelAuto=false
check(!s.tunnelDimmed && !s.paletteNight && !s.tunnelAuto,"disabling auto clears transient state")
wait(0.7)
check(b.brightness.last==230,"disabling auto restores manual baseline")
s.updateTunnel(.inside,now:6)
check(!s.tunnelDimmed,"disabled automatic detection ignores evidence")
s.toggleTunnelMode(); check(s.tunnelDimmed,"shortcut works with auto disabled")
wait(0.115)
s.toggleTunnelMode(); check(!s.tunnelDimmed,"shortcut toggles off")
let atOff=b.brightness.last!
wait(0.115)
check(b.brightness.last!>=atOff,"old dimming timer cannot run after manual exit")
s.tunnelAuto=true
check(!s.tunnelDimmed,"enabling auto clears manual state")
s.updateTunnel(.inside,now:10); wait(0.115)
s.resetTunnel()
check(!s.tunnelDimmed && !s.paletteNight,"session reset clears policy and override")
let atReset=b.brightness.last!
wait(0.7)
check(b.brightness.last==230 && b.brightness.last!>=atReset,"reset restores baseline and cancels old dimming")
s.brightAuto=true; s.brightDay=240; s.brightNight=80; s.nightMode=2
wait(0.2)
s.updateTunnel(.inside,now:20); s.applyDayNight(force:true)
check(s.brightnessInUse==80 && s.paletteNight,"tunnel respects automatic day brightness and forced night palette")
s.resetTunnel(); s.applyDayNight(force:true)
check(s.brightnessInUse==240 && s.paletteNight,"exit restores independent brightness and palette preferences")
SunTimes.day=false; s.applyDayNight(force:true)
s.updateTunnel(.inside,now:21); s.resetTunnel(); s.applyDayNight(force:true)
check(s.brightnessInUse==80 && s.paletteNight,"night exit preserves nighttime baseline")
s.brightAuto=false; s.brightness=20; s.brightNight=80; wait(0.2)
s.toggleTunnelMode(); s.applyDayNight(force:true)
check(b.brightness.last==20,"tunnel never brightens a low baseline")
s.brightNight=10; wait(0.2)
check(b.brightness.last==10,"night slider still updates effective brightness with manual baseline")
s.brightness=7; wait(0.2)
check(b.brightness.last==7,"manual slider debounce uses effective target")
s.resetTunnel(); s.brightness=999; wait(0.2)
check(b.brightness.last==255,"out-of-range preference clamps at device boundary")
s.brightness = -50; wait(0.2)
check(b.brightness.last==5,"minimum brightness remains safe")
s.brightness=230; s.brightNight=60; wait(0.2); b.commands=[]
s.toggleTunnelMode()
for i in 0..<5 { wait(0.04); s.updateTunnel(.unknown,now:30+Double(i)*0.04) }
wait(0.45)
let values=b.brightness
check(values.last==60 && values.count==6,"fade reaches target without extra sends")
var previous=230
for value in values { check(abs(value-previous)<=32,"fade step bound"); previous=value }
let times=b.commands.filter{$0.0.hasPrefix("#b,")}.map{$0.1}
for i in 1..<times.count { check(times[i].timeIntervalSince(times[i-1])>=0.085,"fade interval is 0.1 seconds") }
s.toggleTunnelMode(); s.updateTunnel(.inside,now:31)
check(s.tunnelDimmed,"manual off outside does not suppress the next automatic tunnel")
s.resetTunnel(); s.applyDayNight(force:true); b.commands=[]
s.brightness=220; s.updateTunnel(.inside,now:32)
wait(0.18)
check(b.brightness==[198],"pending slider debounce cannot abruptly finish a tunnel fade")
s.deviceDisconnected(); b.commands=[]
s.deviceReply("CAP,CTL,1")
check(b.commands.map{$0.0} == ["#CTL", "#PS"],"capability reads physical state and power before sending target")
s.setTunnelMode(false); s.applyDayNight(force:true)
check(!b.commands.contains{$0.0.hasPrefix("#TM,") || $0.0.hasPrefix("#b,") || $0.0.hasPrefix("#n,")},"no target before physical read")
s.deviceReply("CTL,000A,1,1,0,1")
check(s.tunnelDimmed && s.paletteNight,"offline physical tunnel beats stale phone state")
check(b.commands.last?.0.hasPrefix("#TM,000A,") == true && b.commands.last?.0.hasSuffix(",1") == true,"target acknowledges physical revision")
let count=b.commands.count
s.deviceReply("CTL,000A,1,1,0,0")
check(b.commands.count==count,"duplicate ack never loops")
s.setTunnelMode(false)
check(!s.tunnelDimmed && b.commands.last?.0.hasSuffix(",0") == true,"manual absolute target after read")
s.deviceReply("CTL,000A,1,1,0,0")
check(!s.tunnelDimmed,"delayed duplicate cannot undo phone intent")
s.deviceReply("CTL,000A,1,1,0,1")
check(!s.tunnelDimmed,"duplicate pending snapshot cannot undo phone intent")
s.deviceReply("CTL,000B,1,0,0,1")
check(s.tunnelDimmed,"new physical revision overrides phone")
s.setTunnelMode(false)
check(!s.tunnelDimmed && b.commands.last?.0.hasSuffix(",1") == true,"physical ack cannot be coalesced by a rapid manual target")
s.deviceReply("CTL,000B,1,0,0,0")
check(b.commands.last?.0.hasSuffix(",0") == true,"manual target sends after physical acknowledgement")
s.setTunnelMode(true)
s.deviceReply("CTL,000A,0,0,0,1")
check(s.tunnelDimmed && s.deviceControlStatus.contains("隧道开启"),"stale physical reply and status are ignored")
s.resetTunnel()
check(!s.tunnelDimmed && b.commands.last?.0.hasSuffix(",0") == true,"end reset reaches new firmware")
s.deviceReply("PS,1800,240")
check(s.usbSleep==1800 && s.batterySleep==240,"device NVS wins initial defaults")
s.setDevicePower(usb:0,battery:30)
check(s.usbSleep==1800 && b.commands.last?.0=="#PS,0,30","power saves only on readback")
s.deviceReply("PS,0,30"); check(s.usbSleep==0 && s.batterySleep==30,"power confirmation applied")
s.deviceReply("CAP,AUD,1"); check(b.commands.last?.0=="#BS","audio first queries")
s.deviceReply("BS,0,37"); s.setDeviceSound(enabled:true,volume:20)
check(!s.bootSound && s.bootVolume==37 && b.commands.last?.0=="#BS,1,20","audio remains device authoritative")
s.deviceReply("BS,1,20"); check(s.bootSound && s.bootVolume==20,"audio confirmation applied")
s.setDeviceSound(enabled:false,volume:10); s.deviceReply("BS,1,20")
check(s.deviceAudioStatus.contains("未确认") && s.bootSound,"audio save failure is visible and preserves device state")
s.setDevicePower(usb:600,battery:120); s.deviceReply("PS,0,30")
check(s.devicePowerStatus.contains("未确认") && s.usbSleep==0,"power save failure is visible")
s.deviceReply("BS,ERR"); check(s.deviceAudioStatus.contains("拒绝"),"audio rejection is visible")
s.deviceReply("CAP,IMU,1"); check(b.commands.last?.0=="#GQ","IMU first queries")
s.deviceReply("GC,1,1,90")
check(s.mountReference==1 && s.mountAngle==90,"startup readback restores saved physical mount before the G page is active")
s.deviceReply("GC,2,0,0"); s.calibrateDevice(reference:2,angle:359)
check(b.commands.last?.0=="#GC,2,359" && s.mountReference==0,"calibration one-shot never saves prematurely")
s.deviceReply("GC,3,2,359"); check(s.deviceCalibrating && s.mountAngle==0,"calibration in progress preserves saved mount")
s.deviceReply("GC,4,2,359"); check(!s.deviceCalibrating && s.mountAngle==0,"failed calibration preserves saved mount")
s.deviceReply("GC,2,2,359"); check(s.mountReference==2 && s.mountAngle==359,"confirmed calibration saved")
let beforeInvalid=b.commands.count
s.calibrateDevice(reference:3,angle:360); s.setDevicePower(usb:3,battery:999); s.setDeviceSound(enabled:true,volume:101)
check(b.commands.count==beforeInvalid,"invalid commands rejected")
check(b.commands.allSatisfy{$0.0.utf8.count<=20},"all device controls fit BLE20")
check(!b.commands.contains{$0.0.hasPrefix("#b,") || $0.0.hasPrefix("#n,")},"new firmware owns brightness fade")
s.deviceDisconnected(); b.commands=[]; s.applyDayNight(force:true)
check(b.commands.isEmpty,"offline display target never replays")
print("PASS tunnel Settings: legacy fade, CTL handshake/offline/stale/duplicate/manual/end reset, confirmed PS/BS/GC and BLE20")
'''
with tempfile.TemporaryDirectory(prefix='motonav-tunnel-settings-') as directory:
    folder = Path(directory)
    source = folder / 'main.swift'
    source.write_text(code)
    env = dict(os.environ)
    env['SWIFT_MODULECACHE_PATH'] = str(folder / 'swift-cache')
    env['CLANG_MODULE_CACHE_PATH'] = str(folder / 'clang-cache')
    subprocess.run(['swiftc', '-O', str(source), '-o', str(folder / 'test')], check=True, env=env)
    subprocess.run([str(folder / 'test')], check=True, env=env)
    for style in range(12):
        subprocess.run([str(folder / 'test'), str(style)], check=True, env=env)
    print('PASS all twelve style selections survive relaunch and emit isolated map commands')
