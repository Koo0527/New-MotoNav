import Foundation
#if canImport(Compression)
import Compression
#endif

var checks = 0
func check(_ truth: Bool, _ reason: String) { precondition(truth, reason); checks += 1 }

let side = CoverEncoder.targetSize

func image(_ w: Int, _ h: Int, _ pixel: (Int, Int) -> (UInt8, UInt8, UInt8)) -> [UInt8] {
    var out = [UInt8](repeating: 255, count: w * h * 4)
    for y in 0..<h {
        for x in 0..<w {
            let (r, g, b) = pixel(x, y)
            let i = (y * w + x) * 4
            out[i] = r; out[i + 1] = g; out[i + 2] = b; out[i + 3] = 255
        }
    }
    return out
}

struct Decoded {
    let w: Int
    let h: Int
    let flags: Int
    let palette: [UInt16]
    let pixels: [UInt16]
}

func inflate(_ packed: [UInt8], expected: Int) -> [UInt8]? {
#if canImport(Compression)
    var out = [UInt8](repeating: 0, count: expected)
    let written = packed.withUnsafeBufferPointer { src -> Int in
        out.withUnsafeMutableBufferPointer { dst -> Int in
            guard let s = src.baseAddress, let d = dst.baseAddress else { return 0 }
            return compression_decode_buffer(d, dst.count, s, src.count, nil, COMPRESSION_ZLIB)
        }
    }
    return written == expected ? out : nil
#else
    return nil
#endif
}

/// 按固件 MapEngine.h 的 parseCover 规则解包，验证线格式。
func decode(_ encoded: CoverEncoder.Encoded) -> Decoded? {
    let d = [UInt8](encoded.data)
    guard d.count > 42 else { return nil }
    let w = Int(d[0]) | Int(d[1]) << 8
    let h = Int(d[2]) | Int(d[3]) << 8
    let flags = Int(d[4]) | Int(d[5]) << 8
    guard w == encoded.width, h == encoded.height else { return nil }
    var palette = [UInt16]()
    for i in 0..<16 { palette.append(UInt16(d[6 + i * 2]) | UInt16(d[7 + i * 2]) << 8) }
    let rawLength = Int(d[38]) | Int(d[39]) << 8 | Int(d[40]) << 16 | Int(d[41]) << 24
    guard rawLength > 0, rawLength <= w * h * 2 else { return nil }
    guard let rle = inflate(Array(d[42...]), expected: rawLength) else { return nil }

    var pixels = [UInt16](repeating: 0, count: w * h)
    var out = 0
    var p = 0
    while p < rle.count && out < w * h {
        let tag = rle[p]; p += 1
        if tag < 16 {
            pixels[out] = palette[Int(tag)]; out += 1
        } else {
            let index = Int(tag & 0x0F)
            var length = Int((tag >> 4) & 0x0F) + 1
            if length == 16 && p < rle.count { length += Int(rle[p]); p += 1 }
            var k = 0
            while k < length && out < w * h { pixels[out] = palette[index]; out += 1; k += 1 }
        }
    }
    guard out == w * h else { return nil }
    return Decoded(w: w, h: h, flags: flags, palette: palette, pixels: pixels)
}

func rgb(_ value: UInt16) -> (Int, Int, Int) {
    (Int((value >> 11) & 31) * 8, Int((value >> 5) & 63) * 4, Int(value & 31) * 8)
}

// 1. 纯色封面：覆盖 271 长度的长游程
let solid = image(side, side) { _, _ in (200, 30, 40) }
let solidPacket = CoverEncoder.encode(rgba: solid, width: side, height: side)
check(solidPacket != nil, "纯色封面可编码")
let solidDecoded = decode(solidPacket!)
check(solidDecoded != nil, "纯色封面可解包")
check(solidDecoded!.flags == 0xA000, "调色板与 deflate 标志位")
check(solidDecoded!.pixels.count == side * side, "像素数等于 180×180")
check(Set(solidDecoded!.pixels).count == 1, "纯色只落在一个调色板项")
check(solidPacket!.data.count < 1024, "纯色包应远小于 1KB")

// 2. 逐像素交替：覆盖长度为 1 的游程
let stripes = image(side, side) { x, _ in x % 2 == 0 ? (0, 0, 0) : (255, 255, 255) }
let stripesPacket = CoverEncoder.encode(rgba: stripes, width: side, height: side)
check(stripesPacket != nil, "交替色可编码")
let stripesDecoded = decode(stripesPacket!)
check(stripesDecoded != nil, "交替色可解包")
check(stripesDecoded!.pixels[0] != stripesDecoded!.pixels[1], "相邻像素不同色")
check(Set(stripesDecoded!.pixels).count == 2, "交替色落在两个调色板项")

// 3. 渐变：整体颜色误差必须足够小
let gradient = image(side, side) { x, y in
    (UInt8(x * 255 / (side - 1)), UInt8(y * 255 / (side - 1)), UInt8((x + y) * 255 / (side * 2 - 2)))
}
let gradientPacket = CoverEncoder.encode(rgba: gradient, width: side, height: side)
check(gradientPacket != nil, "渐变可编码")
let gradientDecoded = decode(gradientPacket!)
check(gradientDecoded != nil, "渐变可解包")
var totalError = 0
for i in 0..<(side * side) {
    let got = rgb(gradientDecoded!.pixels[i])
    let want = (Int(gradient[i * 4]), Int(gradient[i * 4 + 1]), Int(gradient[i * 4 + 2]))
    totalError += abs(got.0 - want.0) + abs(got.1 - want.1) + abs(got.2 - want.2)
}
let meanError = Double(totalError) / Double(side * side * 3)
check(meanError < 48, "16 色量化平均误差 \(meanError) 应小于 48")
check(Set(gradientDecoded!.pixels).count >= 8, "渐变应实际用到至少 8 个调色板项")
check(gradientPacket!.data.count < 48 * 1024, "封面包不超过固件缓冲上限")

// 4. 非法输入
check(CoverEncoder.encode(rgba: solid, width: side + 1, height: side) == nil, "超过 180 拒绝")
check(CoverEncoder.encode(rgba: solid, width: 0, height: side) == nil, "零宽拒绝")
check(CoverEncoder.encode(rgba: [0, 0, 0], width: 10, height: 10) == nil, "像素不足拒绝")

print("Cover encoder: \(checks) checks passed")
