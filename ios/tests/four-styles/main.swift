import Foundation

func check(_ value: @autoclosure () -> Bool, _ message: String) {
    if !value() { fatalError(message) }
}
let n = 1200
var raw = [UInt32](repeating: 0xffeeeeee,count:n*n)
for y in 0..<n { for x in 590..<610 { raw[y*n+x] = 0xffffffff } }
for y in 50..<200 { for x in 50..<200 { raw[y*n+x] = 0xffaaccee } }
for y in 250..<400 { for x in 50..<200 { raw[y*n+x] = 0xff99bb88 } }
let road = MapStyles.minimal(raw,size:n)
check(road[600*n+600] == 1,"white road must remain")
check(road[100*n+100] == 0,"water must disappear")
check(road[300*n+100] == 0,"green area must disappear")
check(road.allSatisfy { $0 <= 1 },"minimal uses only roads/background")

// 极简黑白一格宽细路：清理/平滑不能把整条路删掉。
func fineMask(_ draw: (inout [UInt32]) -> Void) -> [UInt8] {
    var pixels = [UInt32](repeating: 0xffeeeeee, count: n*n)
    draw(&pixels)
    return MapStyles.minimal(pixels, size: n)
}
func roadCount(_ mask: [UInt8]) -> Int { mask.reduce(0) { $0 + ($1 == 1 ? 1 : 0) } }
let horizontal = fineMask { p in for x in 540..<660 { p[600*n+x] = 0xffffffff } }
check(roadCount(horizontal) == 120, "one-cell horizontal road must stay, got \(roadCount(horizontal))")
let vertical = fineMask { p in for y in 540..<660 { p[y*n+600] = 0xffffffff } }
check(roadCount(vertical) == 120, "one-cell vertical road must stay, got \(roadCount(vertical))")
let diagonal = fineMask { p in for i in 0..<120 { p[(540+i)*n+540+i] = 0xffffffff } }
check(roadCount(diagonal) == 120, "one-cell diagonal road must stay, got \(roadCount(diagonal))")
let shortBranch = fineMask { p in for x in 500..<700 { p[600*n+x] = 0xffffffff }; for y in 600..<640 { p[y*n+600] = 0xffffffff } }
check(roadCount(shortBranch) >= 239, "short one-cell branch must stay, got \(roadCount(shortBranch))")
let speck = fineMask { p in for y in 600..<603 { for x in 600..<603 { p[y*n+x] = 0xffffffff } } }
check(roadCount(speck) == 0, "3x3 speck must be removed, got \(roadCount(speck))")
let dots = fineMask { p in for x in stride(from: 540, to: 660, by: 3) { p[600*n+x] = 0xffffffff } }
check(roadCount(dots) == 0, "isolated dots must be removed, got \(roadCount(dots))")
let q = MapStyles.original(raw)
check(q.palette.count == 16 && q.indices.count == raw.count,"palette bounds")
check(q.palette[Int(q.indices[600*n+600])] == 0xffff,"original keeps white roads")
check(q.indices[100*n+100] != q.indices[300*n+100],"original preserves distinct colors")
let packet = MapGeo.encodeRaster(frameId:1,x0:-1200,y0:1200,w:n,h:n,mmPerPx:2000,idx:q.indices,pal:q.palette)
check(RasterPacket.valid(packet),"original palette packet validates")
check(MapStyleTransfer.command(0)=="#t,0,1","native style switch invalidates the firmware's old recoloured map")
check(MapStyleTransfer.matches(packet,style:0),"native style accepts its palette data")
check(!MapStyleTransfer.matches(packet,style:1),"Vice City cannot reuse native palette data")
let minimalPacket=MapGeo.encodeRaster(frameId:1,x0:-1200,y0:1200,w:n,h:n,mmPerPx:2000,idx:road)
check(MapStyleTransfer.matches(minimalPacket,style:5),"minimal accepts only its independent road mask")
check(!MapStyleTransfer.matches(minimalPacket,style:0),"native style cannot display a recoloured old mask")
var wrongMinimal=road;wrongMinimal[0]=2
let wrongPacket=MapGeo.encodeRaster(frameId:1,x0:-1200,y0:1200,w:n,h:n,mmPerPx:2000,idx:wrongMinimal)
check(!MapStyleTransfer.matches(wrongPacket,style:5),"minimal must not reuse a cached park/building texture")
check(RasterPacket.decode(packet) == q.indices,"original palette packet roundtrip")
check(!RasterPacket.valid(Data(packet.dropLast())),"truncated palette packet is rejected")
var corrupt = packet; corrupt[10] = 0
check(!RasterPacket.valid(corrupt),"invalid dimensions rejected")
print("PASS four independent style pipeline checks")

for style in [1,2,3,4,6,7,8,9] {
    check(MapStyleTransfer.matches(minimalPacket,style:style),"classified map remains compatible with legacy firmware style \(style)")
    check(!MapStyleTransfer.matches(packet,style:style),"classified styles must reject native palette data")
    check(MapStyleTransfer.command(style)=="#t,\(style),1","switching style invalidates old receiver data")
}
check(!MapStyleTransfer.matches(minimalPacket,style:10),"satellite does not consume classified raster packets")
check(!MapStyleTransfer.matches(minimalPacket,style:11),"Dragon radar does not consume base maps")
check(!MapStyleTransfer.matches(minimalPacket,style:-1) && !MapStyleTransfer.matches(minimalPacket,style:12),"unknown styles are rejected")
print("PASS restored legacy style material/palette isolation")
