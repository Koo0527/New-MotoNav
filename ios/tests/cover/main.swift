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

/// 按固件 parseCover 期望的格式把 type 6 bulk 包解回 RGB565 像素数组。
func decodeType6(_ encoded: CoverEncoder.Encoded) -> [UInt16]? {
    let d = [UInt8](encoded.data)
    guard d.count >= 42 else { return nil }
    let w = Int(d[0]) | Int(d[1]) << 8
    let h = Int(d[2]) | Int(d[3]) << 8
    guard w == encoded.width, h == encoded.height, w > 0, w <= 255, h > 0, h <= 255 else { return nil }
    let flags = Int(d[4]) | Int(d[5]) << 8
    guard (flags & 0x8000) != 0, (flags & 0x2000) != 0 else { return nil }
    var palette = [UInt16](repeating: 0, count: 16)
    for i in 0..<16 { palette[i] = UInt16(d[6 + i * 2]) | UInt16(d[7 + i * 2]) << 8 }
    let rawRleLen = Int(d[38]) | Int(d[39]) << 8 | Int(d[40]) << 16 | Int(d[41]) << 24
    guard rawRleLen > 0, rawRleLen <= w * h * 2 else { return nil }
    let packed = Array(d[42...])
    let rle = deflateDecode(packed, expected: rawRleLen)
    guard let rle else { return nil }

    let totalPix = w * h
    var out = [UInt16](repeating: 0, count: totalPix)
    var p = 0, idx = 0
    while p < rle.count, idx < totalPix {
        let tag = rle[p]; p += 1
        if tag < 16 {
            out[idx] = palette[Int(tag)]; idx += 1
        } else {
            let cIdx = Int(tag & 0x0F)
            var len = (Int(tag >> 4) & 0x0F) + 1
            if len == 16, p < rle.count { len += Int(rle[p]); p += 1 }
            for _ in 0..<len where idx < totalPix { out[idx] = palette[cIdx]; idx += 1 }
        }
    }
    guard idx >= totalPix else { return nil }
    return out
}

func deflateDecode(_ input: [UInt8], expected: Int) -> [UInt8]? {
#if canImport(Compression)
    var out = [UInt8](repeating: 0, count: expected)
    let written = input.withUnsafeBufferPointer { src -> Int in
        out.withUnsafeMutableBufferPointer { dst -> Int in
            guard let s = src.baseAddress, let d = dst.baseAddress else { return 0 }
            return compression_decode_buffer(d, expected, s, input.count, nil, COMPRESSION_ZLIB)
        }
    }
    guard written == expected else { return nil }
    return out
#else
    return nil
#endif
}

func rgb(_ value: UInt16) -> (Int, Int, Int) {
    (Int((value >> 11) & 31) * 8, Int((value >> 5) & 63) * 4, Int(value & 31) * 8)
}

// 1. 纯色：所有像素解回后值完全相同（RLE 只用一个索引）；type 6 bulk 包体很小
let solid = image(side, side) { _, _ in (200, 30, 40) }
let solidPacket = CoverEncoder.encode(rgba: solid, width: side, height: side)
check(solidPacket != nil, "纯色封面可编码")
let solidPixels = decodeType6(solidPacket!)
check(solidPixels != nil, "纯色封面 type 6 bulk 可解回")
check(Set(solidPixels!).count == 1, "纯色只产生一种 RGB565 值（RLE 只用一个调色板索引）")
check(solidPacket!.data.count < 2000, "纯色 type 6 bulk 应 < 2KB（RLE+deflate 极强）")

// 2. 黑白交替：调色板里至少两种主色，解回后相邻像素交替
let stripes = image(side, side) { x, _ in x % 2 == 0 ? (0, 0, 0) : (255, 255, 255) }
let stripesPacket = CoverEncoder.encode(rgba: stripes, width: side, height: side)!
let stripesPixels = decodeType6(stripesPacket)!
check(stripesPixels[0] == 0x0000, "黑像素应为 0x0000")
check(stripesPixels[1] == 0xFFFF, "白像素应为 0xFFFF")
let stripePalette = stride(from: 6, to: 38, by: 2).map { Int(stripesPacket.data[$0]) | Int(stripesPacket.data[$0 + 1]) << 8 }
check(stripePalette.contains(0x0000) && stripePalette.contains(0xFFFF), "黑白交替调色板包含 0 和 0xFFFF")

// 3. 渐变：调色板量化后 RLE+deflate 压缩率仍应远高于未压缩像素（~64KB）
let gradient = image(side, side) { x, y in
    (UInt8(x * 255 / (side - 1)), UInt8(y * 255 / (side - 1)), UInt8((x + y) * 255 / (side * 2 - 2)))
}
let gradientPacket = CoverEncoder.encode(rgba: gradient, width: side, height: side)!
let gradientPixels = decodeType6(gradientPacket)!
check(gradientPixels.count == side * side, "渐变 type 6 bulk 解回正确数量的像素")
check(gradientPacket.data.count > 42 && gradientPacket.data.count < 25000,
      "渐变 type 6 bulk 应在 42B ~ 25KB（调色板+RLE+deflate 压缩率仍远高于未压缩 64KB）")

// 4. 格式头校验：w=h=180, flags=0xA000, palette 16 色, 最后 4 字节是 RLE 长度
let d = [UInt8](solidPacket!.data)
check(d.count >= 42, "头至少 42 字节")
check(Int(d[0]) | Int(d[1]) << 8 == side, "width = 180")
check(Int(d[2]) | Int(d[3]) << 8 == side, "height = 180")
check((Int(d[4]) | Int(d[5]) << 8) == 0x8000 | 0x2000, "flags = 0xA000")
let rawRleLen = Int(d[38]) | Int(d[39]) << 8 | Int(d[40]) << 16 | Int(d[41]) << 24
check(rawRleLen > 0, "RLE 长度 > 0")
check(rawRleLen <= side * side, "RLE 长度 ≤ \(side*side)")

// 5. type 6 bulk 分片数：180×180 压缩后 ≤ 2KB → parts ≤ 2（payload = 500 - 15 = 485）
let payload = 500 - 15
let parts = (gradientPacket.data.count + payload - 1) / payload
check(parts <= 2, "type 6 bulk 在 MTU 500 下 parts=\(parts) 应 ≤ 2（固件要求 parts ≤ 4096）")

// 6. 非法输入
check(CoverEncoder.encode(rgba: [UInt8](repeating: 0, count: 256 * 4), width: 256, height: 1) == nil,
      "超过 targetSize 拒绝")
check(CoverEncoder.encode(rgba: solid, width: 0, height: side) == nil, "零宽拒绝")
check(CoverEncoder.encode(rgba: [0, 0, 0], width: 10, height: 10) == nil, "像素不足拒绝")

print("Cover encoder (type 6 bulk → firmware parseCover): \(checks) checks passed")
