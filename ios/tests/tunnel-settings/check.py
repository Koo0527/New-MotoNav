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
final class BleLink {
    static let shared = BleLink()
    var commands: [(String, Date)] = []
    func send(_ text: String) { commands.append((text, Date())) }
    var brightness: [Int] { commands.compactMap { $0.0.hasPrefix("#b,") ? Int($0.0.dropFirst(3)) : nil } }
}
final class MapFeeder { static let shared=MapFeeder(); func resetChunk() {}; func resendAll() {} }
enum MapDefaults { static func buildings()->Bool { false }; static func source(_ ud:UserDefaults)->Int { 0 } }
final class MusicBridge { static let shared=MusicBridge(); func syncMode() {}; func syncLyrics(force:Bool) {}; func refresh(force:Bool) {} }
final class AMapServices { static let instance=AMapServices(); static func shared()->AMapServices { instance }; var apiKey="" }
final class SearchService { static let shared=SearchService(); func rebuildAPI() {} }
final class NaviBridge { static let shared=NaviBridge(); var lastLocation:CLLocation?; func rebuildManager() {} }
final class LocationService { static let shared=LocationService(); var location:CLLocation? }
enum SunTimes { static var day=true; static func isDaytime(lat:Double?,lng:Double?)->(day:Bool,desc:String) { (day,"test sun") } }
''' + policy + settings + r'''
defer { testDefaults.removePersistentDomain(forName: suite) }
let s=Settings.shared, b=BleLink.shared
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
print("PASS tunnel Settings: isolated preferences, palette, automatic/manual overrides, reconnect, fade timing, cancellation and reset")
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
