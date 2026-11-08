import Foundation
import zlib

/// Isolated EDGE v1 prototype. Input cells are 2 m semantic materials 0...7.
/// Supply basePacketBytes to enforce 480000 bytes on the complete raster plus tail.
enum MapEdgeGeometry {
    static let maximumPacketBytes = 480_000
    static let maximumDecodedBytes = 512 * 1024

    struct Statistics: Codable {
        var candidateCount = 0, edgeCount = 0, uniqueWords = 0
        var discardedRareEdges = 0, discardedInteriorEdges = 0
        var decodedBytes = 0, tailBytes = 0, fullPacketBytes = 0, codec = 0
        var fallbackReason: String?
    }
    struct Result { let data: Data?; let statistics: Statistics }

    static func build(pixels: [UInt8], width: Int, height: Int, basePacketBytes: Int = 0) -> Data? {
        buildReport(pixels: pixels, width: width, height: height, basePacketBytes: basePacketBytes).data
    }

    static func buildReport(pixels: [UInt8], width: Int, height: Int, basePacketBytes: Int = 0) -> Result {
        var stats = Statistics()
        func rejected(_ reason: String) -> Result {
            var failed = stats; failed.fallbackReason = reason
            return Result(data: nil, statistics: failed)
        }
        guard width > 0, height > 0, width <= 65535, height <= 65535,
              pixels.count == width * height, basePacketBytes >= 0,
              basePacketBytes <= maximumPacketBytes else { return rejected("invalid input") }
        let blocksWide = (width + 15) / 16, blocksHigh = (height + 15) / 16
        let tileCount = blocksWide * blocksHigh
        guard tileCount * 52 <= maximumDecodedBytes,
              pixels.allSatisfy({ $0 < 8 }) else { return rejected("invalid materials or tile budget") }
        var cells = [UInt16](repeating: 0, count: pixels.count)
        var frequency: [UInt16: Int] = [:]
        if width > 2 && height > 2 {
            for y in 1..<(height - 1) { for x in 1..<(width - 1) {
                let word = fit(pixels, width: width, x: x, y: y)
                if word != 0 { cells[y * width + x] = word; frequency[word, default: 0] += 1; stats.candidateCount += 1 }
            } }
        }
        var count = stats.candidateCount
        func plainFits() -> Bool {
            tileCount * 52 + count * 2 <= maximumDecodedBytes &&
            24 + tileCount * 32 + count * 2 <= maximumPacketBytes - basePacketBytes
        }
        // Compress once raw words exceed 64 KiB, or either uncompressed budget is tight.
        let useDictionary = count > 32768 || !plainFits()
        if useDictionary {
            // Drop only internal roof/outline AA first; preserve the original nearest material.
            let interior = frequency.keys.filter { $0 >> 11 == 23 || $0 >> 11 == 28 }.sorted {
                frequency[$0]! == frequency[$1]! ? $0 < $1 : frequency[$0]! < frequency[$1]!
            }
            for word in interior {
                if tileCount * 52 + count + min(256, frequency.count) * 2 <= maximumDecodedBytes { break }
                let removed = frequency.removeValue(forKey: word)!
                count -= removed; stats.discardedInteriorEdges += removed
            }
            if frequency.count > 256 {
                let rare = frequency.keys.sorted { frequency[$0]! == frequency[$1]! ? $0 < $1 : frequency[$0]! < frequency[$1]! }
                let remove = Array(rare.prefix(frequency.count - 256))
                let removed = remove.reduce(0) { $0 + frequency[$1]! }
                guard removed <= stats.candidateCount / 100 else { return rejected("dictionary needs more than 1% rare-edge removal") }
                for word in remove { frequency.removeValue(forKey: word) }
                count -= removed; stats.discardedRareEdges = removed
            }
        }
        let codec = useDictionary && !(count == 0 && plainFits()) ? 1 : 0
        let dictionary = frequency.isEmpty && codec == 1 ? [UInt16(1 << 11)] : frequency.keys.sorted()
        stats.edgeCount = count; stats.uniqueWords = frequency.count
        stats.codec = codec
        stats.decodedBytes = tileCount * 52 + (codec == 0 ? count * 2 : count + dictionary.count * 2)
        guard stats.decodedBytes <= maximumDecodedBytes else { return rejected("decoded metadata budget") }
        let indexes = Dictionary(uniqueKeysWithValues: dictionary.enumerated().map { ($0.element, $0.offset) })
        var masks = Data(capacity: tileCount * 32), values = Data(capacity: count * (codec == 0 ? 2 : 1))
        for ty in 0..<blocksHigh { for tx in 0..<blocksWide { for row in 0..<16 {
            let y = ty * 16 + row
            var mask: UInt16 = 0
            if y < height { for column in 0..<16 {
                let x = tx * 16 + column
                guard x < width else { continue }
                let word = cells[y * width + x]
                guard word != 0, let index = indexes[word] else { continue }
                mask |= UInt16(1) << column
                if codec == 0 { append16(word, to: &values) } else { values.append(UInt8(index)) }
            } }
            append16(mask, to: &masks)
        } } }
        var payload = masks
        if codec == 1 { for word in dictionary { append16(word, to: &payload) } }
        payload.append(values)
        if codec == 1 {
            var size = compressBound(uLong(payload.count))
            var compressed = Data(count: Int(size))
            let status = payload.withUnsafeBytes { input in compressed.withUnsafeMutableBytes { output in
                compress2(output.bindMemory(to: UInt8.self).baseAddress, &size,
                          input.bindMemory(to: UInt8.self).baseAddress, uLong(payload.count), Z_BEST_SPEED)
            } }
            guard status == Z_OK else { return rejected("zlib compression") }
            compressed.count = Int(size); payload = compressed
        }
        stats.tailBytes = 24 + payload.count; stats.fullPacketBytes = basePacketBytes + stats.tailBytes
        guard stats.fullPacketBytes <= maximumPacketBytes else { return rejected("complete packet budget") }
        let checksum = payload.reduce(UInt32(2166136261)) { ($0 ^ UInt32($1)) &* 16777619 }
        var result = Data([69, 68, 71, 69, 1, UInt8(codec)])
        append16(UInt16(width), to: &result); append16(UInt16(height), to: &result)
        append16(codec == 1 ? UInt16(dictionary.count) : 0, to: &result)
        append32(UInt32(tileCount), to: &result); append32(UInt32(count), to: &result)
        append32(checksum, to: &result); result.append(payload)
        return Result(data: result, statistics: stats)
    }

    private static func fit(_ pixels: [UInt8], width: Int, x: Int, y: Int) -> UInt16 {
        let i = y * width + x, center = pixels[i]
        guard pixels[i - 1] != center || pixels[i + 1] != center ||
              pixels[i - width] != center || pixels[i + width] != center ||
              pixels[i - width - 1] != center || pixels[i - width + 1] != center ||
              pixels[i + width - 1] != center || pixels[i + width + 1] != center else { return 0 }
        let samples = (pixels[i - width - 1], pixels[i - width], pixels[i - width + 1],
                       pixels[i - 1], center, pixels[i + 1],
                       pixels[i + width - 1], pixels[i + width], pixels[i + width + 1])
        return withUnsafeBytes(of: samples) { samples in
            var materials: UInt16 = 0
            for sample in samples { materials |= UInt16(1) << sample }
            var outline: UInt8 = 0
            if materials & 0x0f != 0 && materials & 0xf0 != 0 {
                // Road/water take priority over the entire outer-building contact stencil.
                guard materials & 0x0a == 0, !(center >= 4 && center & 1 == 0) else { return 0 }
                guard materials & 0x30 == 0 || materials & 0xc0 == 0 else { return 0 }
                outline = materials & 0x30 != 0 ? 5 : 7
                materials = (materials & 0x0f) | (UInt16(1) << outline)
            }
            let a = materials.trailingZeroBitCount
            let rest = materials & (materials - 1)
            guard rest != 0, rest & (rest - 1) == 0 else { return 0 }
            let b = rest.trailingZeroBitCount
            var pattern = 0
            for index in 0..<9 {
                let material = outline != 0 && samples[index] >= 4 ? outline : samples[index]
                if material == b { pattern |= 1 << index }
            }
            let geometry = patternGeometry[pattern]
            guard geometry != 0 else { return 0 }
            let pair = a * 7 - a * (a - 1) / 2 + b - a
            return UInt16(pair << 11) | (geometry & 2047)
        }
    }

    // The sole geometric fitter runs once for each binary stencil, never once per edge.
    private static let patternGeometry: [UInt16] = (0..<512).map(makeGeometry)

    private static func makeGeometry(_ pattern: Int) -> UInt16 {
        guard pattern != 0, pattern != 511 else { return 0 }
        let samples: [UInt8] = (0..<9).map { pattern & (1 << $0) == 0 ? 0 : 1 }
        let a: UInt8 = 0, b: UInt8 = 1, pair = 1
        // Exact repeated rows/columns yield the same quantized word as the general fit.
        if samples[0] != samples[2] && samples[0] == samples[3] && samples[3] == samples[6] &&
            samples[1] == samples[4] && samples[4] == samples[7] && samples[2] == samples[5] && samples[5] == samples[8] {
            let normal = samples[0] == a ? 0 : 32
            let d = (samples[0] == samples[1] ? 8 : -8) * (normal == 0 ? 1 : -1)
            return UInt16(pair << 11 | normal << 5 | (d + 16))
        }
        if samples[0] != samples[6] && samples[0] == samples[1] && samples[1] == samples[2] &&
            samples[3] == samples[4] && samples[4] == samples[5] && samples[6] == samples[7] && samples[7] == samples[8] {
            let normal = samples[0] == a ? 16 : 48
            let d = (samples[0] == samples[3] ? 8 : -8) * (normal == 16 ? 1 : -1)
            return UInt16(pair << 11 | normal << 5 | (d + 16))
        }
        var points: [(Double, Double)] = []
        for row in 0..<3 { for column in 0..<3 {
            let i = row * 3 + column
            if column < 2 && samples[i] != samples[i + 1] { points.append((Double(column) - 0.5, Double(row) - 1)) }
            if row < 2 && samples[i] != samples[i + 3] { points.append((Double(column) - 1, Double(row) - 0.5)) }
        } }
        guard points.count >= 2 else { return 0 }
        let meanX = points.reduce(0) { $0 + $1.0 } / Double(points.count)
        let meanY = points.reduce(0) { $0 + $1.1 } / Double(points.count)
        var xx = 0.0, yy = 0.0, xy = 0.0
        for (px, py) in points {
            let dx = px - meanX, dy = py - meanY
            xx += dx * dx; yy += dy * dy; xy += dx * dy
        }
        // Principal boundary direction, then its normal; reject hard corners by line residual.
        let tangent = 0.5 * atan2(2 * xy, xx - yy)
        var angle = tangent + Double.pi / 2
        var orientation = 0.0
        for i in 0..<9 {
            orientation += (samples[i] == b ? 1 : -1) * (cos(angle) * Double(i % 3 - 1) + sin(angle) * Double(i / 3 - 1))
        }
        if orientation < 0 { angle += Double.pi }
        let normal = Int((angle * 32 / Double.pi).rounded()) & 63
        let nx = cos(Double(normal) * Double.pi / 32), ny = sin(Double(normal) * Double.pi / 32)
        let distance = nx * meanX + ny * meanY
        // shortcut: 3x3 straight-line evidence only; use original geometry for curved or ambiguous cells.
        guard points.allSatisfy({ abs(nx * $0.0 + ny * $0.1 - distance) <= 0.28 }) else { return 0 }
        let offset = Int((distance * 16).rounded()) + 16
        guard (0...31).contains(offset) else { return 0 }
        let d = Double(offset - 16) / 16
        guard abs(d) <= (abs(nx) + abs(ny)) * 0.5 + 0.001 else { return 0 }
        for i in 0..<9 {
            let side = nx * Double(i % 3 - 1) + ny * Double(i / 3 - 1) - d
            if (samples[i] == a && side > 0.001) || (samples[i] == b && side < -0.001) { return 0 }
        }
        return UInt16(pair << 11 | normal << 5 | offset)
    }

    private static func append16(_ n: UInt16, to data: inout Data) {
        data.append(UInt8(truncatingIfNeeded: n)); data.append(UInt8(truncatingIfNeeded: n >> 8))
    }
    private static func append32(_ n: UInt32, to data: inout Data) {
        append16(UInt16(truncatingIfNeeded: n), to: &data)
        append16(UInt16(truncatingIfNeeded: n >> 16), to: &data)
    }
}
