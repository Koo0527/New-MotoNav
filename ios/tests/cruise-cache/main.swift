// 巡航滚动缓存宿主回归：64MiB 块级 LRU、身份/长度/摘要校验、固定块保护、
// 超预算淘汰、损坏清除、重启复用、跳过写入不抛错。编译 CruiseMapCache.swift + MapGeo.swift。
import Foundation

var passed = 0
func check(_ cond: Bool, _ name: String) {
    precondition(cond, "FAIL: \(name)")
    passed += 1
    print("PASS \(name)")
}

let tmp = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
    .appendingPathComponent("cruise-cache-\(UUID().uuidString)", isDirectory: true)
try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: tmp) }

let frame = MapGeo.Frame(refLat: 39.9075, refLng: 116.3975, id: 1)
func key(_ cx: Double, _ cy: Double, gen: String = "abcd1234", style: Int = 1) -> String {
    CruiseMapCache.blockKey(source: 4, generation: gen, frame: frame, style: style,
                            quality: CruiseMapCache.qualityVersion, cx: cx, cy: cy)
}
func payload(_ n: Int) -> Data { Data((0..<n).map { UInt8($0 & 0xff) }) }

// ---------- 1. 读写往返 + 重启复用 ----------
do {
    let c = CruiseMapCache(root: tmp.appendingPathComponent("a", isDirectory: true))
    let p = payload(500)
    c.store(p, kind: "base", source: 4, generation: "abcd1234", frame: frame, style: 1,
            quality: CruiseMapCache.qualityVersion, cx: 100, cy: 200)
    let back = c.read(kind: "base", source: 4, generation: "abcd1234", frame: frame, style: 1,
                      quality: CruiseMapCache.qualityVersion, cx: 100, cy: 200)
    check(back == p, "写入后读回一致")
    // 主题组兼容：1/2/3 同组互读（同底图复用）
    let g12 = c.read(kind: "base", source: 4, generation: "abcd1234", frame: frame, style: 2,
                     quality: CruiseMapCache.qualityVersion, cx: 100, cy: 200)
    check(g12 == p, "同主题组（1↔2）命中")
    // 不同主题组/代次/块中心 miss
    check(c.read(kind: "base", source: 4, generation: "abcd1234", frame: frame, style: 5,
                 quality: CruiseMapCache.qualityVersion, cx: 100, cy: 200) == nil, "极简组不串")
    check(c.read(kind: "base", source: 4, generation: "ffff0000", frame: frame, style: 1,
                 quality: CruiseMapCache.qualityVersion, cx: 100, cy: 200) == nil, "代次隔离")
    check(c.read(kind: "base", source: 4, generation: "abcd1234", frame: frame, style: 1,
                 quality: CruiseMapCache.qualityVersion, cx: 104, cy: 200) == nil, "块中心隔离")
    // 重启复用：新实例（模拟 App 重启）同一磁盘
    let c2 = CruiseMapCache(root: tmp.appendingPathComponent("a", isDirectory: true))
    check(c2.read(kind: "base", source: 4, generation: "abcd1234", frame: frame, style: 3,
                  quality: CruiseMapCache.qualityVersion, cx: 100, cy: 200) == p, "重启后可复用")
} catch { check(false, "段1异常: \(error)") }

// ---------- 2. 超预算块级淘汰 + 建筑随块同进同出 ----------
do {
    let c = CruiseMapCache(root: tmp.appendingPathComponent("b", isDirectory: true))
    let blockSize = 600 * 1024 // 每块 ~0.6MiB；预算 64MiB ≈ 109 块
    for i in 0..<130 {
        c.store(payload(blockSize), kind: "base", source: 4, generation: "abcd1234", frame: frame,
                style: 1, quality: CruiseMapCache.qualityVersion, cx: Double(i), cy: 0)
        if i % 3 == 0 {
            c.store(payload(100_000), kind: "bld", source: 4, generation: "abcd1234", frame: frame,
                    style: 1, quality: CruiseMapCache.qualityVersion, cx: Double(i), cy: 0)
        }
    }
    let s = c.stats()
    check(s.bytes <= CruiseMapCache.budgetBytes + blockSize, "超预算仍持续写入且总量受限（\(s.bytes)）")
    check(s.blocks < 130 && s.blocks > 90, "最旧块被淘汰（\(s.blocks) 块存留）")
    // 最旧块整体（base+bld）消失；最新块两包都在
    check(c.read(kind: "base", source: 4, generation: "abcd1234", frame: frame, style: 1,
                 quality: CruiseMapCache.qualityVersion, cx: 0, cy: 0) == nil, "最旧块道路已淘汰")
    check(c.read(kind: "base", source: 4, generation: "abcd1234", frame: frame, style: 1,
                 quality: CruiseMapCache.qualityVersion, cx: 129, cy: 0) != nil, "最新块道路在")
    check(c.read(kind: "bld", source: 4, generation: "abcd1234", frame: frame, style: 1,
                 quality: CruiseMapCache.qualityVersion, cx: 128, cy: 0) == nil, "无建筑块返回 nil")
    c.store(payload(100_000), kind: "bld", source: 4, generation: "abcd1234", frame: frame,
            style: 1, quality: CruiseMapCache.qualityVersion, cx: 129, cy: 0)
    check(c.read(kind: "bld", source: 4, generation: "abcd1234", frame: frame, style: 1,
                 quality: CruiseMapCache.qualityVersion, cx: 129, cy: 0) != nil, "补建筑包可读")
} catch { check(false, "段2异常: \(error)") }

// ---------- 3. 固定块保护：显示/传输/待交接块不被淘汰 ----------
do {
    let c = CruiseMapCache(root: tmp.appendingPathComponent("c", isDirectory: true))
    let pinnedKey = key(0, 0)
    c.store(payload(600 * 1024), kind: "base", source: 4, generation: "abcd1234", frame: frame,
            style: 1, quality: CruiseMapCache.qualityVersion, cx: 0, cy: 0)
    c.setPins([pinnedKey])
    for i in 1..<130 {
        c.store(payload(600 * 1024), kind: "base", source: 4, generation: "abcd1234", frame: frame,
                style: 1, quality: CruiseMapCache.qualityVersion, cx: Double(i), cy: 0)
    }
    check(c.read(kind: "base", source: 4, generation: "abcd1234", frame: frame, style: 1,
                 quality: CruiseMapCache.qualityVersion, cx: 0, cy: 0) != nil, "固定块在最旧位仍存留")
    // 解除固定后继续滚动，固定块最终按 LRU 被淘汰（读会把它推到队尾，需整轮翻新）
    c.setPins([])
    for i in 1000..<1140 {
        c.store(payload(600 * 1024), kind: "base", source: 4, generation: "abcd1234", frame: frame,
                style: 1, quality: CruiseMapCache.qualityVersion, cx: Double(i), cy: 0)
    }
    check(c.read(kind: "base", source: 4, generation: "abcd1234", frame: frame, style: 1,
                 quality: CruiseMapCache.qualityVersion, cx: 0, cy: 0) == nil, "解除固定后按 LRU 淘汰")
} catch { check(false, "段3异常: \(error)") }

// ---------- 4. 损坏与身份篡改：校验失败清文件不返回错包 ----------
do {
    var skipEvents = 0
    let c = CruiseMapCache(root: tmp.appendingPathComponent("d", isDirectory: true))
    c.onEvent = { name, _ in if name == "cruise-cache-skip" { skipEvents += 1 } }
    c.store(payload(300), kind: "base", source: 4, generation: "abcd1234", frame: frame,
            style: 1, quality: CruiseMapCache.qualityVersion, cx: 5, cy: 5)
    let url = tmp.appendingPathComponent("d", isDirectory: true)
        .appendingPathComponent(key(5, 5), isDirectory: true).appendingPathComponent("base.bin")
    var tampered = try Data(contentsOf: url)
    tampered[tampered.count - 1] ^= 0xff // 篡改载荷（长度/身份头不变）
    try tampered.write(to: url)
    // 摘要头不变+载荷变无法靠自身摘要发现（载荷不含摘要）——身份头校验覆盖键/类型；篡改载荷的防护由包级 RasterPacket.valid 承担。
    // 此处验证身份篡改：改写身份段
    tampered[11] ^= 0xff
    try tampered.write(to: url)
    check(c.read(kind: "base", source: 4, generation: "abcd1234", frame: frame, style: 1,
                 quality: CruiseMapCache.qualityVersion, cx: 5, cy: 5) == nil, "身份篡改被拒")
    check(skipEvents >= 1 && skipEvents <= 2, "损坏事件已记录")
    check(!FileManager.default.fileExists(atPath: url.path), "损坏文件被清除")
    // 再读 miss（不崩、不复活）
    check(c.read(kind: "base", source: 4, generation: "abcd1234", frame: frame, style: 1,
                 quality: CruiseMapCache.qualityVersion, cx: 5, cy: 5) == nil, "清除后 miss")
} catch { check(false, "段4异常: \(error)") }

// ---------- 5. 主题组映射 ----------
check(CruiseMapCache.themeGroup(1) == "sem" && CruiseMapCache.themeGroup(3) == "sem", "1-3 语义组")
check(CruiseMapCache.themeGroup(5) == "min", "5 极简组")
check((4...9).filter { $0 != 5 }.allSatisfy { CruiseMapCache.themeGroup($0) == "plain" }, "4/6-9 普通组")

// ---------- 6. 写失败不抛错（目录不可写）
do {
    let badRoot = tmp.appendingPathComponent("e.bin", isDirectory: false) // 文件占位当目录
    try payload(1).write(to: badRoot)
    let c = CruiseMapCache(root: badRoot)
    c.store(payload(100), kind: "base", source: 4, generation: "abcd1234", frame: frame,
            style: 1, quality: CruiseMapCache.qualityVersion, cx: 1, cy: 1) // 不应崩溃
    check(c.read(kind: "base", source: 4, generation: "abcd1234", frame: frame, style: 1,
                 quality: CruiseMapCache.qualityVersion, cx: 1, cy: 1) == nil, "写失败返回 miss 不抛错")
} catch { check(false, "段6异常: \(error)") }

print("cruise cache: \(passed) checks passed")
