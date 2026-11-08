import Foundation

/// 巡航滚动缓存：矢量巡航成品（道路/建筑包）的磁盘块级 LRU（64 MiB 预算）。
/// 独立组件——不动导航离线 512MB 缓存（RouteMapCache）与其满额报错路径；
/// 旧 source=4 成果由调用方校验后按需导入（store 即导入），不做批量迁移。
///
/// 缓存键含：图源 / 数据代次 / 坐标参考（frame 引用点）/ 块中心 /
/// 兼容主题组 / 处理质量版本；包类型为块目录内的文件（base/bld）。
/// 读取校验魔数+身份+长度+摘要；正在显示/传输/待交接的固定块不淘汰；
/// 无可淘汰空间或磁盘不足时跳过写入并出诊断事件，绝不阻断道路交付。
/// 淘汰/写盘只在调用方的工作队列上同步执行（MapFeeder worker）；
/// 主线程只调 setPins（内存状态）。
final class CruiseMapCache {
    static let shared = CruiseMapCache()
    /// 巡航成品磁盘预算（64 MiB）；原始瓦片层在 VectorTileClient（48 MiB）。
    static let budgetBytes = 64 * 1024 * 1024
    /// 磁盘可用低于该值时跳过新写入（与导航离线 512MB 层同阈值语义）。
    static let minFreeBytes: Int64 = 32 * 1024 * 1024
    static let headerMagic: [UInt8] = Array("CMC1".utf8)

    private let root: URL
    private let lock = NSLock()
    private var order: [String] = []          // 块键，旧→新（淘汰从头部）
    private var blockBytes: [String: Int] = [:]
    /// 内存存在索引（块键→包类型集合）：连续定位线程只查内存即可判 miss，不碰磁盘。
    private var present: [String: Set<String>] = [:]
    private var totalBytes = 0
    private var pinned: Set<String> = []
    /// 诊断出口：白名单字段（reason/blocks/bytes），由 MapFeeder 接 MapPipelineTrace。
    var onEvent: ((String, [String: Any]) -> Void)? = nil

    init(root: URL? = nil) {
        self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("cruise-maps", isDirectory: true)
        rebuildIndex()
    }

    /// 处理质量版本：CPU 栅格化输出格式变化时递增（旧键自然失效）。
    static let qualityVersion = 1

    /// 兼容主题组：1-3 语义建筑组同底图；4/6-9 普通组；5 极简组。
    static func themeGroup(_ style: Int) -> String {
        if (1...3).contains(style) { return "sem" }
        if style == 5 { return "min" }
        return "plain"
    }

    /// 块键（身份并集）：图源/代次/坐标参考/块中心/主题组/质量版本。
    static func blockKey(source: Int, generation: String, frame: MapGeo.Frame,
                         style: Int, quality: Int, cx: Double, cy: Double) -> String {
        "s\(source)_g\(generation)_f\(frame.refLat)_\(frame.refLng)_t\(themeGroup(style))_q\(quality)_c\(Int(cx))_\(Int(cy))"
    }

    // MARK: - 读写（调用方工作队列）

    /// 存一个包（kind: "base" | "bld"）。超预算先淘汰最旧非固定块；全部固定或磁盘不足则跳过并记录原因。
    /// 永不抛错——写入失败不阻断链路。
    func store(_ data: Data, kind: String, source: Int, generation: String,
               frame: MapGeo.Frame, style: Int, quality: Int, cx: Double, cy: Double) {
        guard !generation.isEmpty, !data.isEmpty else { return }
        let key = CruiseMapCache.blockKey(source: source, generation: generation, frame: frame,
                                          style: style, quality: quality, cx: cx, cy: cy)
        let url = root.appendingPathComponent(key, isDirectory: true)
            .appendingPathComponent("\(kind).bin")
        lock.lock()
        if present[key]?.contains(kind) == true {
            lock.unlock(); return // 同键同类型已有文件：不重写（避免巡航折返时反复 IO）
        }
        let incoming = data.count + 64
        if totalBytes + incoming > CruiseMapCache.budgetBytes {
            var evictable = order.filter { !pinned.contains($0) }
            var freed = 0
            var victims: [String] = []
            while totalBytes + incoming - freed > CruiseMapCache.budgetBytes, let oldest = evictable.first {
                freed += blockBytes[oldest] ?? 0
                victims.append(oldest)
                evictable.removeFirst()
            }
            if totalBytes + incoming - freed > CruiseMapCache.budgetBytes {
                lock.unlock()
                onEvent?("cruise-cache-skip", ["reason": "budget-pinned", "blocks": order.count])
                return
            }
            lock.unlock()
            for v in victims { removeBlock(v) }
        } else {
            lock.unlock()
        }
        if let free = try? root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage, free < CruiseMapCache.minFreeBytes {
            onEvent?("cruise-cache-skip", ["reason": "disk", "blocks": order.count])
            return
        }
        let body = CruiseMapCache.frame(headerFor: key, kind: kind, payload: data)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try body.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            var rv = URLResourceValues()
            rv.isExcludedFromBackup = true
            var dirURL = url.deletingLastPathComponent()
            try? dirURL.setResourceValues(rv)
        } catch {
            onEvent?("cruise-cache-skip", ["reason": "write", "blocks": order.count])
            return
        }
        lock.lock()
        if !order.contains(key) { order.append(key) }
        else if let i = order.firstIndex(of: key) { order.remove(at: i); order.append(key) }
        blockBytes[key] = max(blockBytes[key] ?? 0, body.count)
        present[key, default: []].insert(kind)
        totalBytes = blockBytes.values.reduce(0, +)
        lock.unlock()
    }

    /// 读一个包：内存索引先判 miss（连续定位零磁盘）；命中走磁盘并校验
    /// 魔数/身份/长度/摘要，任何不符返回 nil 并清除损坏文件。
    func read(kind: String, source: Int, generation: String, frame: MapGeo.Frame,
              style: Int, quality: Int, cx: Double, cy: Double) -> Data? {
        guard !generation.isEmpty else { return nil }
        let key = CruiseMapCache.blockKey(source: source, generation: generation, frame: frame,
                                          style: style, quality: quality, cx: cx, cy: cy)
        lock.lock()
        let known = present[key]?.contains(kind) == true
        lock.unlock()
        guard known else { return nil }
        let url = root.appendingPathComponent(key, isDirectory: true)
            .appendingPathComponent("\(kind).bin")
        guard let body = try? Data(contentsOf: url),
              let payload = CruiseMapCache.parse(body, key: key, kind: kind) else {
            try? FileManager.default.removeItem(at: url)
            lock.lock()
            present[key]?.remove(kind)
            if present[key]?.isEmpty == true { present.removeValue(forKey: key) }
            lock.unlock()
            onEvent?("cruise-cache-skip", ["reason": "corrupt", "blocks": order.count])
            return nil
        }
        lock.lock()
        if let i = order.firstIndex(of: key) { order.remove(at: i); order.append(key) }
        lock.unlock()
        return payload
    }

    /// 固定块保护（主线程，内存状态）：正在显示/传输/待交接的块键集合。
    func setPins(_ keys: Set<String>) {
        lock.lock(); pinned = keys; lock.unlock()
    }

    /// 当前索引统计（诊断/测试）。
    func stats() -> (blocks: Int, bytes: Int) {
        lock.lock(); defer { lock.unlock() }
        return (order.count, totalBytes)
    }

    // MARK: - 私有

    private func removeBlock(_ key: String) {
        try? FileManager.default.removeItem(at: root.appendingPathComponent(key, isDirectory: true))
        lock.lock()
        if let i = order.firstIndex(of: key) { order.remove(at: i) }
        totalBytes -= blockBytes.removeValue(forKey: key) ?? 0
        present.removeValue(forKey: key)
        lock.unlock()
        onEvent?("cruise-cache-evict", ["blocks": order.count])
    }

    private func rebuildIndex() {
        lock.lock()
        order = []; blockBytes = [:]; present = [:]; totalBytes = 0
        lock.unlock()
        guard let blocks = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey]) else { return }
        var entries: [(String, Date, Int, Set<String>)] = []
        for dir in blocks {
            guard (try? dir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
            var bytes = 0
            var kinds = Set<String>()
            if let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
                for f in files {
                    bytes += (try? f.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                    let name = f.lastPathComponent
                    if name.hasSuffix(".bin") { kinds.insert(String(name.dropLast(4))) }
                }
            }
            guard !kinds.isEmpty else { continue }
            let mtime = (try? dir.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            entries.append((dir.lastPathComponent, mtime, bytes, kinds))
        }
        entries.sort { $0.1 < $1.1 } // 旧→新
        lock.lock()
        order = entries.map { $0.0 }
        for e in entries { blockBytes[e.0] = e.2; present[e.0] = e.3 }
        totalBytes = entries.reduce(0) { $0 + $1.2 }
        lock.unlock()
    }

    /// 封装：魔数(4) + 摘要(4, FNV-1a 32 of key|kind) + 身份长度(2) + 身份(key) + 载荷。
    private static func frame(headerFor key: String, kind: String, payload: Data) -> Data {
        var out = Data(CruiseMapCache.headerMagic)
        let digest = CruiseMapCache.digest(key + "|" + kind)
        var d = digest.bigEndian; out.append(Data(bytes: &d, count: 4))
        let keyBytes = Array(key.utf8)
        var kl = UInt16(keyBytes.count).bigEndian; out.append(Data(bytes: &kl, count: 2))
        out.append(contentsOf: keyBytes)
        out.append(payload)
        return out
    }

    private static func parse(_ body: Data, key: String, kind: String) -> Data? {
        guard body.count > 10 else { return nil }
        let b = [UInt8](body.prefix(10))
        guard Array(b[0...3]) == CruiseMapCache.headerMagic else { return nil }
        let digest = UInt32(b[4]) << 24 | UInt32(b[5]) << 16 | UInt32(b[6]) << 8 | UInt32(b[7])
        guard digest == CruiseMapCache.digest(key + "|" + kind) else { return nil }
        let kl = Int(b[8]) << 8 | Int(b[9])
        guard body.count >= 10 + kl else { return nil }
        let stored = String(data: body.subdata(in: 10..<10+kl), encoding: .utf8)
        guard stored == key else { return nil }
        return body.subdata(in: 10+kl..<body.count)
    }

    private static func digest(_ s: String) -> UInt32 {
        var h: UInt64 = 0xcbf29ce484222325
        for byte in s.utf8 { h = (h ^ UInt64(byte)) &* 0x100000001b3 }
        return UInt32(truncatingIfNeeded: h)
    }
}
