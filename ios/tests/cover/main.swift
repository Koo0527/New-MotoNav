import Foundation

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

/// 按《音乐模块对接话术》的 C 命令格式校验 RGB565 小端像素。
func decode(_ encoded: CoverEncoder.Encoded) -> [UInt16]? {
    let d = [UInt8](encoded.data)
    guard d.count == encoded.width * encoded.height * 2 else { return nil }
    var pixels = [UInt16](repeating: 0, count: encoded.width * encoded.height)
    for i in 0..<pixels.count {
        pixels[i] = UInt16(d[i * 2]) | UInt16(d[i * 2 + 1]) << 8   // 低字节在前
    }
    return pixels
}

func rgb(_ value: UInt16) -> (Int, Int, Int) {
    (Int((value >> 11) & 31) * 8, Int((value >> 5) & 63) * 4, Int(value & 31) * 8)
}

// 1. 纯色：像素数与数值都要对
let solid = image(side, side) { _, _ in (200, 30, 40) }
let solidPacket = CoverEncoder.encode(rgba: solid, width: side, height: side)
check(solidPacket != nil, "纯色封面可编码")
let solidPixels = decode(solidPacket!)
check(solidPixels != nil, "纯色封面字节数等于 w*h*2")
check(Set(solidPixels!).count == 1, "纯色只产生一个 RGB565 值")
let solidRgb = rgb(solidPixels![0])
check(abs(solidRgb.0 - 200) <= 8 && abs(solidRgb.1 - 30) <= 4 && abs(solidRgb.2 - 40) <= 8,
      "RGB565 量化误差在通道位宽内")

// 2. 黑白交替：相邻像素必须不同，验证字节序没有错位
let stripes = image(side, side) { x, _ in x % 2 == 0 ? (0, 0, 0) : (255, 255, 255) }
let stripesPacket = CoverEncoder.encode(rgba: stripes, width: side, height: side)!
let stripesPixels = decode(stripesPacket)!
check(stripesPixels[0] != stripesPixels[1], "相邻像素不同色")
check(stripesPixels[0] == 0x0000 && stripesPixels[1] == 0xFFFF, "黑白 565 值正确")

// 3. 渐变：整体误差应在 565 量化范围内
let gradient = image(side, side) { x, y in
    (UInt8(x * 255 / (side - 1)), UInt8(y * 255 / (side - 1)), UInt8((x + y) * 255 / (side * 2 - 2)))
}
let gradientPacket = CoverEncoder.encode(rgba: gradient, width: side, height: side)!
let gradientPixels = decode(gradientPacket)!
var totalError = 0
for i in 0..<(side * side) {
    let got = rgb(gradientPixels[i])
    let want = (Int(gradient[i * 4]), Int(gradient[i * 4 + 1]), Int(gradient[i * 4 + 2]))
    totalError += abs(got.0 - want.0) + abs(got.1 - want.1) + abs(got.2 - want.2)
}
let meanError = Double(totalError) / Double(side * side * 3)
check(meanError < 10, "RGB565 平均误差 \(meanError) 应小于 10")

// 4. 分片：每包 11 字节头，parts 必须 ≤ 255
let payload = 500 - 11
let parts = (gradientPacket.data.count + payload - 1) / payload
check(parts <= 255, "180×180 在 MTU 500 下片数 \(parts) 应 ≤ 255")
check(CoverEncoder.side(maxWrite: 500) == side, "协商到 500 时保持 180×180")
check(CoverEncoder.side(maxWrite: 23) <= side, "小 MTU 时自动收缩边长")

// 5. 非法输入
check(CoverEncoder.encode(rgba: [UInt8](repeating: 0, count: 256 * 4), width: 256, height: 1) == nil, "超过 255 拒绝")
check(CoverEncoder.encode(rgba: solid, width: 0, height: side) == nil, "零宽拒绝")
check(CoverEncoder.encode(rgba: [0, 0, 0], width: 10, height: 10) == nil, "像素不足拒绝")

print("Cover encoder (C/RGB565): \(checks) checks passed")
