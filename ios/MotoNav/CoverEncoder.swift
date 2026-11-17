import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// 专辑封面编码器：把图片转成固件 `C` 命令要的 RGB565 小端像素。
///
/// 线格式（与《音乐模块对接话术》一致）：
/// `'C' id part parts wLo wHi h off0 off1 off2 off3` + RGB565 数据（每像素 2 字节，低字节在前）。
/// `w = 0` 或 `h = 0` 表示清除封面。
enum CoverEncoder {
    /// 首选边长；实际边长会按协商到的 MTU 收缩，保证分片数 ≤ 255。
    static let targetSize = 180
    static let maxSide = 255
    static let minSide = 32

    struct Encoded {
        let width: Int
        let height: Int
        let data: Data
    }

    /// 按单包可写长度算出能塞进 255 片的封面边长。
    static func side(maxWrite: Int) -> Int {
        let payload = max(32, maxWrite - 11)
        let limit = Int((Double(255 * payload / 2)).squareRoot())
        return max(minSide, min(targetSize, limit))
    }

    /// RGBA8888 像素 → RGB565 小端数据。
    static func encode(rgba: [UInt8], width: Int, height: Int) -> Encoded? {
        let count = width * height
        guard width > 0, height > 0, width <= maxSide, height <= maxSide,
              rgba.count >= count * 4 else { return nil }
        var out = [UInt8](repeating: 0, count: count * 2)
        for i in 0..<count {
            let value = UInt16((Int(rgba[i * 4]) >> 3) << 11
                | ((Int(rgba[i * 4 + 1]) >> 2) << 5)
                | (Int(rgba[i * 4 + 2]) >> 3))
            out[i * 2] = UInt8(value & 0xFF)          // 低字节在前
            out[i * 2 + 1] = UInt8(value >> 8)
        }
        return Encoded(width: width, height: height, data: Data(out))
    }
}

#if canImport(UIKit)
extension CoverEncoder {
    /// UIImage → 居中裁切填满 side×side → RGB565。
    static func encode(image: UIImage, side: Int = targetSize) -> Encoded? {
        guard let cg = image.cgImage else { return nil }
        guard let rgba = rgbaPixels(from: cg, size: side) else { return nil }
        return encode(rgba: rgba, width: side, height: side)
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
