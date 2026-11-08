import Foundation

/// Source road colours, not road elevation. Slots 14/15 are metadata, never pixels.
enum RoadPalette {
    static func packetVersion(_ data: Data) -> Int {
        guard data.count >= 48 else { return 0 }
        let p=data.startIndex, marker=data[p+46]
        guard data[p+14] == 0xd0 && data[p+15] == 0x87 && data[p+44] == 0x4e && data[p+45] == 0x4d && data[p+47] == 0x52 && [1,2,17,18].contains(marker) else { return 0 }
        return Int(marker & 15)
    }
    static func isPacket(_ data: Data) -> Bool { packetVersion(data) != 0 }
    static func isCurrentPacket(_ data: Data) -> Bool { packetVersion(data) == 2 }
    static func hasRoofs(_ data: Data) -> Bool { isPacket(data) && data[data.startIndex+46] & 0x10 != 0 }

    private static func warm(_ c: UInt32) -> Bool {
        let r=Int(c>>16&255),g=Int(c>>8&255),b=Int(c&255)
        return r>0 && r>=g && g>b && (r-b)*100>r*18 && (g-b)*6>=r-b
    }
    private static func sourceCasing(_ raw: [UInt32], w: Int, h: Int) -> [UInt8] {
        var result=[UInt8](repeating:0,count:raw.count)
        guard w>=5,h>=5 else {return result}
        let candidate=raw.map {warm($0) && ($0>>16&255)<=242}
        func bright(_ q: Int, _ p: Int) -> Bool {
            let a=raw[p],b=raw[q]
            let ar=Int(a>>16&255),ag=Int(a>>8&255),ab=Int(a&255)
            let br=Int(b>>16&255),bg=Int(b>>8&255),bb=Int(b&255)
            return warm(b) && br>=ar+8 && 30*(br-ar)+59*(bg-ag)+11*(bb-ab)>=1000 &&
                abs((ag-ab)*100/(ar-ab)-(bg-bb)*100/(br-bb))<=25
        }
        for y in 2..<(h-2) {for x in 2..<(w-2) {
            let p=y*w+x
            guard candidate[p] else {continue}
            for (dx,dy) in [(1,0),(0,1),(1,1),(1,-1)] {
                let normal=dy*w+dx,tangent=dx*w-dy
                guard candidate[p+tangent] || candidate[p-tangent] else {continue}
                var plus=false,minus=false,contrast=false
                for distance in 1...2 {
                    let a=p+distance*normal,b=p-distance*normal
                    if !candidate[a] {plus=true};if !candidate[b] {minus=true}
                    if bright(a,p) || bright(b,p) {contrast=true}
                }
                if plus && minus && contrast {result[p]=1;break}
            }
        }}
        return result
    }
    static func propagatedLabel(_ labels: [UInt8], at p: Int, offsets: [Int]) -> UInt8 {
        var n8=0,n9=0,n11=0
        for d in offsets {
            switch labels[p+d] {case 8:n8+=1;case 9:n9+=1;case 11:n11+=1;default:break}
        }
        let best=max(n8,max(n9,n11))
        if best<3 {return 0}
        for d in offsets {
            let v=labels[p+d]
            if (v==8 && n8==best) || (v==9 && n9==best) || (v==11 && n11==best) {return v}
        }
        return 0
    }
    static func classify(_ raw: [UInt32], w: Int, h: Int) -> [UInt8] {
        guard w>0,h>0,raw.count==w*h else {return []}
        let protected=sourceCasing(raw,w:w,h:h)
        var indices=MapGeo.classifyAmapBase(raw,w:w,h:h,protectedRoadPixels:protected)
        for p in raw.indices {
            if protected[p] != 0 {indices[p]=10}
            else if indices[p]==1 && warm(raw[p]) {
                let c=raw[p],r=Int(c>>16&255),g=Int(c>>8&255),b=Int(c&255)
                indices[p]=(g-b)*60 <= (r-b)*42 ? 8:9
            }
        }
        if w >= 3 && h >= 3 {
            var labels=[UInt8](repeating:0,count:raw.count)
            let offsets=[-w-1,-w,-w+1,-1,1,w-1,w,w+1]
            for y in 1..<(h-1) { for x in 1..<(w-1) {
                let p=y*w+x
                if indices[p] != 8 && indices[p] != 9 {continue}
                let c=raw[p]
                var rmin=Int(c>>16&255),rmax=rmin,gmin=Int(c>>8&255),gmax=gmin,bmin=Int(c&255),bmax=bmin
                var stable=true
                for d in offsets {
                    let q=p+d
                    if indices[q] != 8 && indices[q] != 9 {stable=false;break}
                    let v=raw[q],r=Int(v>>16&255),g=Int(v>>8&255),b=Int(v&255)
                    rmin=min(rmin,r);rmax=max(rmax,r);gmin=min(gmin,g);gmax=max(gmax,g);bmin=min(bmin,b);bmax=max(bmax,b)
                    if rmax-rmin>12 || gmax-gmin>12 || bmax-bmin>12 {stable=false;break}
                }
                if stable {
                    let l=30*Int(c>>16&255)+59*Int(c>>8&255)+11*Int(c&255)
                    labels[p]=l<21400 ? 8 : l<22600 ? 9 : 11
                }
            }}
            for _ in 0..<2 {
                let before=labels
                for y in 1..<(h-1) { for x in 1..<(w-1) {
                    let p=y*w+x
                    if (indices[p] != 8 && indices[p] != 9) || before[p] != 0 {continue}
                    labels[p]=propagatedLabel(before,at:p,offsets:offsets)
                }}
            }
            for p in indices.indices where labels[p] != 0 {indices[p]=labels[p]}
        }
        return indices
    }
    private static func palette(version: Int, roofs: Bool) -> [Int] {
        func rgb(_ c: Int)->Int {((c>>8)&0xf800)|((c>>5)&0x07e0)|((c>>3)&31)}
        return [0x252628,0xa6a8a8,0x3f5149,0x42535e,0x36383a,0x505255,0x36383a,0x505255,version == 1 ? 0xc6caca : 0x707a7a,version == 1 ? 0x707a7a : 0x9aa4a4,0x252628,version == 1 ? 0 : 0xc6caca].map(rgb)+[0,0,0x4d4e,0x5200 | (roofs ? 0x10 : 0) | version]
    }
    static func encode(frameId: Int, x0: Int, y0: Int, w: Int, h: Int, indices: [UInt8], version: Int = 2) -> Data {
        guard (1...2).contains(version),w>0,h>0,indices.count==w*h,indices.allSatisfy({$0 <= (version == 1 ? 10 : 11)}) else {return Data()}
        let roofs=indices.contains { (4...7).contains($0) }
        let pal=palette(version:version,roofs:roofs)
        return MapGeo.encodeRaster(frameId:frameId,x0:x0,y0:y0,w:w,h:h,mmPerPx:2000,idx:indices,pal:pal)
    }
    static func encode(_ indices: [UInt8], like base: Data) -> Data {
        guard RasterPacket.valid(base) else {return base}
        let b=[UInt8](base)
        return encode(frameId:RasterPacket.u16(b,0),x0:RasterPacket.i32(b,2),y0:RasterPacket.i32(b,6),w:RasterPacket.size,h:RasterPacket.size,indices:indices,version:isPacket(base) ? packetVersion(base) : 2)
    }
    static func compactBase(_ data: Data) -> Data {forWire(data,paletteVersion:packetVersion(data),buildingsSupported:false)}
    /// Merge transformed runs directly; never expand a full frame on the sending thread.
    static func forWire(_ data: Data, paletteVersion: Int, buildingsSupported: Bool) -> Data {
        guard isPacket(data) else {return buildingsSupported ? data:RasterPacket.forLegacy(data)}
        guard RasterPacket.valid(data) else {return data}
        let paletteSupported=paletteVersion > 0
        let version=min(packetVersion(data),max(0,paletteVersion))
        if version == packetVersion(data) && (buildingsSupported || !hasRoofs(data)) {return data}
        let raw=[UInt8](data)
        var result=Data(raw.prefix(paletteSupported ? 48:16))
        let keepRoofs=buildingsSupported && hasRoofs(data)
        if paletteSupported {
            result[46]=UInt8(version | (keepRoofs ? 0x10:0))
            if version == 1 && packetVersion(data) == 2 {
                for (i,color) in palette(version:1,roofs:keepRoofs).enumerated() {
                    result[16+i*2]=UInt8(color&255); result[17+i*2]=UInt8(color>>8)
                }
            }
        }
        else {let flags=2000 | (keepRoofs ? RasterPacket.flag:0);result[14]=UInt8(flags&255);result[15]=UInt8(flags>>8)}
        var p=48,last=UInt8(255),run=0
        func flush() {
            while run>0 {
                let n=min(271,run)
                if n<=15 {result.append(UInt8((n-1)<<4)|last)}
                else {result.append(0xf0|last);result.append(UInt8(n-16))}
                run-=n
            }
        }
        while p<raw.count {
            let v=raw[p];p+=1
            var n=Int(v>>4)+1
            if v>>4==15 {n+=Int(raw[p]);p+=1}
            var color=v&15
            if color>=8 && !paletteSupported {color=1}
            else if color == 11 && version == 1 {color=9}
            else if (4...7).contains(color) && !buildingsSupported {color &= 2}
            if last != color {flush();last=color}
            run+=n
        }
        flush();return result
    }
}
