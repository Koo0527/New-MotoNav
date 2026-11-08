from pathlib import Path
import subprocess, tempfile
root=Path(__file__).resolve().parents[3]
swift=r'''
import Foundation
var styleState=MapEdgeStyleState()
assert(!styleState.configure(frame:60000),"never configure before SDK mapInitComplete")
assert(!styleState.ready(frame:60000,enabled:true),"getter alone is not ready")
styleState.initialized=true
assert(styleState.configure(frame:60000))
assert(!styleState.configure(frame:60000),"do not reload style for every tile/pass")
assert(!styleState.ready(frame:60000,enabled:false))
assert(styleState.ready(frame:60000,enabled:true))
assert(!styleState.ready(frame:60001,enabled:true),"a new scene needs its own configuration")
assert(styleState.configure(frame:60001))
styleState=MapEdgeStyleState()
assert(!styleState.ready(frame:60001,enabled:true),"new/released maps must discard initialization")
for terminal in ["complete: five scenes","partial: five scenes; captures=3/5 checkedMask=3","failed: POI SDK error 1002"] {
 var lifecycle=MapEdgeLifecycle()
 assert(lifecycle.update("query: 01-dense"))
 assert(lifecycle.update(terminal) && lifecycle.finished)
 assert(!lifecycle.update("cancelled-background"),"background after terminal must not replace root cause")
 assert(!lifecycle.update("failed: late callback"))
 assert(lifecycle.lastStatus == terminal)
}
var interrupted=MapEdgeLifecycle()
assert(interrupted.update("capture: 01-dense"))
assert(interrupted.update("cancelled-background") && interrupted.finished)
assert(!interrupted.update("complete: five scenes"))
for i in MapEdgeSamples.all.indices {
 let query=MapEdgeSamples.all[i].query
 assert(MapEdgeSamples.matches(name:query,at:i))
 assert(!MapEdgeSamples.matches(name:query+"停车场",at:i))
 assert(!MapEdgeSamples.matches(name:"商户"+query,at:i))
 assert(!MapEdgeSamples.matches(name:nil,at:i))
}
assert(MapEdgeSamples.matches(name:"延安东路立交桥",at:3))
// Exercise the same mode, exact-name and city guards used by SDK callbacks.
assert(MapEdgeSamples.selected(arguments:[]).map { $0.folder } == MapEdgeSamples.all.map { $0.folder })
assert(MapEdgeSamples.all.count == 5 && MapEdgeSamples.all.allSatisfy { $0.city == "上海" })
assert(MapEdgeSamples.selected(arguments:["--edge-capture-mingbo"]).count == 5,"Mingbo alone must not select a diagnostic target")
assert(MapEdgeSamples.selected(arguments:["--edge-capture-check"]).count == 5)
let mingbo=MapEdgeSamples.selected(arguments:["--edge-capture-check","--edge-capture-mingbo"])
assert(mingbo.count == 1 && mingbo[0].folder == "06-mingbo")
assert(mingbo[0].query == "明波立交桥" && mingbo[0].city == "昆明")
for name in ["明波立交桥","明波立交"] { assert(MapEdgeSamples.matches(name:name,at:0,in:mingbo)) }
for name in ["明波立交桥停车场","商户明波立交桥","明波立交桥(入口)","延安东路立交"] {
 assert(!MapEdgeSamples.matches(name:name,at:0,in:mingbo))
}
assert(!MapEdgeSamples.matches(name:nil,at:0,in:mingbo))
assert(MapEdgeSamples.contains(latitude:25,longitude:102,city:mingbo[0].city))
assert(!MapEdgeSamples.contains(latitude:31,longitude:121,city:mingbo[0].city))
assert(MapEdgeSamples.contains(latitude:31,longitude:121,city:MapEdgeSamples.all[0].city))
assert(!MapEdgeSamples.contains(latitude:25,longitude:102,city:MapEdgeSamples.all[0].city))
for (lat,lng) in [(23.9,102.0),(26.1,102.0),(25.0,100.9),(25.0,104.1),(Double.nan,102),(25,Double.infinity)] {
 assert(!MapEdgeSamples.contains(latitude:lat,longitude:lng,city:mingbo[0].city))
}
assert(!MapEdgeSamples.contains(latitude:25,longitude:102,city:"unknown"))
for count in [1,5] {
 let complete=MapEdgeSamples.completion(count:count,partial:[])
 let partial=MapEdgeSamples.completion(count:count,partial:["captures=3/5"])
 assert(complete == "complete: \(count) scenes" && partial == "partial: \(count) scenes; captures=3/5")
 var lifecycle=MapEdgeLifecycle()
 assert(lifecycle.update(partial) && lifecycle.finished)
 assert(!lifecycle.update(complete) && lifecycle.lastStatus == partial)
}
let dir=URL(fileURLWithPath:CommandLine.arguments[1])
// A partial SDK result is evidence, never a complete scene, even when every raw PNG exists.
try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
var progress=MapEdgeDiagnostics()
assert(progress.checkedMask == nil && progress.captureCount == 0 && !progress.complete)
try progress.write(to:dir)
let unknown=try JSONSerialization.jsonObject(with:Data(contentsOf:dir.appendingPathComponent("diagnostics.json"))) as! [String:Any]
assert((unknown["coverage"] as! [String:Any])["checkedMask"] is NSNull,"absent coverage must not look checked")
for name in ["base","building-0","building-1"] { progress.tiles[name]="exported" }
progress.baseExported=true; progress.outputExported=true; progress.checkedMask=3; progress.rasterCaptureCount=3
progress.noteBuildingStatus("建筑提取未完成：建筑两次截图尺寸或相机发生变化")
assert(progress.captureCount == 3 && !progress.complete)
assert(progress.failures == ["建筑两次截图尺寸或相机发生变化"])
assert(progress.summary("01-dense").contains("captures=3/5 checkedMask=3"))
let originalPNG=dir.appendingPathComponent("building-0-on.png")
try Data([1,2,3]).write(to:originalPNG)
try progress.write(to:dir)
let diagnostic=try JSONSerialization.jsonObject(with:Data(contentsOf:dir.appendingPathComponent("diagnostics.json"))) as! [String:Any]
assert(diagnostic["captureCount"] as? Int == 3 && diagnostic["complete"] as? Bool == false)
assert((diagnostic["coverage"] as! [String:Any])["checkedMask"] as? Int == 3)
assert((diagnostic["tiles"] as! [String:String])["building-2"] == "pending")
let retained=try Data(contentsOf:originalPNG)
assert(retained == Data([1,2,3]),"progress updates must preserve all raw captures")
for name in ["building-2","building-3"] { progress.tiles[name]="exported" }
assert(!progress.complete,"five raw shots cannot promote unchecked coverage")
progress.checkedMask=15
assert(!progress.complete,"a recorded failure cannot become complete")
progress.failures=[]
assert(progress.complete)
progress.exportFailed=true
assert(!progress.complete,"export errors must remain partial")
for sensitive in ["key=secret cookie=session latitude=31.2304 longitude=121.4737 /Users/private/file", "高德地图加载失败：key=secret cookie=token 1002"] {
 let safe=MapEdgeDiagnostics.safeReason(sensitive)
 assert(!safe.contains("secret") && !safe.contains("cookie") && !safe.contains("31.2304") && !safe.contains("/Users/"))
}
assert(MapEdgeDiagnostics.safeReason("高德地图加载失败：AMapErrorDomain 1002") == "SDK map load failure code=1002")
let fileError=NSError(domain:NSCocoaErrorDomain,code:640,userInfo:[NSLocalizedDescriptionKey:"disk secret cookie=token /Users/private/file"])
let safeFileError=MapEdgeDiagnostics.safeError(fileError)
assert(safeFileError.contains("NSCocoaErrorDomain code=640") && !safeFileError.contains("secret") && !safeFileError.contains("/Users/"))
let styleURL=dir.appendingPathComponent("style.data")
let unused=try MapEdgeStyle.load(requested:false,from:styleURL)
assert(unused == nil,"normal startup must not read optional style")
do {_=try MapEdgeStyle.load(requested:true,from:styleURL);assertionFailure("missing explicit style must fail")}catch{}
try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
for invalid in [Data(),Data(repeating:1,count:2*1024*1024+1)] {
 try invalid.write(to:styleURL)
 do {_=try MapEdgeStyle.load(requested:true,from:styleURL);assertionFailure("invalid explicit style must fail")}catch{}
}
try Data([0x01,0x02,0x03]).write(to:styleURL)
do {_=try MapEdgeStyle.load(requested:true,from:styleURL);assertionFailure("unverified style must fail")}catch{}
let valid=try Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[2]))
try valid.write(to:styleURL)
let loaded=try MapEdgeStyle.load(requested:true,from:styleURL)
assert(loaded == valid,"pass original style bytes without conversion")
let pixels:[UInt32]=[0xff112233,0xff445566,0xff778899,0xffaabbcc]
let info=try MapEdgeArchive.write(pixels, width:2, height:2, left:0, top:0, right:2, bottom:2,
 north:31.01, south:31, size:2, to:dir, name:"base")
assert(info.columns == [0,1] && info.rows == [0,1])
assert(!FileManager.default.fileExists(atPath:dir.appendingPathComponent("base.argb32le").path),"full-resolution pixel dumps duplicate lossless PNGs")
try MapEdgeArchive.writePixels(pixels,to:dir.appendingPathComponent("sampled.argb32le"))
let raw=try Data(contentsOf:dir.appendingPathComponent("sampled.argb32le"))
assert(Array(raw.prefix(4)) == [0x33,0x22,0x11,0xff])
let metadata=try String(contentsOf:dir.appendingPathComponent("base.json"),encoding:.utf8)
assert(!metadata.contains("31.01") && !metadata.contains("north") && !metadata.contains("latitude"))
let grid=(0..<36).map { UInt32(0xff000000) | UInt32($0) }
let projection=try MapEdgeArchive.write(grid,width:6,height:6,left:0.2,top:0.3,right:5.8,bottom:5.7,north:80,south:40,size:3,to:dir,name:"nonlinear")
let expected=try AmapSampleGrid.resample(grid,width:6,height:6,left:0.2,top:0.3,right:5.8,bottom:5.7,north:80,south:40,size:3)
let replay=projection.rows.flatMap { y in projection.columns.map { x in grid[y*6+x] } }
assert(replay == expected,"coordinate-free projection must exactly reproduce the production Mercator sampler")
let sampled=try AmapSampleGrid.resample(pixels,width:2,height:2,left:0,top:0,right:2,bottom:2,north:31.01,south:31,size:2)
assert(sampled == pixels)
do {
 _=try MapEdgeArchive.write(pixels,width:2,height:2,left:0,top:0,right:3,bottom:2,north:31.01,south:31,size:2,to:dir,name:"invalid")
 assertionFailure("invalid projection must fail")
} catch MapProcessingError.invalid(_) {}
assert(!FileManager.default.fileExists(atPath:dir.appendingPathComponent("invalid.argb32le").path))
// The diagnostic frame must survive UInt16 wire encoding and cache validation.
for id in 60000...60004 {
 let frame=MapGeo.Frame(refLat:0,refLng:0,id:id)
 let node=RouteMapPlan.Node(x:0,y:0,distance:0)
 let bytes=MapGeo.encodeRaster(frameId:id,x0:-1200,y0:1200,w:1200,h:1200,mmPerPx:2000,idx:[UInt8](repeating:0,count:1440000))
 let cache=RouteMapCache(root:dir.appendingPathComponent("cache-\(id)"))
 let update=BuildingUpdate(bytes:bytes,coverage:BuildingCoverage(qualityVersion:FastBuildings.qualityVersion,checkedMask:15))
 try cache.storeBuildingUpdate(update,frame:frame,source:3,node:node)
 assert(cache.buildingUpdate(frame:frame,source:3,node:node,style:1)?.coverage.isComplete == true)
}
print("PASS edge partial diagnostics/count/coverage, error redaction, raw preservation, lifecycle terminal guards, exact POI matching, style bounds/asset validation and archive: byte order, sampling projection, coordinate redaction, invalid projection, diagnostic UInt16 cache roundtrip")
'''
with tempfile.TemporaryDirectory() as d:
 p=Path(d);(p/'main.swift').write_text(swift)
 subprocess.run(['swiftc','-DDEBUG','-module-cache-path',str(p/'modules'),'-swift-version','5',*[str(root/'ios/MotoNav'/f'{s}.swift') for s in ['MapGeo','RasterProcessing','RoadPalette','RouteMapPlan','MapStyles','MapEdgeCapture']],str(p/'main.swift'),'-o',str(p/'check')],check=True)
 subprocess.run([str(p/'check'),str(p/'out'),str(root/'output/edge-bridge-evidence/my_style_new.data')],check=True)

# Diagnostic switches and custom-style SDK mutations must compile out of Release.
def without_debug(source):
    result=[]; branches=[]
    for line in source.splitlines():
        token=line.strip()
        if token.startswith('#if '):
            branches.append(token == '#if DEBUG')
        elif token == '#endif':
            branches.pop()
        elif not any(branches):
            result.append(line)
    return '\n'.join(result)
for name in ['AmapCaptureHost','MapEdgeCapture']:
    release=without_debug((root/'ios/MotoNav'/f'{name}.swift').read_text())
    for diagnostic in ['--edge-capture-', 'MapEdgeCapture', 'MapEdgeStyle', 'customMapStyleEnabled', 'isIdleTimerDisabled', 'CryptoKit']:
        assert diagnostic not in release, f'{diagnostic} leaked into Release {name}'
print('PASS edge source gating: style, idle timer and diagnostic APIs excluded from Release')

# UIKit callbacks are not compiled by the portable harness; assert the evidence hooks stay wired.
capture=(root/'ios/MotoNav/MapEdgeCapture.swift').read_text()
for callback in ['onBuildingStatus: { message in','onBuildingReady: { update in']:
    assert callback in capture
assert 'failed: incomplete captures or export' not in capture
assert 'status(MapEdgeSamples.completion(count: scenes.count, partial: partialScenes))' in capture
assert 'req.city = scenes[index].city; req.cityLimit = true' in capture
assert 'MapEdgeSamples.matches(name: $0.name, at: index, in: scenes)' in capture
assert 'MapEdgeSamples.contains(latitude: lat, longitude: lng, city: scenes[index].city)' in capture
assert 'self.index += 1; self.next()' in capture
assert 'self.frameID == id, !self.shouldCancel(), !self.lifecycle.finished' in capture
assert 'frame.id == frameID, !lifecycle.finished, !shouldCancel()' in capture
print('PASS partial scene continuation and callback terminal/frame isolation hooks')

host=(root/'ios/MotoNav/AmapCaptureHost.swift').read_text()
header=(root/'ios/Pods/AMapNavi/AMapNaviKit.framework/Headers/MAMapView.h').read_text()
assert '- (void)mapInitComplete:(MAMapView *)mapView;' in header
assert '@objc(mapInitComplete:)' in host
assert 'self.map === m' in host
assert 'guard pending != nil, let frame = edgeStyleFrame' in host
assert 'self.serial == id, self.pending != nil, self.edgeStyleFrame != nil' in host
assert host.index('guard edgeStyle.ready(frame: styleFrame') < host.index('m.takeSnapshot(in:')
assert '诊断样式等待地图初始化或启用超时' in host
assert 'edgeStyleFrame = nil' in host[host.index('private func finish'):]
for field in ['mapInitComplete','customMapStyleEnabledGetter','configuredForFrame','verifiedAssetSHA','renderedStyleChangeVerified']:
    assert field in host
assert '"customStyle": AmapCaptureHost.shared.styleEvidence' in capture
assert 'style-status.json' in capture
assert 'frame == frameID && !lifecycle.finished && !shouldCancel()' in capture
print('PASS SDK initialization selector, per-frame style gate, cancellation/frame isolation and camera/status evidence hooks')
