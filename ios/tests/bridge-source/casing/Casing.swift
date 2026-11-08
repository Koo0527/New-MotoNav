import Foundation

extension MapGeo {
    // Offline candidate: preserve only observed dark warm pixels, never extend lines.
    static func sourceCasing(_ raw: [UInt32], w: Int, h: Int, local: Bool) -> [UInt8] {
        precondition(w >= 5 && h >= 5 && raw.count == w*h)
        func warm(_ c: UInt32) -> Bool {
            let r=Int(c>>16&255), g=Int(c>>8&255), b=Int(c&255)
            // HSV hue 10...60 and saturation > .18, with red as the maximum.
            return r>0 && r>=g && g>b && (r-b)*100>r*18 && (g-b)*6 >= r-b
        }
        var candidate = [UInt8](repeating: 0, count: raw.count)
        for p in raw.indices where warm(raw[p]) && (raw[p]>>16&255)<=242 { candidate[p]=1 }
        if !local { return candidate }
        var result = [UInt8](repeating: 0, count: raw.count)
        func bright(_ q: Int, _ p: Int) -> Bool {
            let a=raw[p], b=raw[q]
            let ar=Int(a>>16&255), ag=Int(a>>8&255), ab=Int(a&255)
            let br=Int(b>>16&255), bg=Int(b>>8&255), bb=Int(b&255)
            // Same warm family and a measured contrast; AA colours remain eligible.
            return warm(b) && br>=ar+8 && 30*(br-ar)+59*(bg-ag)+11*(bb-ab)>=1000 &&
                abs((ag-ab)*100/(ar-ab) - (bg-bb)*100/(br-bb))<=25
        }
        for y in 2..<(h-2) { for x in 2..<(w-2) {
            let p=y*w+x
            guard candidate[p] != 0 else { continue }
            for (dx,dy) in [(1,0),(0,1),(1,1),(1,-1)] {
                let normal=dy*w+dx, tangent=dx*w-dy
                // Thin support: escape the dark band on both sides within two pixels,
                // and retain an observed dark neighbour along the edge.
                guard candidate[p+tangent] != 0 || candidate[p-tangent] != 0 else {continue}
                var plus=false, minus=false, contrast=false
                for distance in 1...2 {
                    let a=p+distance*normal, b=p-distance*normal
                    if candidate[a] == 0 { plus=true }
                    if candidate[b] == 0 { minus=true }
                    if bright(a,p) || bright(b,p) { contrast=true }
                }
                if plus && minus && contrast { result[p]=1; break }
            }
        } }
        return result
    }
}
