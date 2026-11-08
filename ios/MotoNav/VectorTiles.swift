import Foundation
import Compression

/// 版本：OpenFreeMap 矢量瓦片阶段一（数据源验证）；正式接入时由调度层复用。
///
/// 职责（纯 Foundation + 系统压缩框架，宿主 swiftc 可编译）：
/// - TileJSON 解析：瓦片地址模板与数据版本（缓存键包含版本，不硬编码日期目录）
/// - 受约束下载：App 标识 UA、≤2 并发、单请求 15 秒超时、同瓦片请求合并、
///   原始响应 ≤4 MiB、解压后 ≤16 MiB、失败不写成功缓存、429 遵循 Retry-After、
///   其余失败 15 秒内不重试
/// - MVT（Mapbox Vector Tile）严格解码：varint/长度/计数/几何命令越界一律拒绝
///
/// 坐标约定：本文件只做「瓦片局部整数坐标」的解码；还原为 WGS84 后的 GCJ 转换
/// 与栅格化在 VectorMapRaster 中完成（图源入口只转换一次）。
enum VectorTileError: Error, CustomStringConvertible {
    case badTileJSON(String)
    case http(Int)
    case rateLimited(retryAfter: TimeInterval?)
    case tooLargeRaw
    case tooLargeInflated
    case inflateFailed
    case corrupt(String)
    case throttled(remaining: TimeInterval)
    case cancelled

    var description: String {
        switch self {
        case .badTileJSON(let w): return "TileJSON 无效: \(w)"
        case .http(let c): return "HTTP \(c)"
        case .rateLimited: return "429 限流"
        case .tooLargeRaw: return "原始响应超过 4 MiB"
        case .tooLargeInflated: return "解压后超过 16 MiB"
        case .inflateFailed: return "gzip 解压失败"
        case .corrupt(let w): return "MVT 数据损坏: \(w)"
        case .throttled(let r): return "失败冷却中(剩余\(Int(r))s)"
        case .cancelled: return "已取消"
        }
    }
}

// MARK: - gzip / zlib 解压（系统 Compression 框架，输出硬上限）

enum VectorGzip {
    /// 解压 gzip(0x1f8b) / zlib(0x78) 封装的 deflate 数据；maxOutput 越界抛错。
    /// 非压缩封包头时按原始 deflate 尝试。gzip 时校验尾部 ISIZE。
    static func inflate(_ input: Data, maxOutput: Int) throws -> Data {
        guard input.count >= 2 else { throw VectorTileError.inflateFailed }
        var payload: [UInt8]
        var wasGzip = false
        if input[input.startIndex] == 0x1f && input[input.startIndex + 1] == 0x8b {
            payload = [UInt8](try stripGzip(input))
            wasGzip = true
        } else if input[input.startIndex] == 0x78 {
            guard input.count >= 6 else { throw VectorTileError.inflateFailed }
            payload = [UInt8](input.dropFirst(2).dropLast(4))
        } else {
            payload = [UInt8](input)
        }

        var stream = compression_stream(dst_ptr: UnsafeMutablePointer<UInt8>(bitPattern: 1)!,
                                        dst_size: 0,
                                        src_ptr: UnsafePointer<UInt8>(bitPattern: 1)!,
                                        src_size: 0, state: nil)
        guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB)
                == COMPRESSION_STATUS_OK else { throw VectorTileError.inflateFailed }
        defer { compression_stream_destroy(&stream) }

        var out = [UInt8]()
        out.reserveCapacity(min(maxOutput, 1 << 18))
        let dstCap = 1 << 16
        var dst = [UInt8](repeating: 0, count: dstCap)
        var finalized = false

        try payload.withUnsafeBufferPointer { srcBuf in
            try dst.withUnsafeMutableBufferPointer { dstBuf in
                var consumed = 0
                loop: while true {
                    if !finalized {
                        stream.src_ptr = srcBuf.baseAddress! + consumed
                        stream.src_size = payload.count - consumed
                        if stream.src_size == 0 { finalized = true }
                    }
                    stream.dst_ptr = dstBuf.baseAddress!
                    stream.dst_size = dstCap
                    let flags = finalized ? Int32(bitPattern: COMPRESSION_STREAM_FINALIZE.rawValue) : 0
                    let st = compression_stream_process(&stream, flags)
                    if stream.dst_size > 0 {
                        if out.count + stream.dst_size > maxOutput { throw VectorTileError.tooLargeInflated }
                        out.append(contentsOf: dstBuf[0 ..< Int(stream.dst_size)])
                    }
                    switch st {
                    case COMPRESSION_STATUS_END:
                        break loop
                    case COMPRESSION_STATUS_ERROR:
                        throw VectorTileError.inflateFailed
                    default:
                        if !finalized {
                            consumed = payload.count - Int(stream.src_size)
                        } else if stream.dst_size == 0 {
                            // 已 finalize 仍无输出无结束：截断
                            throw VectorTileError.inflateFailed
                        }
                    }
                }
            }
        }
        if wasGzip {
            // 尾部 8 字节：CRC32(4) + ISIZE(4, 小端，原始长度低 32 位)
            var isize = 0
            for (i, b) in input.suffix(4).enumerated() { isize |= Int(b) << (8 * i) }
            if isize != out.count & 0xffffffff { throw VectorTileError.inflateFailed }
        }
        return Data(out)
    }

    /// 解析 gzip 头（含 FEXTRA/FNAME/FCOMMENT/FHCRC），返回 deflate 载荷（去尾部 8 字节）。
    private static func stripGzip(_ d: Data) throws -> Data {
        guard d.count >= 18 else { throw VectorTileError.inflateFailed } // 头10 + 尾8 至少
        let b = [UInt8](d.prefix(10))
        guard b[2] == 8, b[3] & 0xE0 == 0 else { throw VectorTileError.inflateFailed }
        var p = 10
        let flg = b[3]
        if flg & 0x04 != 0 { // FEXTRA
            guard d.count >= p + 2 else { throw VectorTileError.inflateFailed }
            let xlen = Int(d[d.startIndex + p]) | Int(d[d.startIndex + p + 1]) << 8
            p += 2 + xlen
        }
        if flg & 0x08 != 0 { // FNAME
            while p < d.count && d[d.startIndex + p] != 0 { p += 1 }
            p += 1
        }
        if flg & 0x10 != 0 { // FCOMMENT
            while p < d.count && d[d.startIndex + p] != 0 { p += 1 }
            p += 1
        }
        if flg & 0x02 != 0 { p += 2 } // FHCRC
        guard d.count >= p + 8 else { throw VectorTileError.inflateFailed }
        return d.subdata(in: d.startIndex + p ..< d.endIndex - 8)
    }
}

// MARK: - MVT 解码

/// 解码后的瓦片：仅保留渲染需要的图层、要素与字符串属性。
struct MVTTile {
    struct Feature {
        let type: UInt8                       // 1 点 2 线 3 面（点要素本管线不用）
        let tags: [Int]                       // 键值下标交错
        var lines: [[(Int, Int)]] = []        // 线要素：多条路径（瓦片局部整数坐标）
        var polygons: [[(Int, Int)]] = []     // 面要素：所有环平铺（偶奇填充处理孔洞）
    }
    struct Layer {
        let extent: Int
        let keys: [String]
        let values: [String]                  // 非字符串属性以空串占位
        let features: [Feature]
        func attr(_ f: Feature, _ key: String) -> String? {
            var i = 0
            while i + 1 < f.tags.count {
                let k = f.tags[i], v = f.tags[i + 1]
                if k >= 0, k < keys.count, keys[k] == key, v >= 0, v < values.count {
                    return values[v]
                }
                i += 2
            }
            return nil
        }
    }
    let layers: [String: Layer]

    // 防越界上限：远超真实城市瓦片的合法量级，超出即拒绝。
    static let maxLayerFeatures = 200_000
    static let maxGeomVarints = 2_000_000
    static let maxPointsPerFeature = 100_000
    static let maxExtent = 1 << 16

    static func decode(_ data: Data, keepLayers: Set<String>) throws -> MVTTile {
        var r = Reader(data)
        var layers: [String: Layer] = [:]
        while let f = try r.varintField() {
            guard f.tag == 3, f.wire == 2 else { try r.skip(f); continue }
            let (name, layer) = try decodeLayer(try r.bytes())
            if keepLayers.contains(name) { layers[name] = layer }
        }
        guard !layers.isEmpty else { throw VectorTileError.corrupt("无已知图层") }
        return MVTTile(layers: layers)
    }

    private static func decodeLayer(_ data: Data) throws -> (String, Layer) {
        var r = Reader(data)
        var name: String?
        var featureDatas: [Data] = []
        var keys: [String] = []
        var valueStrings: [String] = []
        var extent = 4096
        while let f = try r.varintField() {
            switch (f.tag, f.wire) {
            case (1, 2): name = try r.string()
            case (2, 2): featureDatas.append(try r.bytes())
            case (3, 2): keys.append(try r.string())
            case (4, 2): valueStrings.append(try decodeValue(try r.bytes()))
            case (5, 0): extent = Int(try r.varint())
            case (15, 0): _ = try r.varint()   // 图层版本，不消费
            default: try r.skip(f)
            }
        }
        guard let layerName = name, extent > 0, extent <= maxExtent else {
            throw VectorTileError.corrupt("图层名/extent 缺失")
        }
        guard featureDatas.count <= maxLayerFeatures else {
            throw VectorTileError.corrupt("要素数越界(\(featureDatas.count))")
        }
        var features: [Feature] = []
        features.reserveCapacity(featureDatas.count)
        for fd in featureDatas {
            if let f = try decodeFeature(fd, extent: extent) { features.append(f) }
        }
        return (layerName, Layer(extent: extent, keys: keys, values: valueStrings, features: features))
    }

    private static func decodeValue(_ data: Data) throws -> String {
        var r = Reader(data)
        while let f = try r.varintField() {
            switch (f.tag, f.wire) {
            case (1, 2): return try r.string()
            case (2, 5): // float
                return ""   // 浮点属性本管线不消费
            case (4, 0): return String(Int64(bitPattern: try r.varint()))   // int64
            case (5, 0): return String(try r.varint())                      // uint64
            case (6, 0): return String(MVTTile.zigzagDecode(try r.varint())) // sint64(zigzag)
            case (7, 0): return (try r.varint()) != 0 ? "true" : "false"
            default: try r.skip(f)
            }
        }
        return ""
    }

    private static func decodeFeature(_ data: Data, extent: Int) throws -> Feature? {
        var r = Reader(data)
        var type: UInt8 = 0
        var tags: [Int] = []
        var geometry: [UInt64] = []
        while let f = try r.varintField() {
            switch (f.tag, f.wire) {
            case (2, 2):
                var pr = Reader(try r.bytes())
                while pr.remaining > 0 { tags.append(Int(try pr.varint())) }
            case (3, 0): type = UInt8(truncatingIfNeeded: try r.varint())
            case (4, 2):
                var pr = Reader(try r.bytes())
                while pr.remaining > 0 { geometry.append(try pr.varint()) }
            default: try r.skip(f)
            }
        }
        guard type == 2 || type == 3, !geometry.isEmpty else { return nil }
        guard geometry.count <= maxGeomVarints else {
            throw VectorTileError.corrupt("geometry 命令数越界")
        }
        var lines: [[(Int, Int)]] = []
        var polygons: [[(Int, Int)]] = []
        var cur: [(Int, Int)] = []
        var x = 0, y = 0
        var i = 0
        let lo = -extent, hi = extent * 2   // 允许瓦片缓冲，超出即拒绝
        func endPath(polygon: Bool) {
            guard cur.count >= (polygon ? 3 : 2) else { cur = []; return }
            if polygon { polygons.append(cur) } else { lines.append(cur) }
            cur = []
        }
        while i < geometry.count {
            let cmd = geometry[i]; i += 1
            let id = cmd & 0x7, count = Int(cmd >> 3)
            if id == 7 { // ClosePath
                guard type == 3 else { throw VectorTileError.corrupt("线要素出现 ClosePath") }
                if let s = cur.first, s != (x, y) { cur.append(s) }
                endPath(polygon: true)
                continue
            }
            guard id == 1 || id == 2, count >= 1 else {
                throw VectorTileError.corrupt("非法几何命令 \(id)")
            }
            guard i + 2 * count <= geometry.count, 2 * count <= maxPointsPerFeature * 2 else {
                throw VectorTileError.corrupt("几何参数不足或越界")
            }
            if id == 1 { endPath(polygon: type == 3) }   // MoveTo 开新路径/新环
            for _ in 0 ..< count {
                let dx = zigzagDecode(geometry[i]), dy = zigzagDecode(geometry[i + 1])
                i += 2
                x += dx; y += dy
                guard (lo...hi).contains(x), (lo...hi).contains(y) else {
                    throw VectorTileError.corrupt("坐标越界(\(x),\(y))")
                }
                cur.append((x, y))
                if cur.count > maxPointsPerFeature { throw VectorTileError.corrupt("点数越界") }
            }
        }
        endPath(polygon: type == 3)
        if type == 3 {
            guard !polygons.isEmpty else { return nil }
        } else {
            guard !lines.isEmpty else { return nil }
        }
        return Feature(type: type, tags: tags, lines: lines, polygons: polygons)
    }

    static func zigzagDecode(_ v: UInt64) -> Int {
        Int(v >> 1) ^ (v & 1 == 1 ? -1 : 0)
    }

    /// protobuf 读取器：varint 限 10 字节防溢出；长度字段限剩余字节数。
    struct Reader {
        let buf: [UInt8]
        var p = 0
        init(_ d: Data) { buf = [UInt8](d) }
        var remaining: Int { buf.count - p }
        struct Field { let tag: Int; let wire: Int }
        mutating func varintField() throws -> Field? {
            guard remaining > 0 else { return nil }
            let key = try varint()
            return Field(tag: Int(key >> 3), wire: Int(key & 7))
        }
        mutating func varint() throws -> UInt64 {
            var result: UInt64 = 0
            for shift in stride(from: 0, through: 63, by: 7) {
                guard p < buf.count else { throw VectorTileError.corrupt("varint 截断") }
                let b = buf[p]; p += 1
                if shift == 63 && b > 1 { throw VectorTileError.corrupt("varint 溢出") }
                result |= UInt64(b & 0x7f) << shift
                if b & 0x80 == 0 { return result }
            }
            throw VectorTileError.corrupt("varint 超过10字节")
        }
        mutating func bytes() throws -> Data {
            let len = Int(try varint())
            guard len <= remaining else { throw VectorTileError.corrupt("长度越界(\(len)>\(remaining))") }
            defer { p += len }
            return Data(buf[p ..< p + len])
        }
        mutating func string() throws -> String {
            let d = try bytes()
            guard let s = String(data: d, encoding: .utf8) else {
                throw VectorTileError.corrupt("非法 UTF-8")
            }
            return s
        }
        mutating func skip(_ f: Field) throws {
            switch f.wire {
            case 0: _ = try varint()
            case 1: p += 8
            case 2: _ = try bytes()
            case 5: p += 4
            default: throw VectorTileError.corrupt("wire type \(f.wire)")
            }
            guard p <= buf.count else { throw VectorTileError.corrupt("skip 越界") }
        }
    }
}

// MARK: - 图源客户端

/// 原始瓦片磁盘缓存：压缩响应原样落盘（48 MiB LRU，键=数据代次/z/x/y）。
/// 读盘/校验/修剪都在调用方工作队列同步执行；内存索引先判 miss，热路径零磁盘。
/// 损坏（魔数/长度不符）即删文件返回 nil，不阻断补图。
final class VectorTileDiskStore {
    static let budget = 48 * 1024 * 1024
    private static let magic: [UInt8] = Array("VTD1".utf8)
    private let root: URL
    private let lock = NSLock()
    private var order: [String] = []      // 旧→新
    private var sizes: [String: Int] = [:]
    private var total = 0
    private var present = Set<String>()

    init(root: URL) {
        self.root = root
        rebuild()
    }

    private func url(_ key: String) -> URL {
        root.appendingPathComponent(key.replacingOccurrences(of: "/", with: "_") + ".mvt")
    }

    func read(_ key: String) -> Data? {
        lock.lock(); let known = present.contains(key); lock.unlock()
        guard known else { return nil }
        guard let body = try? Data(contentsOf: url(key)) else { return nil }
        guard body.count > 8, Array(body.prefix(4)) == VectorTileDiskStore.magic else {
            try? FileManager.default.removeItem(at: url(key)); forget(key); return nil
        }
        let len = Int(body[4]) << 24 | Int(body[5]) << 16 | Int(body[6]) << 8 | Int(body[7])
        guard body.count - 8 == len else {
            try? FileManager.default.removeItem(at: url(key)); forget(key); return nil
        }
        lock.lock()
        if let i = order.firstIndex(of: key) { order.remove(at: i); order.append(key) }
        lock.unlock()
        return body.dropFirst(8)
    }

    /// 原子写（排除备份+首次解锁前保护）；超预算从最旧开始修剪；失败静默。
    func write(_ key: String, _ raw: Data) {
        guard !raw.isEmpty else { return }
        var body = Data(VectorTileDiskStore.magic)
        var len = UInt32(raw.count).bigEndian
        body.append(Data(bytes: &len, count: 4))
        body.append(raw)
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try body.write(to: url(key), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            var target = url(key)
            var rv = URLResourceValues()
            rv.isExcludedFromBackup = true
            try? target.setResourceValues(rv)
        } catch { return }
        lock.lock()
        if let i = order.firstIndex(of: key) {
            total -= sizes.removeValue(forKey: key) ?? 0
            order.remove(at: i)
        }
        order.append(key)
        sizes[key] = body.count
        total += body.count
        present.insert(key)
        var victims: [String] = []
        while total > VectorTileDiskStore.budget, let oldest = order.first, oldest != key {
            victims.append(oldest)
            order.removeFirst()
            total -= sizes.removeValue(forKey: oldest) ?? 0
            present.remove(oldest)
        }
        lock.unlock()
        for v in victims { try? FileManager.default.removeItem(at: url(v)) }
    }

    func remove(_ key: String) {
        try? FileManager.default.removeItem(at: url(key))
        forget(key)
    }

    private func forget(_ key: String) {
        lock.lock()
        if let i = order.firstIndex(of: key) { order.remove(at: i) }
        total -= sizes.removeValue(forKey: key) ?? 0
        present.remove(key)
        lock.unlock()
    }

    private func rebuild() {
        lock.lock(); order = []; sizes = [:]; total = 0; present = []; lock.unlock()
        guard let files = try? FileManager.default.contentsOfDirectory(at: root,
                includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]) else { return }
        var entries: [(String, Date, Int)] = []
        for f in files where f.pathExtension == "mvt" {
            // 文件名把键里的 "/" 存成 "_"（键=代次/z/x/y，不含下划线），恢复原始键
            let key = f.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "_", with: "/")
            let size = (try? f.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            let mtime = (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            entries.append((key, mtime, size))
        }
        entries.sort { $0.1 < $1.1 }
        lock.lock()
        order = entries.map { $0.0 }
        for e in entries { sizes[e.0] = e.2 }
        total = entries.reduce(0) { $0 + $1.2 }
        present = Set(order)
        lock.unlock()
    }

    func stats() -> (count: Int, bytes: Int) {
        lock.lock(); defer { lock.unlock() }
        return (order.count, total)
    }
}

/// URLSessionTaskMetrics 采集：metrics 属性读取不可靠，统一走 delegate didFinishCollecting（SDK 探针结论）。
final class VectorMetricsCollector: NSObject, URLSessionDataDelegate {
    private let lock = NSLock()
    private var store: [Int: URLSessionTaskMetrics] = [:]

    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        lock.lock()
        store[task.taskIdentifier] = metrics
        lock.unlock()
    }

    func take(taskIdentifier: Int) -> URLSessionTaskMetrics? {
        lock.lock(); defer { lock.unlock() }
        return store.removeValue(forKey: taskIdentifier)
    }
}

/// OpenFreeMap 客户端：同步接口，供后台串行队列调用。
/// 网络（fetch）、时钟（now）与引导目录（bootstrapDirectory）可注入供宿主测试；
/// 数据代次 = 规范化模板 + TileJSON version 联合散列——模板路径里的日期目录才是
/// 实际数据代次来源，仅靠长期不变的 version 字段（"3.16.0"）会漏失效。
final class VectorTileClient {
    static let tileJSONURL = URL(string: "https://tiles.openfreemap.org/planet")!
    static let userAgent = "MotoNav/0.16.0 (iOS; OpenFreeMap raster consumer; contact: in-app settings)"
    static let revalidationInterval: TimeInterval = 24 * 3600

    private let metrics = VectorMetricsCollector()
    private let session: URLSession
    private let timeout: TimeInterval
    private let lock = NSLock()
    private let concurrencySlot: DispatchSemaphore
    private var inflight: [String: ResultBox] = [:]
    private var failureUntil: [String: Date] = [:]
    private(set) var template: String = ""
    private(set) var dataVersion: String = ""
    /// 当前数据代次（模板+版本散列）；空表示未就绪。缓存键以代次为前缀实现代次隔离。
    private(set) var dataGeneration = ""
    private var lastValidatedAt: Date? = nil
    private var didLoadDiskBootstrap = false
    private let bootstrapDirectory: URL?
    /// 原始瓦片磁盘层（压缩响应 48 MiB LRU）；nil 时禁用（宿主测试控制）。
    let tileDisk: VectorTileDiskStore?

    /// 可注入依赖（宿主测试替换；生产保持系统默认）。
    /// fetch 返回 (数据, 响应, 资源获取类型列表)。
    var fetch: ((URLRequest) throws -> (Data, URLResponse, [String]))? = nil
    var now: () -> Date = { Date() }
    /// 诊断出口：事件名 + 白名单字段（匿名瓦片散列、代次、字节数、来源），不含坐标与 URL。
    var onEvent: ((String, [String: Any]) -> Void)? = nil

    // 进程内有界 LRU（48 MiB，访问序）：同帧相邻块与风格重绘复用瓦片，
    // 命中即移到队尾；数据代次变化时整体失效。
    static let cacheLimit = 48 * 1024 * 1024
    private var cache: [String: Data] = [:]
    private var cacheOrder: [String] = []
    private var cacheBytes = 0

    /// 同瓦片并发合并槽：owner 负责下载；waiters 供取消判定——
    /// 取消只丢弃"无其他使用者"的下载，有等待者则继续完成共享结果。
    final class ResultBox {
        let condition = NSCondition()
        var done = false
        var data: Data?
        var error: Error?
        var waiters = 0
    }

    init(maxConcurrent: Int = 2, timeout: TimeInterval = 15, bootstrapDirectory: URL? = nil,
         tileDiskDirectory: URL? = nil) {
        self.timeout = timeout
        self.concurrencySlot = DispatchSemaphore(value: maxConcurrent)
        self.bootstrapDirectory = bootstrapDirectory
        if let dir = tileDiskDirectory {
            self.tileDisk = VectorTileDiskStore(root: dir)
        } else {
            self.tileDisk = nil
        }
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = timeout
        cfg.httpAdditionalHeaders = ["User-Agent": VectorTileClient.userAgent]
        self.session = URLSession(configuration: cfg, delegate: metrics, delegateQueue: nil)
        if let dir = bootstrapDirectory {
            loadPersistedBootstrap(from: dir)
        }
    }

    /// 数据代次：规范化模板 + version 联合 FNV-1a 64（截断 UInt32，8 hex）。
    static func generation(template: String, version: String) -> String {
        var h: UInt64 = 0xcbf29ce484222325
        for b in (template + "\u{1f}" + version).utf8 {
            h = (h ^ UInt64(b)) &* 0x100000001b3
        }
        return String(format: "%08x", UInt32(truncatingIfNeeded: h))
    }

    /// 匿名瓦片标识（诊断日志用；瓦片坐标可反推位置，日志只出散列）。
    static func tileHash(_ z: Int, _ x: Int, _ y: Int) -> String {
        var h: UInt64 = 0xcbf29ce484222325
        for b in "\(z)/\(x)/\(y)".utf8 {
            h = (h ^ UInt64(b)) &* 0x100000001b3
        }
        return String(format: "%08x", UInt32(truncatingIfNeeded: h))
    }

    /// 引导与刷新：模板为空时联网引导；距上次验证超 24 小时（或从未验证）时联网重验，
    /// 刷新失败保留最后有效模板不抛错（下次再试）。
    func ensureReady() {
        lock.lock()
        let empty = template.isEmpty
        let last = lastValidatedAt
        let diskBootstrap = didLoadDiskBootstrap
        let gen = dataGeneration
        let age: TimeInterval
        if let l = last { age = now().timeIntervalSince(l) } else { age = -1 }
        didLoadDiskBootstrap = false
        lock.unlock()
        if diskBootstrap {
            onEvent?("tilejson-bootstrap", ["generation": gen, "ageSeconds": Int(age.rounded())])
        }
        let stale: Bool
        if let l = last { stale = now().timeIntervalSince(l) > VectorTileClient.revalidationInterval }
        else { stale = true }
        if empty || stale {
            try? loadTileJSON()
        }
    }

    /// 拉取并解析 TileJSON；校验（tiles 模板含 {z}/{x}/{y}）通过才切换并整体失效旧代次缓存，
    /// 成功后持久化引导记录。失败抛错且不改变现有模板。
    func loadTileJSON() throws {
        let (data, response, types) = try perform(VectorTileClient.tileJSONURL)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw VectorTileError.http((response as? HTTPURLResponse)?.statusCode ?? -1)
        }
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let tiles = obj["tiles"] as? [String], let first = tiles.first,
              first.contains("{z}"), first.contains("{x}"), first.contains("{y}") else {
            throw VectorTileError.badTileJSON("tiles 模板缺失或缺少 {z}/{x}/{y}")
        }
        let newVersion = (obj["version"] as? String) ?? ""
        let newGeneration = VectorTileClient.generation(template: first, version: newVersion)
        lock.lock()
        if newGeneration != dataGeneration {
            cache.removeAll(); cacheOrder.removeAll(); cacheBytes = 0
            failureUntil.removeAll()
            template = first
            dataVersion = newVersion
            dataGeneration = newGeneration
        }
        lastValidatedAt = now()
        lock.unlock()
        persistBootstrap(template: first, version: newVersion)
        onEvent?("tilejson", ["generation": newGeneration, "fetchTypes": types])
    }

    func tileURL(z: Int, x: Int, y: Int) -> URL? {
        lock.lock(); defer { lock.unlock() }
        guard !template.isEmpty else { return nil }
        var s = template
        if s.contains("{version}") {
            s = s.replacingOccurrences(of: "{version}", with: dataVersion.isEmpty ? "0" : dataVersion)
        }
        s = s.replacingOccurrences(of: "{z}", with: String(z))
            .replacingOccurrences(of: "{x}", with: String(x))
            .replacingOccurrences(of: "{y}", with: String(y))
        return URL(string: s)
    }

    /// 下载并解压一个瓦片；缓存/合并命中直取，失败受 15 秒冷却与 429 Retry-After 约束，
    /// 同代次同瓦片并发只下载一次。shouldCancel 为块级取消探询：仅当无其他等待者时
    /// 才允许取消丢弃。返回解压后的 MVT 字节（≤16 MiB）。
    func fetchTile(z: Int, x: Int, y: Int, shouldCancel: (() -> Bool)? = nil) throws -> Data {
        lock.lock()
        let generation = dataGeneration
        guard !generation.isEmpty else {
            lock.unlock()
            throw VectorTileError.badTileJSON("模板未加载")
        }
        let key = generation + "/" + "\(z)/\(x)/\(y)"
        if let hit = cache[key] {
            if let i = cacheOrder.firstIndex(of: key) { cacheOrder.remove(at: i); cacheOrder.append(key) }
            lock.unlock()
            onEvent?("vector-tile", ["tile": VectorTileClient.tileHash(z, x, y),
                                     "generation": generation, "origin": "memory"])
            return hit
        }
        if let until = failureUntil[key], until > now() {
            let remaining = until.timeIntervalSince(now())
            lock.unlock()
            throw VectorTileError.throttled(remaining: remaining)
        }
        // 内存 miss → 磁盘原始瓦片（压缩响应；命中即解压并回填内存，零网络）。
        // 注意：此处仍持有 client lock（下方 inflight 注册前统一释放），NSLock 不可重入，
        // 回填内存直接操作缓存结构，不得再 lock。
        if let disk = tileDisk, let raw = disk.read(key) {
            do {
                var body = raw
                if body.count >= 2, (body[body.startIndex] == 0x1f && body[body.startIndex + 1] == 0x8b)
                    || body[body.startIndex] == 0x78 {
                    body = try VectorGzip.inflate(body, maxOutput: 16 * 1024 * 1024)
                }
                guard body.count <= 16 * 1024 * 1024 else { throw VectorTileError.tooLargeInflated }
                if cache[key] == nil {
                    cache[key] = body
                    cacheOrder.append(key)
                    cacheBytes += body.count
                    while cacheBytes > VectorTileClient.cacheLimit, let oldest = cacheOrder.first {
                        cacheOrder.removeFirst()
                        if let removed = cache.removeValue(forKey: oldest) { cacheBytes -= removed.count }
                    }
                }
                lock.unlock()
                onEvent?("vector-tile", ["tile": VectorTileClient.tileHash(z, x, y),
                                         "generation": generation, "origin": "disk", "bytes": body.count])
                return body
            } catch {
                // 磁盘瓦片损坏：删除文件走网络（仍持有锁，继续下方流程）
                disk.remove(key)
            }
        }
        var isOwner = false
        var box = inflight[key]
        if box == nil {
            let nb = ResultBox()
            inflight[key] = nb
            box = nb
            isOwner = true
        }
        guard let b = box else { fatalError("unreachable") }
        if !isOwner { b.waiters += 1 }
        lock.unlock()

        if isOwner {
            b.condition.lock()
            download(z: z, x: x, y: y, key: key, generation: generation, box: b, shouldCancel: shouldCancel)
            b.done = true
            b.condition.broadcast()
            b.condition.unlock()
            lock.lock()
            if inflight[key] === b { inflight[key] = nil }
            lock.unlock()
        } else {
            b.condition.lock()
            while !b.done { b.condition.wait() }
            b.condition.unlock()
            lock.lock()
            b.waiters -= 1
            lock.unlock()
        }

        if let e = b.error { throw e }
        guard let d = b.data else { throw VectorTileError.cancelled }
        if isOwner {
            lock.lock()
            // 代次已切换：旧请求结果不写入新代次缓存
            if dataGeneration == generation, cache[key] == nil {
                cache[key] = d
                cacheOrder.append(key)
                cacheBytes += d.count
                while cacheBytes > VectorTileClient.cacheLimit, let oldest = cacheOrder.first {
                    cacheOrder.removeFirst()
                    if let removed = cache.removeValue(forKey: oldest) { cacheBytes -= removed.count }
                }
            }
            lock.unlock()
        }
        return d
    }

    private func download(z: Int, x: Int, y: Int, key: String, generation: String,
                          box: ResultBox, shouldCancel: (() -> Bool)?) {
        let tile = VectorTileClient.tileHash(z, x, y)
        // 已取消且无人共用：直接放弃，不排队不发布（等待者下轮重新发起）
        if let cancelled = shouldCancel, cancelled(), sharedWaiters(box) == 0 {
            box.error = VectorTileError.cancelled
            onEvent?("vector-tile-fail", ["tile": tile, "generation": generation, "reason": "cancelled"])
            return
        }
        guard let url = tileURL(z: z, x: x, y: y) else {
            box.error = VectorTileError.badTileJSON("模板未加载")
            return
        }
        concurrencySlot.wait()
        // 排队后再次确认取消
        if let cancelled = shouldCancel, cancelled(), sharedWaiters(box) == 0 {
            concurrencySlot.signal()
            box.error = VectorTileError.cancelled
            onEvent?("vector-tile-fail", ["tile": tile, "generation": generation, "reason": "cancelled"])
            return
        }
        var raw: Data?
        do {
            let (data, resp, _) = try perform(url)
            let http = resp as? HTTPURLResponse
            let code = http?.statusCode ?? -1
            if code == 429 {
                var retry: TimeInterval? = nil
                if let ra = http?.value(forHTTPHeaderField: "Retry-After"), let secs = Double(ra) {
                    retry = secs
                }
                markFailure(key, after: retry ?? 60)
                box.error = VectorTileError.rateLimited(retryAfter: retry)
                onEvent?("vector-tile-fail", ["tile": tile, "generation": generation,
                                              "reason": "429", "retryAfter": retry ?? 60])
            } else if code != 200 {
                markFailure(key, after: 15)
                box.error = VectorTileError.http(code)
                onEvent?("vector-tile-fail", ["tile": tile, "generation": generation,
                                              "reason": "http", "code": code])
            } else if data.count > 4 * 1024 * 1024 {
                markFailure(key, after: 15)
                box.error = VectorTileError.tooLargeRaw
                onEvent?("vector-tile-fail", ["tile": tile, "generation": generation, "reason": "too-large-raw"])
            } else {
                raw = data
            }
        } catch let e {
            markFailure(key, after: 15)
            box.error = e
            onEvent?("vector-tile-fail", ["tile": tile, "generation": generation, "reason": "error"])
        }
        concurrencySlot.signal()
        guard var body = raw else { return }
        do {
            if body.count >= 2, (body[body.startIndex] == 0x1f && body[body.startIndex + 1] == 0x8b)
                || body[body.startIndex] == 0x78 {
                body = try VectorGzip.inflate(body, maxOutput: 16 * 1024 * 1024)
            }
            guard body.count <= 16 * 1024 * 1024 else { throw VectorTileError.tooLargeInflated }
            // 完成后取消且无人共用：丢弃不发布
            if let cancelled = shouldCancel, cancelled(), sharedWaiters(box) == 0 {
                box.error = VectorTileError.cancelled
                onEvent?("vector-tile-fail", ["tile": tile, "generation": generation, "reason": "cancelled"])
                return
            }
            box.data = body
            lock.lock()
            // 成功清除该瓦片的历史冷却，避免陈旧冷却误伤
            failureUntil.removeValue(forKey: key)
            lock.unlock()
            // 原始压缩响应落磁盘层（48 MiB LRU）；写失败不影响交付
            if let disk = tileDisk { disk.write(key, raw ?? body) }
            onEvent?("vector-tile", ["tile": tile, "generation": generation,
                                     "origin": "network", "bytes": body.count])
        } catch let e {
            markFailure(key, after: 15)
            box.error = e
            onEvent?("vector-tile-fail", ["tile": tile, "generation": generation, "reason": "inflate"])
        }
    }

    private func sharedWaiters(_ box: ResultBox) -> Int {
        lock.lock(); defer { lock.unlock() }
        return box.waiters
    }

    private func markFailure(_ key: String, after: TimeInterval) {
        lock.lock()
        failureUntil[key] = now().addingTimeInterval(after)
        // 冷却表及时清理：超过 512 条先剔除已过期项，防止长期巡航下的无界增长
        if failureUntil.count > 512 {
            let cutoff = now()
            failureUntil = failureUntil.filter { $0.value > cutoff }
        }
        lock.unlock()
    }

    private func perform(_ url: URL) throws -> (Data, URLResponse, [String]) {
        var req = URLRequest(url: url)
        req.timeoutInterval = timeout
        // 拿原始 gzip 字节以执行 4 MiB 原始上限；禁用透明解压
        req.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if let injected = fetch {
            return try injected(req)
        }
        return try systemFetch(req)
    }

    private func systemFetch(_ req: URLRequest) throws -> (Data, URLResponse, [String]) {
        var data: Data?
        var resp: URLResponse?
        var getError: Error?
        let done = DispatchSemaphore(value: 0)
        let task = session.dataTask(with: req) { d, r, e in
            data = d; resp = r; getError = e
            done.signal()
        }
        task.resume()
        done.wait()
        if let e = getError { throw e }
        // didFinishCollecting 与完成回调先后无保证，短暂等待采集落地（区分真实网络与缓存）
        var collected: URLSessionTaskMetrics? = nil
        for _ in 0..<20 {
            collected = metrics.take(taskIdentifier: task.taskIdentifier)
            if collected != nil { break }
            Thread.sleep(forTimeInterval: 0.01)
        }
        var types: [String] = []
        if let m = collected {
            for t in m.transactionMetrics {
                if let n = VectorTileClient.fetchTypeName(t.resourceFetchType) {
                    types.append(n)
                }
            }
        }
        return (data ?? Data(), resp ?? URLResponse(url: req.url ?? VectorTileClient.tileJSONURL,
                                                    mimeType: nil, expectedContentLength: -1,
                                                    textEncodingName: nil), types)
    }

    /// 诊断只区分"真实网络 vs 缓存"两类；其余获取类型不计入（跨 SDK 用例名不完全一致）。
    private static func fetchTypeName(_ t: URLSessionTaskMetrics.ResourceFetchType?) -> String? {
        switch t {
        case .networkLoad: return "network"
        case .localCache: return "cache"
        default: return nil
        }
    }

    private struct BootstrapRecord: Codable {
        var template: String
        var version: String
        var validatedAt: Date
    }

    private static let bootstrapFileName = "openfreemap-bootstrap.json"

    private func persistBootstrap(template: String, version: String) {
        guard let dir = bootstrapDirectory else { return }
        let rec = BootstrapRecord(template: template, version: version, validatedAt: now())
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let enc = JSONEncoder()
            enc.dateEncodingStrategy = .iso8601
            let body = try enc.encode(rec)
            var dst = dir.appendingPathComponent(VectorTileClient.bootstrapFileName)
            try body.write(to: dst, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            var rv = URLResourceValues()
            rv.isExcludedFromBackup = true
            try? dst.setResourceValues(rv)
        } catch {
            // 引导持久化失败不阻断链路；下次联网成功时重写
        }
    }

    private func loadPersistedBootstrap(from dir: URL) {
        let dst = dir.appendingPathComponent(VectorTileClient.bootstrapFileName)
        guard let body = try? Data(contentsOf: dst) else { return }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        guard let rec = try? dec.decode(BootstrapRecord.self, from: body),
              !rec.template.isEmpty,
              rec.template.contains("{z}"), rec.template.contains("{x}"), rec.template.contains("{y}") else {
            return // 损坏或字段不全：丢弃，走联网引导
        }
        lock.lock()
        template = rec.template
        dataVersion = rec.version
        dataGeneration = VectorTileClient.generation(template: rec.template, version: rec.version)
        lastValidatedAt = rec.validatedAt
        didLoadDiskBootstrap = true
        lock.unlock()
    }
}
