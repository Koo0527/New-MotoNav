import Foundation
#if canImport(Compression)
import Compression
#endif
#if canImport(UIKit)
import UIKit
#endif

/// 专辑封面编码器：把图片压成圆屏固件能解析的封面包（大块通道 type 6）。
///
/// 线格式与 Android 端 `CoverPacket.java` 一致：
/// u16 w, u16 h, u16 flags(0x8000 调色板 | 0x2000 deflate),
/// 16 × u16 RGB565 调色板, u32 RLE 字节数, deflate 数据。
/// 固件侧解析见 `MapEngine.h` 的 `parseCover`。
enum CoverEncoder {
    static let targetSize = 180
    static let typeCover = 6

    struct Encoded {
        let width: Int
        let height: Int
        let data: Data
    }

    /// RGBA8888 像素 → 封面包。w/h 都不能超过 180（固件限制）。
    static func encode(rgba: [UInt8], width: Int, height: Int) -> Encoded? {
        let count = width * height
        guard width > 0, height > 0, width <= targetSize, height <= targetSize,
              rgba.count >= count * 4 else { return nil }

        let palette = selectPalette(rgba: rgba, count: count)
        var indices = [UInt8](repeating: 0, count: count)
        for i in 0..<count {
            indices[i] = UInt8(nearestIndex(rgba[i * 4], rgba[i * 4 + 1], rgba[i * 4 + 2], palette))
        }

        let rle = rleEncode(indices)
        guard let packed = deflate(rle) else { return nil }

        var out: [UInt8] = []
        out.reserveCapacity(42 + packed.count)
        appendU16(&out, UInt16(width))
        appendU16(&out, UInt16(height))
        appendU16(&out, 0x8000 | 0x2000)                 // FLAG_PALETTE | FLAG_DEFLATE
        for color in palette { appendU16(&out, rgb565(color)) }
        appendU32(&out, UInt32(rle.count))
        out.append(contentsOf: packed)
        return Encoded(width: width, height: height, data: Data(out))
    }

    // MARK: - 调色板

    /// 4 位/通道直方图取出现最多的 16 个桶，与 Android 端算法逐行对应。
    private static func selectPalette(rgba: [UInt8], count: Int) -> [Int] {
        var buckets = [Int](repeating: 0, count: 4096)
        let step = max(1, count / 5000)
        var i = 0
        while i < count {
            let r = Int(rgba[i * 4] >> 4)
            let g = Int(rgba[i * 4 + 1] >> 4)
            let b = Int(rgba[i * 4 + 2] >> 4)
            buckets[(r << 8) | (g << 4) | b] += 1
            i += step
        }

        var topBuckets = [Int](repeating: -1, count: 16)
        var topCounts = [Int](repeating: 0, count: 16)
        for bucket in 0..<4096 where buckets[bucket] > 0 {
            let hits = buckets[bucket]
            for slot in 0..<16 where hits > topCounts[slot] {
                var j = 15
                while j > slot {
                    topCounts[j] = topCounts[j - 1]
                    topBuckets[j] = topBuckets[j - 1]
                    j -= 1
                }
                topCounts[slot] = hits
                topBuckets[slot] = bucket
                break
            }
        }

        var palette = [Int](repeating: 0, count: 16)
        for slot in 0..<16 {
            let bucket = topBuckets[slot]
            if bucket >= 0 {
                let r = ((bucket >> 8) & 15) * 17
                let g = ((bucket >> 4) & 15) * 17
                let b = (bucket & 15) * 17
                palette[slot] = (r << 16) | (g << 8) | b
            } else {
                let gray = slot * 17
                palette[slot] = (gray << 16) | (gray << 8) | gray
            }
        }
        return palette
    }

    private static func nearestIndex(_ r: UInt8, _ g: UInt8, _ b: UInt8, _ palette: [Int]) -> Int {
        let rr = Int(r), gg = Int(g), bb = Int(b)
        var best = 0
        var bestDistance = Int.max
        for slot in 0..<16 {
            let color = palette[slot]
            let dr = rr - ((color >> 16) & 255)
            let dg = gg - ((color >> 8) & 255)
            let db = bb - (color & 255)
            let distance = dr * dr * 2 + dg * dg * 4 + db * db * 3
            if distance < bestDistance {
                bestDistance = distance
                best = slot
            }
        }
        return best
    }

    private static func rgb565(_ color: Int) -> UInt16 {
        let r = (color >> 16) & 255
        let g = (color >> 8) & 255
        let b = color & 255
        return UInt16(((r >> 3) << 11) | ((g >> 2) << 5) | (b >> 3))
    }

    // MARK: - 4 位 RLE

    /// 与固件 parseCover 的取值规则一致：<16 表示单像素，否则高 4 位为 run-16 长度。
    private static func rleEncode(_ indices: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(indices.count / 4 + 64)
        let count = indices.count
        var pos = 0
        while pos < count {
            let value = indices[pos] & 15
            var run = 1
            while pos + run < count, run < 271, (indices[pos + run] & 15) == value { run += 1 }
            if run <= 15 {
                out.append(((UInt8(run - 1)) << 4) | value)
            } else {
                out.append((15 << 4) | value)
                out.append(UInt8(run - 16))
            }
            pos += run
        }
        return out
    }

    // MARK: - deflate

    private static func deflate(_ input: [UInt8]) -> [UInt8]? {
#if canImport(Compression)
        guard !input.isEmpty else { return nil }
        var out = [UInt8](repeating: 0, count: input.count + input.count / 2 + 128)
        let written = input.withUnsafeBufferPointer { src -> Int in
            out.withUnsafeMutableBufferPointer { dst -> Int in
                guard let s = src.baseAddress, let d = dst.baseAddress else { return 0 }
                return compression_encode_buffer(d, dst.count, s, src.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written > 0 else { return nil }
        return Array(out[0..<written])
#else
        return nil
#endif
    }

    private static func appendU16(_ out: inout [UInt8], _ value: UInt16) {
        out.append(UInt8(value & 0xFF))
        out.append(UInt8((value >> 8) & 0xFF))
    }

    private static func appendU32(_ out: inout [UInt8], _ value: UInt32) {
        out.append(UInt8(value & 0xFF))
        out.append(UInt8((value >> 8) & 0xFF))
        out.append(UInt8((value >> 16) & 0xFF))
        out.append(UInt8((value >> 24) & 0xFF))
    }
}

#if canImport(UIKit)
extension CoverEncoder {
    /// UIImage → 180×180 居中裁切 → 封面包。
    static func encode(image: UIImage) -> Encoded? {
        guard let cg = image.cgImage else { return nil }
        guard let rgba = rgbaPixels(from: cg, size: targetSize) else { return nil }
        return encode(rgba: rgba, width: targetSize, height: targetSize)
    }

    /// 等比放大填满目标方框后居中裁切，避免封面被拉伸变形。
    private static func rgbaPixels(from cg: CGImage, size: Int) -> [UInt8]? {
        let side = CGFloat(size)
        let width = CGFloat(cg.width)
        let height = CGFloat(cg.height)
        guard width > 0, height > 0 else { return nil }
        let scale = max(side / width, side / height)
        let drawWidth = width * scale
        let drawHeight = height * scale
        let rect = CGRect(x: (side - drawWidth) / 2, y: (side - drawHeight) / 2,
                          width: drawWidth, height: drawHeight)

        var buffer = [UInt8](repeating: 0, count: size * size * 4)
        let drawn = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(data: raw.baseAddress, width: size, height: size,
                                          bitsPerComponent: 8, bytesPerRow: size * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                return false
            }
            context.interpolationQuality = .high
            context.draw(cg, in: rect)
            return true
        }
        return drawn ? buffer : nil
    }
}
#endif
