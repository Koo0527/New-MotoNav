// Host-only prototype. Deliberately excluded from the Xcode project and production sources.
import Foundation

struct DenseMapGeometry {
    struct Point { var x: Double; var y: Double }
    struct Tables {
        // Zero means rejected; geometry stores the low ten word bits plus 1024.
        var binary = [UInt16](repeating: 0, count: 65536)
        var band: [(key: UInt32, geometry: UInt16)] = []
        var binaryCandidates = 0
        var bandCandidates = 0
        init() {
            var binaryPatterns = Set<UInt16>(), bandPatterns = Set<UInt32>()
            for normal in 0..<32 { for offset in 0..<32 {
                let nx = cos(Double(normal) * .pi / 16), ny = sin(Double(normal) * .pi / 16)
                let d = Double(offset - 16) / 32, width = 0.5 * max(abs(nx), abs(ny))
                var outer: UInt16 = 0, fill: UInt16 = 0
                for j in 0..<4 { for i in 0..<4 {
                    let side = nx * (Double(i) - 1.5) * 0.5 + ny * (Double(j) - 1.5) * 0.5 - d
                    if side >= 0 { outer |= 1 << (j * 4 + i) }
                    if side >= width { fill |= 1 << (j * 4 + i) }
                }}
                binaryPatterns.insert(outer)
                bandPatterns.insert(UInt32(outer) | UInt32(fill) << 16)
            }}
            binaryCandidates = binaryPatterns.count; bandCandidates = bandPatterns.count
            precondition(binaryCandidates <= 1024 && bandCandidates <= 1024)
            for key in binaryPatterns {
                let p = (0..<16).map { Int((key >> $0) & 1) }
                if let geometry = DenseMapGeometry.fit(p, band: false) { binary[Int(key)] = geometry + 1024 }
            }
            for key in bandPatterns {
                let p = (0..<16).map { (key & (1 << $0)) == 0 ? 0 : (key & (1 << ($0 + 16))) == 0 ? 2 : 1 }
                if let geometry = DenseMapGeometry.fit(p, band: true) { band.append((key, geometry)) }
            }
            band.sort { $0.key < $1.key }
        }
        func bandGeometry(_ key: UInt32) -> UInt16? {
            var low = 0, high = band.count
            while low < high {
                let mid = (low + high) / 2
                if band[mid].key < key { low = mid + 1 } else { high = mid }
            }
            return low < band.count && band[low].key == key ? band[low].geometry : nil
        }
        var allocatedElementCapacityBytes: Int { binary.capacity * 2 + band.capacity * MemoryLayout<(UInt32, UInt16)>.stride }
        var binaryAccepted: Int { binary.reduce(0) { $0 + ($1 == 0 ? 0 : 1) } }
        var logicalPayloadBytes: Int { binary.count * 2 + band.count * 6 }
    }

    // Exactly the frozen C PCA, quantization, residual and sixteen-center admission.
    // Normalized binary: 0=a, 1=b; band: 0=ground, 1=fill, 2=outline.
    static func fit(_ p: [Int], band: Bool) -> UInt16? {
        let center = [p[5], p[6], p[9], p[10]]
        if !band {
            if Set(center).count != 2 || (center[0] == center[3] && center[1] == center[2]) { return nil }
            if p.contains(where: { $0 != 0 && $0 != 1 }) { return nil }
        } else if Set(p) != Set([0, 1, 2]) { return nil }
        var outer: [Point] = [], inner: [Point] = []
        for j in 0..<4 { for i in 0..<4 {
            let v = p[j * 4 + i], px = (Double(i) - 1.5) * 0.5, py = (Double(j) - 1.5) * 0.5
            func transition(_ b: Int, _ point: Point) {
                if v == b { return }
                if !band || ((v == 0) != (b == 0)) { outer.append(point) } else { inner.append(point) }
            }
            if i < 3 { transition(p[j * 4 + i + 1], Point(x: px + 0.25, y: py)) }
            if j < 3 { transition(p[(j + 1) * 4 + i], Point(x: px, y: py + 0.25)) }
        }}
        if outer.count < 3 || (band && inner.count < 2) { return nil }
        var mx = 0.0, my = 0.0
        for q in outer { mx += q.x; my += q.y }
        mx /= Double(outer.count); my /= Double(outer.count)
        var xx = 0.0, yy = 0.0, xy = 0.0
        for q in outer { let dx = q.x - mx, dy = q.y - my; xx += dx * dx; yy += dy * dy; xy += dx * dy }
        var angle = 0.5 * atan2(2 * xy, xx - yy) + .pi / 2, orient = 0.0
        for j in 0..<4 { for i in 0..<4 {
            let positive = band ? p[j * 4 + i] != 0 : p[j * 4 + i] == 1
            orient += (positive ? 1.0 : -1.0) * (cos(angle) * (Double(i) - 1.5) + sin(angle) * (Double(j) - 1.5))
        }}
        if orient < 0 { angle += .pi }
        let normal = Int((angle * 16 / .pi).rounded(.toNearestOrAwayFromZero)) & 31
        let nx = cos(Double(normal) * .pi / 16), ny = sin(Double(normal) * .pi / 16)
        let offset = Int(((nx * mx + ny * my) * 32).rounded(.toNearestOrAwayFromZero)) + 16
        if offset < 0 || offset > 31 { return nil }
        let d = Double(offset - 16) / 32, width = 0.5 * max(abs(nx), abs(ny))
        if !band && abs(d) > (abs(nx) + abs(ny)) * 0.5 { return nil }
        if outer.contains(where: { abs(nx * $0.x + ny * $0.y - d) > 0.14 }) { return nil }
        if band && inner.contains(where: { abs(nx * $0.x + ny * $0.y - d - width) > 0.14 }) { return nil }
        for j in 0..<4 { for i in 0..<4 {
            let side = nx * (Double(i) - 1.5) * 0.5 + ny * (Double(j) - 1.5) * 0.5 - d, v = p[j * 4 + i]
            if band {
                if abs(side) < 0.001 || abs(side - width) < 0.001 { return nil }
                if (side < 0 ? 0 : side >= width ? 1 : 2) != v { return nil }
            } else if (v == 0 && side >= -0.001) || (v == 1 && side <= 0.001) { return nil }
        }}
        return UInt16(normal << 5 | offset)
    }

    static func encode(_ p: [UInt8], width w: Int, height h: Int, tables: Tables, direct: Bool = false) -> [UInt16] {
        precondition(w > 0 && h > 0 && w % 2 == 0 && h % 2 == 0 && p.count == w * h)
        precondition(p.allSatisfy { $0 < 8 })
        var out = [UInt16](repeating: 0, count: w * h / 4)
        for cy in 0..<h/2 { for cx in 0..<w/2 {
            let x = cx * 2, y = cy * 2
            let m = [p[y*w+x], p[y*w+x+1], p[(y+1)*w+x], p[(y+1)*w+x+1]]
            var word: UInt16 = 0x8000, mask = 0
            for i in 0..<4 { word |= UInt16(m[i]) << (3 * i); mask |= 1 << Int(m[i]) }
            if mask & (mask - 1) == 0 { out[cy * (w/2) + cx] = UInt16(m[0]); continue }
            if x >= 1 && y >= 1 && x + 2 < w && y + 2 < h {
                var halo = 0, outer: UInt16 = 0, fill: UInt16 = 0
                // First identify the halo palette; only normalized pattern lookups follow.
                for j in -1...2 { for i in -1...2 { halo |= 1 << Int(p[(y+j)*w+x+i]) }}
                if halo.nonzeroBitCount == 2 && mask.nonzeroBitCount == 2 && !(mask & 0x0a != 0 && mask & 0xf0 != 0) {
                    let a = halo.trailingZeroBitCount, b = Int.bitWidth - 1 - halo.leadingZeroBitCount
                    for j in -1...2 { for i in -1...2 {
                        if Int(p[(y+j)*w+x+i]) == b { outer |= 1 << ((j+1)*4+i+1) }
                    }}
                    let result: UInt16
                    if direct { result = fit((0..<16).map { Int((outer >> $0) & 1) }, band: false).map { $0 + 1024 } ?? 0 }
                    else { result = tables.binary[Int(outer)] }
                    if result != 0 { word = UInt16((a*7-a*(a-1)/2+b-a) << 10) | (result - 1024) }
                } else if halo == 0x31 || halo == 0xc4 {
                    let ground: UInt8 = halo == 0x31 ? 0 : 2, interior: UInt8 = ground == 0 ? 4 : 6
                    for j in -1...2 { for i in -1...2 {
                        let v = p[(y+j)*w+x+i], bit = (j+1)*4+i+1
                        if v != ground { outer |= 1 << bit }
                        if v == interior { fill |= 1 << bit }
                    }}
                    let key = UInt32(outer) | UInt32(fill) << 16
                    let geometry: UInt16?
                    if direct { geometry = fit((0..<16).map { key & (1 << $0) == 0 ? 0 : key & (1 << ($0+16)) == 0 ? 2 : 1 }, band: true) }
                    else { geometry = tables.bandGeometry(key) }
                    if let geometry { word = UInt16((ground == 0 ? 29 : 30) << 10) | geometry }
                }
            }
            out[cy * (w/2) + cx] = word
        }}
        return out
    }
}
