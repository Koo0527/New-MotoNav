import Foundation
func check(_ b: Bool,_ message: String) {if !b {print("FAIL: \(message)");exit(1)}}
let n=1200,count=n*n
func packet(_ ids: [UInt8])->Data {RoadPalette.encode(frameId:7,x0:-1200,y0:1200,w:n,h:n,indices:ids)}
var ids=[UInt8](repeating:0,count:count)
for i in 0...10 {ids[i]=UInt8(i)}
let semantic=packet(ids)
check(RasterPacket.valid(semantic) && RoadPalette.isPacket(semantic) && RasterPacket.isBuilding(semantic),"semantic roof packet")
check(RasterPacket.decode(semantic)==ids,"semantic decode exact")
var wrapped=Data([1,2,3]);wrapped.append(semantic)
let slice=wrapped.dropFirst(3)
check(RoadPalette.isPacket(slice) && RoadPalette.hasRoofs(slice) && RasterPacket.isBuilding(slice),"Data slices preserve header checks")
check(RasterPacket.valid(slice) && RasterPacket.decode(slice)==ids,"Data slices validate and decode")
check(semantic.count<=480000,"transfer limit")
let semanticBytes=[UInt8](semantic)
check(RasterPacket.u16(semanticBytes,36)==RasterPacket.u16(semanticBytes,16),"casing fallback colour is base")
check(RasterPacket.u16(semanticBytes,44)==0x4d4e && RasterPacket.u16(semanticBytes,46)==0x5212,"canonical metadata")
check(!RasterPacket.valid(Data(semantic.prefix(47))),"truncated palette rejected")
check(!RasterPacket.valid(Data(semantic.dropLast())),"truncated RLE rejected")
var oversized=semantic;oversized.append(Data(repeating:0,count:480001))
check(!RasterPacket.valid(oversized),"oversized transfer rejected")
var carriedIDs=ids
for p in carriedIDs.indices where (4...7).contains(carriedIDs[p]) {carriedIDs[p] &= 2}
let carried=AmapBuildings.carry(packet(carriedIDs),known:packet([UInt8](repeating:4,count:count)))
check(RasterPacket.valid(carried) && RoadPalette.isPacket(carried) && RasterPacket.isBuilding(carried),"carry preserves semantic metadata")
let carriedPixels=RasterPacket.decode(carried)!
for i in 8...10 {check(carriedPixels[i]==UInt8(i),"carry preserves all new materials")}
check(carriedPixels[0]==4 && carriedPixels[2]==6,"carry retains roofs only on ground/park")
let painted=RasterPacket.decode(FastBuildings.packet(base:packet(carriedIDs),patches:[0:Data(repeating:1,count:90000)]))!
for i in 8...10 {check(painted[i]==UInt8(i),"paint preserves all new materials")}

for p in [false,true] {for b in [false,true] {
    let converted=RoadPalette.forWire(semantic,paletteVersion:p ? 2 : 0,buildingsSupported:b)
    check(RasterPacket.valid(converted),"all capability combinations valid")
    let decoded=RasterPacket.decode(converted)!
    for i in 0...10 {
        let want:UInt8=i>=8 && !p ? 1 : (4...7).contains(i) && !b ? UInt8(i&2):UInt8(i)
        check(decoded[i]==want,"capability conversion")
    }
    check(RasterPacket.isBuilding(converted)==b,"roof bit conversion")
    check(RoadPalette.isPacket(converted)==p,"palette capability")
}}
let compact=MapDeliveryPolicy.compactBase(semantic)
check(RasterPacket.valid(compact) && !RasterPacket.isBuilding(compact),"compact roofs cleared")
check(RasterPacket.decode(compact)![10]==10,"protected casing survives compact")
check(RasterPacket.decode(RasterPacket.forLegacy(semantic))![10]==1,"legacy semantic fallback")
check(MapStyleTransfer.matches(semantic,style:2) && !MapStyleTransfer.matches(semantic,style:0) && !MapStyleTransfer.matches(semantic,style:5),"semantic styles")
var invalid=semantic;invalid[46]=3
check(!RasterPacket.valid(invalid),"unsupported semantic version")
invalid=semantic;invalid[46]=0x21
check(!RoadPalette.isPacket(invalid) && !RasterPacket.valid(invalid),"unknown roof/version bits rejected")
invalid=semantic;invalid[10]=0
check(!RasterPacket.valid(invalid),"non1200 semantic frame rejected")
invalid=semantic;invalid[14]=0xd1
check(!RasterPacket.valid(invalid),"non2000 semantic scale rejected")
invalid=semantic;invalid[46]=1
check(!RasterPacket.valid(invalid),"missing roof flag")
invalid=packet([UInt8](repeating:10,count:count));invalid[46]=0x11
check(!RasterPacket.valid(invalid),"extra roof flag")
for code in [12,14,15] {invalid=semantic;invalid[48]=(invalid[48]&240)|UInt8(code);check(!RasterPacket.valid(invalid),"reserved pixel code")}
check(!RasterPacket.hasMapContent(packet([UInt8](repeating:10,count:count))),"casing is not content")
for roof in [false,true] {
    let old=MapGeo.encodeRaster(frameId:7,x0:0,y0:0,w:n,h:n,mmPerPx:2000|(roof ? RasterPacket.flag:0),idx:[UInt8](repeating:roof ? 7:3,count:count))
    check(RasterPacket.valid(old),"old standard valid")
    let wire=RoadPalette.forWire(old,paletteVersion:2,buildingsSupported:false)
    check(RasterPacket.valid(wire) && !RasterPacket.isBuilding(wire),"old roofs downgraded for nonbuilding receiver")
}
let custom=MapGeo.encodeRaster(frameId:7,x0:0,y0:0,w:n,h:n,mmPerPx:2000,idx:[UInt8](repeating:15,count:count),pal:Array(0...15))
check(RasterPacket.valid(custom) && !RoadPalette.isPacket(custom),"ordinary palette valid")
check(RoadPalette.forWire(custom,paletteVersion:0,buildingsSupported:false)==custom,"ordinary palette untouched")
var white=[UInt32](repeating:0xfff8f9fa,count:101*101)
for y in 0..<101 {for x in 45...55 {white[y*101+x]=0xffffffff}}
check(RoadPalette.classify(white,w:101,h:101)[50*101+50]==1,"white ordinary road")
check(RoadPalette.classify([UInt32](repeating:0xffb9a069,count:49),w:7,h:7).allSatisfy{$0 != 10},"flat dark warm pavement not casing")
func fixture(_ file: URL, count expected: Int) -> Data {
    guard let bytes=try? Data(contentsOf:file) else {
        print("FAIL: required fixture missing or unreadable: \(file.path)");exit(1)
    }
    check(bytes.count==expected,"fixture size mismatch: \(file.path) (expected \(expected), got \(bytes.count))")
    return bytes
}
let testRoot=URL(fileURLWithPath:CommandLine.arguments[1])
let neighbors=[-4,-3,-2,-1,1,2,3,4]
var tie=[UInt8](repeating:0,count:9)
for p in [0,2,6] {tie[p]=9};for p in [1,3,5] {tie[p]=8}
check(RoadPalette.propagatedLabel(tie,at:4,offsets:neighbors)==9,"tied votes pick first neighbor")
tie[0]=0;tie[2]=0;tie[6]=0;tie[1]=0
check(RoadPalette.propagatedLabel(tie,at:4,offsets:neighbors)==0,"two votes do not propagate")
let toneBytes=fixture(testRoot.appendingPathComponent("fixtures/multitone-40.argb32le"),count:40*40*4)
let toneRaw=toneBytes.withUnsafeBytes {Array($0.bindMemory(to:UInt32.self))}
let toneExpected=[UInt8](fixture(testRoot.appendingPathComponent("fixtures/multitone-40.expected.idx"),count:40*40))
let toneActual=RoadPalette.classify(toneRaw,w:40,h:40)
for y in 3..<37 {for x in 3..<37 {let p=y*40+x;check(toneActual[p]==toneExpected[p],"portable propagation and fallback fixture")}}
let fullWidth=100, fullHeight=90, windowWidth=80, windowHeight=70
var overlapSource=[UInt32](repeating:0xffffffff,count:fullWidth*fullHeight)
for y in 20..<58 {for x in 16..<72 {
    overlapSource[y*fullWidth+x] = x<34 ? 0xfff7c36b : x<52 ? 0xfff7df84 : 0xfffaeda6
}}
func classifyWindow(_ x0: Int, _ y0: Int) -> [UInt8] {
    var pixels=[UInt32](); pixels.reserveCapacity(windowWidth*windowHeight)
    for y in y0..<(y0+windowHeight) {
        pixels.append(contentsOf:overlapSource[(y*fullWidth+x0)..<(y*fullWidth+x0+windowWidth)])
    }
    return RoadPalette.classify(pixels,w:windowWidth,h:windowHeight)
}
let overlapA=classifyWindow(0,0), overlapB=classifyWindow(12,8)
var overlapLabels=Set<UInt8>()
for y in 11..<67 {for x in 15..<77 {
    let a=overlapA[y*windowWidth+x], b=overlapB[(y-8)*windowWidth+x-12]
    check(a==b,"offset windows agree within common three-pixel border")
    overlapLabels.insert(a)
}}
check([UInt8(8),9,11].allSatisfy {overlapLabels.contains($0)},"overlap includes all three warm tones")
let nativeBytes=fixture(testRoot.appendingPathComponent("fixtures/mingbo-native-road-13x13.argb32le"),count:13*13*4)
let nativeRaw=nativeBytes.withUnsafeBytes {Array($0.bindMemory(to:UInt32.self))}
let native=RoadPalette.classify(nativeRaw,w:13,h:13)
check(native[6*13+7]==8 && native[6*13+6]==10 && native[6*13+5]==9,"portable native orange/casing/yellow probes")
for (color,expected) in [(UInt32(0xfff7c36b),UInt8(8)),(UInt32(0xfff7df84),UInt8(9))] {
    let solid=RoadPalette.classify([UInt32](repeating:color,count:13*13),w:13,h:13)
    check(solid[6*13+6]==expected,"solid measured warm pavement retains its road category")
}
print("PASS portable road palette core regressions (native 13x13 fixture)")
check(RoadPalette.packetVersion(semantic)==2 && RoadPalette.isCurrentPacket(semantic),"new packets are v2")
let v2eleven=packet([UInt8](repeating:11,count:n*n))
check(RasterPacket.valid(v2eleven),"v2 accepts slot 11")
let v1eleven=RoadPalette.forWire(v2eleven,paletteVersion:1,buildingsSupported:false)
check(RoadPalette.packetVersion(v1eleven)==1 && RasterPacket.decode(v1eleven)!.allSatisfy{$0==9},"v2 downgrade")
check(RoadPalette.packetVersion(RoadPalette.encode(RasterPacket.decode(v1eleven)!,like:v1eleven))==1,"encode like preserves v1")
var alteredPalette=semantic
for p in [16,17,20,21,40,41,42,43] {alteredPalette[p] ^= 0x5a}
check(RasterPacket.valid(alteredPalette),"modified v2 palette remains valid")
for roofs in [false,true] {
    let downgraded=RoadPalette.forWire(alteredPalette,paletteVersion:1,buildingsSupported:roofs)
    let actual=[UInt8](downgraded)
    let expected=[0x2125,0xa555,0x3a89,0x428b,0x31c7,0x528a,0x31c7,0x528a,0xc659,0x73cf,0x2125,0,0,0,0x4d4e,roofs ? 0x5211 : 0x5201]
    check((0..<16).allSatisfy { RasterPacket.u16(actual,16+2*$0)==expected[$0] },"downgrade rebuilds full canonical v1 palette")
}
let v1roof=RoadPalette.forWire(semantic,paletteVersion:1,buildingsSupported:true)
check(RasterPacket.valid(v1roof) && RoadPalette.packetVersion(v1roof)==1 && !RoadPalette.isCurrentPacket(v1roof) && RoadPalette.hasRoofs(v1roof),"v1 roof downgrade")
check(RoadPalette.packetVersion(RoadPalette.compactBase(v1roof))==1 && !RoadPalette.hasRoofs(RoadPalette.compactBase(v1roof)),"compact preserves v1")
let v1paint=FastBuildings.packet(base:RoadPalette.compactBase(v1roof),patches:[0:Data(repeating:1,count:90000)])
check(RasterPacket.valid(v1paint) && RoadPalette.packetVersion(v1paint)==1,"building composition preserves v1")
var badV1=v1eleven;badV1[48]=(badV1[48]&0xf0)|11
check(!RasterPacket.valid(badV1),"v1 rejects slot 11")
check(RoadPalette.packetVersion(RoadPalette.encode([UInt8](repeating:1,count:count),like:custom))==2,"ordinary input encodes as new version")
let flatLegacy=RoadPalette.forWire(v2eleven,paletteVersion:0,buildingsSupported:false)
check(RasterPacket.decode(flatLegacy)!.allSatisfy{$0==1},"slot 11 legacy fallback")
guard CommandLine.arguments.count>2 else {
    print("Real corpus: not requested (use --real-corpus)");exit(0)
}
let corpus=URL(fileURLWithPath:CommandLine.arguments[2])
let scenes=["fresh-mingbo/06-mingbo","fresh-default-five/01-dense","fresh-default-five/02-low-density","fresh-default-five/03-diagonal","fresh-default-five/04-interchange","fresh-default-five/05-waterfront"]
var sceneCount=0
for scene in scenes {
    let folder=corpus.appendingPathComponent(scene)
    let file=folder.appendingPathComponent("base-sampled-2m.argb32le")
    let bytes=fixture(file,count:count*4)
    let raw=bytes.withUnsafeBytes {Array($0.bindMemory(to:UInt32.self))}
    let start=Date(), classified=RoadPalette.classify(raw,w:n,h:n)
    let base=packet(classified)
    check(RasterPacket.valid(base) && base.count<=480000,"real scene valid transfer")
    print("scene \(scene) bytes=\(base.count) seconds=\(Date().timeIntervalSince(start))")
    if scene.hasSuffix("04-interchange") {
        let expected=[UInt8](fixture(corpus.appendingPathComponent("road-multitone-preview/04-interchange/candidate-offline.idx"),count:count))
        let old=[UInt8](fixture(corpus.appendingPathComponent("road-palette-qa/04-interchange/building.idx"),count:count))
        for y in 3..<(n-3) {for x in 3..<(n-3) {let p=y*n+x; if old[p] == 8 || old[p] == 9 {check(classified[p] == expected[p],"Shanghai multitone gold interior")}}}
    }
    if scene.hasSuffix("06-mingbo") {
        let expected=[UInt8](fixture(corpus.appendingPathComponent("road-multitone-preview/06-mingbo/candidate-offline.idx"),count:count))
        let old=[UInt8](fixture(corpus.appendingPathComponent("road-palette-qa/06-mingbo/building.idx"),count:count))
        for y in 3..<(n-3) {for x in 3..<(n-3) {let p=y*n+x; if old[p] == 8 || old[p] == 9 {check(classified[p] == expected[p],"multitone gold interior")}}}
        var patches=[Int:Data]()
        for q in 0..<4 {
            let b=fixture(folder.appendingPathComponent("building-\(q)-sampled-2m.argb32le"),count:600*600*4)
            patches[q]=try! FastBuildings.simplify(b.withUnsafeBytes {Array($0.bindMemory(to:UInt32.self))})
        }
        let composed=FastBuildings.packet(base:base,patches:patches)
        check(RasterPacket.valid(composed),"real buildings valid")
        let built=RasterPacket.decode(composed)!
        for p in classified.indices where classified[p]==10 {check(built[p]==10,"building cannot overwrite casing")}

        print("Mingbo casing \(classified.filter{$0==10}.count), building overwrite 0")
    }
    sceneCount+=1
}
check(sceneCount==6,"all six frozen scenes present")
print("PASS real-corpus road palette regressions: \(sceneCount) / 6 scenes")
