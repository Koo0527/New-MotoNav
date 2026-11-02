import Foundation

/// Protocol-compatible with Android RasterPacket: 1200², 2 m/pixel, bounded RLE.
enum RasterPacket {
    static let size = 1200, flag = 0x4000
    static func u16(_ b: [UInt8], _ p: Int) -> Int { Int(b[p]) | Int(b[p + 1]) << 8 }
    static func i32(_ b: [UInt8], _ p: Int) -> Int {
        Int(Int32(bitPattern: UInt32(b[p]) | UInt32(b[p+1]) << 8 | UInt32(b[p+2]) << 16 | UInt32(b[p+3]) << 24))
    }
    static func isBuilding(_ data: Data) -> Bool {
        let b = [UInt8](data); return b.count >= 16 && u16(b, 14) == (2000 | flag)
    }
    static func valid(_ data: Data, frame: Int, x: Int, y: Int) -> Bool {
        let b = [UInt8](data)
        guard b.count >= 17, b.count <= 480000, u16(b, 0) == frame, i32(b, 2) == x, i32(b, 6) == y,
              u16(b, 10) == size, u16(b, 12) == size, [2000, 2000 | flag, 2000 | 0x8000].contains(u16(b, 14)) else { return false }
        let customPalette = u16(b, 14) & 0x8000 != 0
        guard !customPalette || b.count >= 49 else { return false }
        var pos = customPalette ? 48 : 16, pixels = 0
        let building = u16(b, 14) == (2000 | flag)
        while pos < b.count && pixels < size * size {
            let v = Int(b[pos]); pos += 1
            if v & 15 > (customPalette ? 15 : building ? 7 : 3) { return false }
            var run = (v >> 4) + 1
            if v >> 4 == 15 {
                guard pos < b.count else { return false }
                run = 16 + Int(b[pos]); pos += 1
            }
            guard run <= size * size - pixels else { return false }
            pixels += run
        }
        return pixels == size * size && pos == b.count
    }
    static func valid(_ data: Data) -> Bool {
        let b = [UInt8](data)
        guard b.count >= 16 else { return false }
        return valid(data, frame: u16(b, 0), x: i32(b, 2), y: i32(b, 6))
    }
    /// Check RLE runs without expanding a 1.44M-pixel frame on the main thread.
    static func hasMapContent(_ data:Data)->Bool {
        guard valid(data) else{return false}
        let b=[UInt8](data)
        if u16(b,14)&0x8000 != 0{return true}
        var p=16,materials=0
        let minimum=MapGeo.minMaterialPixels(w:size,h:size)
        while p<b.count {
            let v=b[p];p+=1
            var count=Int(v>>4)+1
            if v>>4==15 {count+=Int(b[p]);p+=1}
            if v&15 != 0 {materials+=count;if materials>=minimum{return true}}
        }
        return false
    }
    static func forLegacy(_ data: Data) -> Data {
        guard isBuilding(data), valid(data) else { return data }
        var b = [UInt8](data); b[14] = UInt8(2000 & 255); b[15] = UInt8(2000 >> 8)
        var p = 16
        while p < b.count {
            let v = b[p]
            if v & 15 > 3 { b[p] = (v & 240) | (v & 2) }
            p += v >> 4 == 15 ? 2 : 1
        }
        return Data(b)
    }
    static func decode(_ data: Data) -> [UInt8]? {
        guard valid(data) else { return nil }
        let b = [UInt8](data)
        var out = [UInt8](repeating: 0, count: size * size), p = u16(b, 14) & 0x8000 != 0 ? 48 : 16, k = 0
        while p < b.count {
            let v = b[p]; p += 1
            var run = Int(v >> 4) + 1
            if v >> 4 == 15 { run += Int(b[p]); p += 1 }
            for i in k..<(k + run) { out[i] = v & 15 }; k += run
        }
        return out
    }
}

enum MapStyleTransfer {
    static func command(_ style:Int)->String {"#t,\(style),1"}
    static func matches(_ packet:Data,style:Int)->Bool {
        guard RasterPacket.valid(packet) else {return false}
        let bytes=[UInt8](packet),flags=RasterPacket.u16(bytes,14)
        if style==0 {return flags&0x8000 != 0}
        if style != 5 {return (1...9).contains(style) && flags&0x8000 == 0}
        if style==5 {
            guard flags==2000 else {return false}
            var p=16
            while p<bytes.count {
                let v=bytes[p];p+=1
                if v&15>1 {return false}
                if v>>4==15 {p+=1}
            }
        }
        return true
    }
}


enum AmapCapturePolicy {
    static func supportsBuildings(_ style: Int) -> Bool { (1...3).contains(style) }
    // SDK zoom is based on logical view bounds, not on Retina screenshot pixel count.
    // Keep the 3x drawable below 4096 pixels; 1200 points still exceeds zoom 17
    // for a 1.2km building tile. Android pixel dimensions are not iOS points.
    static func renderSize(for tileSize: Int) -> Int { tileSize == 600 ? 1200 : 720 }
    static func aligned(_ reference: [Double], _ current: [Double]) -> Bool {
        guard reference.count == 4, current.count == 4 else { return false }
        return zip(reference, current).allSatisfy { a, b in a.isFinite && b.isFinite && abs(a - b) <= 0.5 }
    }
    static func completed(_ result: AmapBuildings.Result) -> Bool { result.buildings > 0 && result.roofPixels > 0 }
}

enum AmapSampleGrid {
    /// Nearest-neighbour sampling commutes with the per-pixel building difference.
    /// Compare only the map samples, rather than millions of unused Retina pixels.
    static func sample(_ pixels: [UInt32], withoutBuildings: [UInt32]?, width: Int, height: Int,
                       left: Double, top: Double, right: Double, bottom: Double,
                       north: Double, south: Double, size: Int) throws -> [UInt32] {
        let current = try resample(pixels, width: width, height: height, left: left, top: top,
                                   right: right, bottom: bottom, north: north, south: south, size: size)
        guard let reference = withoutBuildings else { return current }
        let previous = try resample(reference, width: width, height: height, left: left, top: top,
                                    right: right, bottom: bottom, north: north, south: south, size: size)
        return try AmapBuildings.difference(without: previous, with: current)
    }
    static func resample(_ pixels: [UInt32], width: Int, height: Int, left: Double, top: Double,
                         right: Double, bottom: Double, north: Double, south: Double, size: Int) throws -> [UInt32] {
        guard width > 0, height > 0, size > 0, pixels.count == width * height,
              [left, top, right, bottom, north, south].allSatisfy({ $0.isFinite }), left >= 0, top >= 0,
              right <= Double(width), bottom <= Double(height), right > left, bottom > top,
              north > south, north < 85, south > -85 else { throw MapProcessingError.invalid("截图没有完整覆盖地图范围") }
        func mercator(_ lat: Double) -> Double { log(tan(.pi / 4 + lat * .pi / 360)) }
        let mn = mercator(north), ms = mercator(south)
        var cols = [Int](repeating: 0, count: size), rows = cols
        for i in 0..<size {
            let u = (Double(i) + 0.5) / Double(size)
            cols[i] = Int(floor(left + u * (right - left)))
            rows[i] = Int(floor(top + (mn - mercator(north + (south - north) * u)) / (mn - ms) * (bottom - top)))
            guard cols[i] >= 0, cols[i] < width, rows[i] >= 0, rows[i] < height else { throw MapProcessingError.invalid("截图采样越界") }
        }
        var result = [UInt32](repeating: 0, count: size * size)
        for y in 0..<size { for x in 0..<size {
            let c = pixels[rows[y] * width + cols[x]]
            guard c >> 24 >= 250 else { throw MapProcessingError.invalid("截图仍有透明区域") }
            result[y * size + x] = c
        } }
        return result
    }
}

enum MapProcessingError: LocalizedError {
    case invalid(String), cancelled
    var errorDescription: String? {
        switch self { case .invalid(let message): return message; case .cancelled: return "地图任务已取消" }
    }
}

enum AmapBuildings {
    struct Result { let pixels: [UInt8]; let buildings: Int; let roofPixels: Int }
    static func colorDifference(_ a: UInt32, _ b: UInt32) -> Int {
        let r = abs(Int((a >> 16) & 255) - Int((b >> 16) & 255))
        let g = abs(Int((a >> 8) & 255) - Int((b >> 8) & 255))
        let blue = abs(Int(a & 255) - Int(b & 255))
        return max(r, max(g, blue))
    }
    static func difference(without: [UInt32], with: [UInt32]) throws -> [UInt32] {
        guard without.count == with.count else { throw MapProcessingError.invalid("楼块截图尺寸发生变化") }
        return try zip(without, with).map { a, b in
            guard a >> 24 >= 250, b >> 24 >= 250 else { throw MapProcessingError.invalid("楼块截图含透明区域") }
            let delta = max(abs(Int(a >> 16 & 255) - Int(b >> 16 & 255)),
                            max(abs(Int(a >> 8 & 255) - Int(b >> 8 & 255)), abs(Int(a & 255) - Int(b & 255))))
            return delta >= 4 ? 0xffff00ff : 0xfff8f9fa
        }
    }
    static func marked(_ c: UInt32) -> Bool {
        let r = c >> 16 & 255, g = c >> 8 & 255, b = c & 255
        return r >= 140 && b >= 140 && g * 2 < min(r, b)
    }
    static func apply(_ raw: [UInt32], base: [UInt8], w: Int, h: Int) throws -> Result {
        guard w > 0, h > 0, w * h == raw.count, raw.count == base.count else { throw MapProcessingError.invalid("楼块图尺寸不一致") }
        var mask = raw.map { marked($0) ? UInt8(1) : 0 }
        guard mask.filter({ $0 == 1 }).count <= raw.count / 2 else { throw MapProcessingError.invalid("建筑图层覆盖异常") }
        var component: [Int] = []; component.reserveCapacity(raw.count / 8)
        var buildings = 0
        guard mask.reduce(0, { $0 + Int($1) }) <= mask.count / 2 else {throw MapProcessingError.invalid("建筑图层覆盖异常")}
        for i in mask.indices where mask[i] == 1 {
            component.removeAll(keepingCapacity: true); component.append(i); mask[i] = 2
            var head = 0, minX = i % w, maxX = minX, minY = i / w, maxY = minY
            while head < component.count {
                let p = component[head], x = p % w, y = p / w; head += 1
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
                func visit(_ n: Int) { if mask[n] == 1 { mask[n] = 2; component.append(n) } }
                if x > 0 { visit(p - 1) }; if x + 1 < w { visit(p + 1) }
                if y > 0 { visit(p - w) }; if y + 1 < h { visit(p + w) }
            }
            let bw = maxX - minX + 1, bh = maxY - minY + 1
            let valid = component.count >= 6 && component.count <= raw.count / 8 && bw >= 2 && bh >= 2 && component.count * 8 >= bw * bh
            if valid { buildings += 1 }
            for p in component { mask[p] = valid ? 3 : 4 }
        }
        var out = base, count = 0
        for y in 0..<h { for x in 0..<w {
            let i = y * w + x
            if mask[i] != 3 || (base[i] != 0 && base[i] != 2) { continue }
            let edge = x == 0 || x + 1 == w || y == 0 || y + 1 == h || mask[i-1] != 3 || mask[i+1] != 3 || mask[i-w] != 3 || mask[i+w] != 3
            out[i] = (edge ? 5 : 4) | (base[i] & 2); count += 1
        } }
        return Result(pixels: out, buildings: buildings, roofPixels: count)
    }
    /// Preserve known roofs in overlapping packets. This does not mark a partial layer complete.
    static func carry(_ incoming: Data, known: Data?) -> Data {
        guard let known = known, RasterPacket.valid(incoming), RasterPacket.valid(known), RasterPacket.isBuilding(known) else { return incoming }
        let a = [UInt8](incoming), b = [UInt8](known)
        guard RasterPacket.u16(a, 0) == RasterPacket.u16(b, 0) else { return incoming }
        let ox = Int(floor(Double(RasterPacket.i32(a, 2) - RasterPacket.i32(b, 2) + 1) / 2))
        let oy = Int(floor(Double(RasterPacket.i32(b, 6) - RasterPacket.i32(a, 6) + 1) / 2))
        let n = RasterPacket.size
        guard abs(ox) < n, abs(oy) < n, var current = RasterPacket.decode(incoming), let previous = RasterPacket.decode(known) else { return incoming }
        var retained = false
        for y in max(0, -oy)..<min(n, n - oy) { for x in max(0, -ox)..<min(n, n - ox) {
            let i = y * n + x, old = previous[(y + oy) * n + x + ox]
            if (current[i] == 0 || current[i] == 2) && old >= 4 && old <= 7 {
                current[i] = 4 | (old & 1) | (current[i] & 2); retained = true
            }
        } }
        guard retained else { return incoming }
        let packet = MapGeo.encodeRaster(frameId: RasterPacket.u16(a, 0), x0: RasterPacket.i32(a, 2), y0: RasterPacket.i32(a, 6), w: n, h: n, mmPerPx: 2000 | RasterPacket.flag, idx: current)
        return RasterPacket.valid(packet) ? packet : incoming
    }
}


/// Keep essential roads in front of optional roofs on a measured, slow link.
enum MapDeliveryPolicy {
    static func roofsFit(kmh:Int,bytes:Int,rate:Double?,coverageSeconds:Double,nextBaseBytes:Int=0)->Bool {
        if kmh<6 {return true}
        guard let rate=rate,rate.isFinite,rate>0,coverageSeconds.isFinite,coverageSeconds>0 else {return false}
        // The measured rate already includes ATT waits and competing position traffic.
        // Reserve the next road packet plus a margin before this viewport expires.
        return Double(bytes+max(0,nextBaseBytes))/rate+1<=coverageSeconds
    }
    /// Unlike a colour-only legacy conversion, re-RLE the merged runs so the
    /// missing roof layer actually reduces bytes. No 1.44M-pixel expansion.
    static func compactBase(_ data:Data)->Data {
        guard RasterPacket.isBuilding(data),RasterPacket.valid(data) else {return data}
        let raw=[UInt8](data)
        var result=Data(raw.prefix(16));result[14]=UInt8(2000&255);result[15]=UInt8(2000>>8)
        var p=16,last=UInt8(255),run=0
        func flush() {
            while run>0 {
                let count=min(271,run)
                if count<=15 {result.append(UInt8((count-1)<<4)|last)}
                else {result.append(0xf0|last);result.append(UInt8(count-16))}
                run-=count
            }
        }
        while p<raw.count {
            let v=raw[p];p+=1
            var n=Int(v>>4)+1
            if v>>4==15 {n+=Int(raw[p]);p+=1}
            let original=v&15,color=original>3 ? original&2:original
            if last != color {flush();last=color}
            run+=n
            while run>=271 {result.append(0xf0|last);result.append(255);run-=271}
        }
        flush();return result
    }
}

struct BuildingCoverage: Codable, Equatable {
    var qualityVersion: Int = FastBuildings.qualityVersion
    var checkedMask: UInt8 = 0
    var isComplete: Bool { checkedMask == 15 }
    static let legacyFull = BuildingCoverage(qualityVersion: 0, checkedMask: 15)
}
struct BuildingUpdate { let bytes: Data; let coverage: BuildingCoverage }
struct BuildingView { let x: Double, y: Double, bearing: Double?, radius: Double }
struct BuildingCheckpoint { let coverage: BuildingCoverage; let patches: [Int: Data] }
enum FastBuildings {
    static let qualityVersion = 2
    static func order(cx: Double, cy: Double, view: BuildingView?) -> [Int] {
        let v = view.flatMap { $0.x.isFinite && $0.y.isFinite && $0.radius.isFinite && $0.radius>=0 ? $0 : nil }
        func score(_ i: Int) -> (Double, Double, Double) {
            let x = cx + (i % 2 == 0 ? -600.0 : 600.0), y = cy + (i < 2 ? 600.0 : -600.0)
            let dx = x - (v?.x ?? cx), dy = y - (v?.y ?? cy)
            var overlap=0.0
            if let v=v {
                let width:Double=max(0,min(x+600,v.x+v.radius)-max(x-600,v.x-v.radius))
                let height:Double=max(0,min(y+600,v.y+v.radius)-max(y-600,v.y-v.radius))
                overlap=width*height
            }
            let a = (v?.bearing ?? 0) * .pi / 180
            let forward = v?.bearing?.isFinite == true ? dx * sin(a) + dy * cos(a) : 0
            return (-overlap, -forward, hypot(dx,dy))
        }
        return [0,1,2,3].sorted { let a=score($0),b=score($1); return a == b ? $0 < $1 : a < b }
    }
    static func simplify(_ raw: [UInt32]) throws -> Data {
        guard raw.count == 600*600 else { throw MapProcessingError.invalid("楼块图尺寸不一致") }
        var mask = [UInt8](repeating: 0, count: 300*300)
        for y in 0..<300 { for x in 0..<300 {
            let p=y*1200+x*2
            let count=[p,p+1,p+600,p+601].reduce(0) { $0 + (AmapBuildings.marked(raw[$1]) ? 1 : 0) }
            mask[y*300+x] = count >= 2 ? 1 : 0
        } }
        guard mask.reduce(0, { $0 + Int($1) }) <= mask.count / 2 else {throw MapProcessingError.invalid("建筑图层覆盖异常")}
        for i in mask.indices where mask[i] == 1 {
            var cells=[i],head=0;mask[i]=2
            while head<cells.count {
                let p=cells[head];head+=1
                for n in [p%300>0 ? p-1 : -1,p%300<299 ? p+1 : -1,p>=300 ? p-300 : -1,p<89700 ? p+300 : -1] where n>=0 {
                    if mask[n]==1 {mask[n]=2;cells.append(n)}
                }
            }
            guard cells.count <= mask.count / 8 else {throw MapProcessingError.invalid("建筑连通区域异常")}
            for p in cells {mask[p] = cells.count>=4 ? 3 : 0}
        }
        return clean(Data(mask.map { $0 == 3 ? 1 : 0 }))
    }
    /// Remove only a one-cell leaf on a supported flat edge. Its sole cardinal
    /// attachment and empty outer ring preserve components and holes.
    static func clean(_ patch: Data) -> Data {
        guard patch.count == 300*300 else { return patch }
        let source = [UInt8](patch)
        guard source.allSatisfy({ $0 <= 1 }) else { return patch }
        var out = source
        let directions = [(-300,1),(300,1),(-1,300),(1,300)]
        for y in 1..<299 { for x in 1..<299 {
            let p = y*300+x
            guard source[p] == 1 else { continue }
            let ring = [-301,-300,-299,-1,1,299,300,301]
            guard ring.reduce(0, { $0 + Int(source[p+$1]) }) == 3 else { continue }
            for (toward,side) in directions {
                if source[p+toward] == 1 && source[p+toward-side] == 1 && source[p+toward+side] == 1 {
                    out[p] = 0
                    break
                }
            }
        } }
        return Data(out)
    }
    static func packet(base: Data, patches: [Int: Data]) -> Data {
        guard var pixels=RasterPacket.decode(base) else {return base}
        var mask=[UInt8](repeating:0,count:600*600)
        for (i,patch) in patches where (0..<4).contains(i) && patch.count==90000 {
            let tile=[UInt8](patch),ox=(i%2)*300,oy=(i/2)*300
            for y in 0..<300 {for x in 0..<300 {mask[(oy+y)*600+ox+x]=tile[y*300+x]}}
        }
        var roofs=false
        for y in 0..<1200 {for x in 0..<1200 {
            let p=y*1200+x,c=(y/2)*600+x/2
            guard mask[c]==1,pixels[p]==0 || pixels[p]==2 else {continue}
            let edge=x==0 || y==0 || x==1199 || y==1199 ||
                mask[(y/2)*600+(x-1)/2] != 1 || mask[(y/2)*600+(x+1)/2] != 1 ||
                mask[((y-1)/2)*600+x/2] != 1 || mask[((y+1)/2)*600+x/2] != 1
            pixels[p]=(edge ? 5 : 4) | (pixels[p]&2);roofs=true
        }}
        let b=[UInt8](base)
        return MapGeo.encodeRaster(frameId:RasterPacket.u16(b,0),x0:RasterPacket.i32(b,2),y0:RasterPacket.i32(b,6),w:1200,h:1200,mmPerPx:2000 | (roofs ? RasterPacket.flag : 0),idx:pixels)
    }
}
