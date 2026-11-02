// Synthetic processing benchmark; excludes SDK, disk cache and BLE. Compile as main.swift.
import Foundation
import Darwin
let mode=CommandLine.arguments[1],area=Int(CommandLine.arguments[2])!
let basePixels=[UInt8](repeating:0,count:1440000)
let base=MapGeo.encodeRaster(frameId:1,x0:-1200,y0:1200,w:1200,h:1200,mmPerPx:2000,idx:basePixels)
func tile(_ q:Int)->[UInt32] {
 var r=[UInt32](repeating:0xfff8f9fa,count:360000)
 let spacing=[28,48,72,110,600][area],size=[17,27,31,39,0][area]
 for y in stride(from:10,to:580,by:spacing) {for x in stride(from:10,to:580,by:spacing) {
  for yy in y..<min(600,y+size) {for xx in x..<min(600,x+size+(q%2)) {r[yy*600+xx]=0xffff00ff}}
 }}
 return r
}
var first=0,full=0
let start=ProcessInfo.processInfo.systemUptime
for _ in 0..<10 {
 if mode=="old" {
  var raw=[UInt32](repeating:0xfff8f9fa,count:1440000)
  for q in 0..<4 {let t=tile(q);for y in 0..<600 {for x in 0..<600 {raw[(q/2*600+y)*1200+q%2*600+x]=t[y*600+x]}}}
  let b=try AmapBuildings.apply(raw,base:basePixels,w:1200,h:1200)
  let packet=MapGeo.encodeRaster(frameId:1,x0:-1200,y0:1200,w:1200,h:1200,mmPerPx:2000 | (b.roofPixels>0 ? RasterPacket.flag:0),idx:b.pixels)
  first=packet.count;full=0
 } else {
  var patches=[Int:Data]()
  for q in 0..<4 {
   patches[q]=try FastBuildings.simplify(tile(q))
   if q==0 && patches[q]!.contains(1) {first=FastBuildings.packet(base:base,patches:patches).count}
  }
  full=FastBuildings.packet(base:base,patches:patches).count
 }
}
var usage=rusage();getrusage(RUSAGE_SELF,&usage)
let result:[String:Any] = ["mode":mode,"syntheticArea":area,"meanPipelineMs":(ProcessInfo.processInfo.systemUptime-start)*100,"userCpuSeconds":Double(usage.ru_utime.tv_sec)+Double(usage.ru_utime.tv_usec)/1e6,"peakRssBytes":usage.ru_maxrss,"firstBytes":first,"finalBytes":full]
print(String(data:try JSONSerialization.data(withJSONObject:result,options:.sortedKeys),encoding:.utf8)!)
