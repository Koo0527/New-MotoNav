// VectorTileClient 可靠性宿主回归：请求合并/取消语义/429 节流/数据代次/
// 持久化引导/24h 重验/冷却清理。全部离线（注入 fetch/now/目录），只编译 VectorTiles.swift。
import Foundation

var passed = 0
func check(_ cond: Bool, _ name: String) {
    precondition(cond, "FAIL: \(name)")
    passed += 1
    print("PASS \(name)")
}

/// 可注入网络：按 URL 前缀路由，记录调用与并发峰值。
final class FakeNet {
    let lock = NSLock()
    private var handlers: [(String, (URLRequest) throws -> (Data, URLResponse, [String]))] = []
    private var inflight = 0
    private(set) var calls: [String] = []
    private(set) var maxInflight = 0

    func on(_ prefix: String, _ h: @escaping (URLRequest) throws -> (Data, URLResponse, [String])) {
        lock.lock()
        handlers.removeAll { $0.0 == prefix } // 同前缀覆盖：后注册生效
        handlers.append((prefix, h))
        lock.unlock()
    }
    func http(_ url: String, _ code: Int, headers: [String: String] = [:],
              body: Data = Data("{\"tiles\":[\"https://t.example/20261101/{z}/{x}/{y}\"],\"version\":\"3.16.0\"}".utf8))
        -> (Data, URLResponse, [String]) {
        let resp = HTTPURLResponse(url: URL(string: url)!, statusCode: code, httpVersion: nil, headerFields: headers)!
        return (body, resp, ["network"])
    }
    func route(_ req: URLRequest) throws -> (Data, URLResponse, [String]) {
        let url = req.url!.absoluteString
        lock.lock()
        inflight += 1; maxInflight = max(maxInflight, inflight); calls.append(url)
        let hs = handlers.sorted { $0.0.count > $1.0.count } // 最长前缀优先：具体路径 handler 覆盖通用
        lock.unlock()
        defer { lock.lock(); inflight -= 1; lock.unlock() }
        for (prefix, h) in hs where url.hasPrefix(prefix) {
            return try h(req)
        }
        throw NSError(domain: "fakenet-unmatched", code: -1, userInfo: [NSLocalizedDescriptionKey: url])
    }
    func callCount(_ contains: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        return calls.filter { $0.contains(contains) }.count
    }
    func waitCalls(_ contains: String, _ n: Int) {
        for _ in 0..<1000 where callCount(contains) < n { Thread.sleep(forTimeInterval: 0.01) }
    }
}

final class Clock { var now = Date(timeIntervalSince1970: 1_800_000_000) }

func tileJSONBody(_ template: String, version: String = "3.16.0") -> Data {
    Data("{\"tiles\":[\"\(template)\"],\"version\":\"\(version)\"}".utf8)
}
func planetOK(_ template: String) -> (URLRequest) throws -> (Data, URLResponse, [String]) {
    { _ in (tileJSONBody(template),
            HTTPURLResponse(url: VectorTileClient.tileJSONURL, statusCode: 200, httpVersion: nil, headerFields: [:])!,
            ["network"]) }
}
func okTile(_ req: URLRequest) -> (Data, URLResponse, [String]) {
    (Data([0x11, 0x22, 0x33]),
     HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: [:])!, ["network"])
}

let tmpRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
    .appendingPathComponent("vector-reliability-\(UUID().uuidString)", isDirectory: true)
try? FileManager.default.createDirectory(at: tmpRoot, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: tmpRoot) }

// ---------- 1. 并发同瓦片合并：只下载一次；不同瓦片 ≤2 并发 ----------
do {
    let net = FakeNet()
    let hold = DispatchSemaphore(value: 0) // 挂起首个请求，让其余线程先排队
    net.on("https://tiles.openfreemap.org/planet", planetOK("https://t.example/20261101/{z}/{x}/{y}"))
    net.on("https://t.example/") { req in hold.wait(); return okTile(req) }
    let c = VectorTileClient(maxConcurrent: 2, timeout: 15)
    c.fetch = net.route
    try c.loadTileJSON()
    var results: [Data] = []
    let rlock = NSLock()
    let group = DispatchGroup()
    for _ in 0..<4 {
        group.enter()
        Thread {
            if let d = try? c.fetchTile(z: 14, x: 1, y: 1) {
                rlock.lock(); results.append(d); rlock.unlock()
            }
            group.leave()
        }.start()
    }
    net.waitCalls("14/1/1", 1)
    Thread.sleep(forTimeInterval: 0.15) // 等待者就位
    hold.signal()
    group.wait()
    check(results.count == 4, "合并等待者全部拿到数据")
    check(net.callCount("14/1/1") == 1, "同瓦片并发只下载一次")
    _ = try c.fetchTile(z: 14, x: 1, y: 1)
    check(net.callCount("14/1/1") == 1, "命中缓存不再下载")
    // 并发上限：4 个不同瓦片同时取，峰值 ≤ 2
    net.on("https://t.example/") { req in okTile(req) }
    let g2 = DispatchGroup()
    for i in 2..<6 {
        g2.enter()
        Thread { _ = try? c.fetchTile(z: 14, x: i, y: 1); g2.leave() }.start()
    }
    g2.wait()
    check(net.maxInflight <= 2, "并发不超过 2")
} catch { check(false, "段1异常: \(error)") }

// ---------- 2/3. 取消语义：无等待者取消丢弃；有等待者继续完成 ----------
do {
    let net = FakeNet()
    let clock = Clock()
    var cancelFlag = false
    net.on("https://tiles.openfreemap.org/planet", planetOK("https://t.example/20261101/{z}/{x}/{y}"))
    net.on("https://t.example/") { req in
        if req.url!.absoluteString.contains("14/11/") { cancelFlag = true } // 下载完成时才置取消
        return okTile(req)
    }
    let c = VectorTileClient(maxConcurrent: 1, timeout: 15)
    c.fetch = net.route
    c.now = { clock.now }
    try c.loadTileJSON()
    // 无等待者 + 下载前取消：不发起网络
    do { _ = try c.fetchTile(z: 14, x: 10, y: 10, shouldCancel: { true }); check(false, "取消应抛错") }
    catch { check(net.callCount("14/10/10") == 0, "无等待者取消不发起网络") }
    // 无等待者 + 下载完成后取消：数据丢弃不缓存
    do { _ = try c.fetchTile(z: 14, x: 11, y: 11, shouldCancel: { cancelFlag }); check(false, "完成后取消应抛错") }
    catch {}
    check(net.callCount("14/11/11") == 1, "完成后取消已产生一次网络")
    _ = try? c.fetchTile(z: 14, x: 11, y: 11) // 无取消，成功并缓存
    check(net.callCount("14/11/11") == 2, "丢弃的结果未写缓存（需重新下载）")
    _ = try c.fetchTile(z: 14, x: 11, y: 11)
    check(net.callCount("14/11/11") == 2, "第二次成功后命中缓存")
    // 有等待者：owner 取消也不得丢弃共享下载
    let gate = DispatchSemaphore(value: 0)
    net.on("https://t.example/20261101/14/12/") { req in gate.wait(); return okTile(req) }
    let waiter = DispatchGroup(); waiter.enter()
    Thread { _ = try? c.fetchTile(z: 14, x: 12, y: 12); waiter.leave() }.start()
    net.waitCalls("14/12/12", 1)
    Thread.sleep(forTimeInterval: 0.15) // 等待者挂上
    let owner = DispatchGroup(); owner.enter()
    Thread {
        do { let d = try c.fetchTile(z: 14, x: 12, y: 12, shouldCancel: { true })
             check(d.count == 3, "有等待者时取消不丢弃共享结果") }
        catch { check(false, "有等待者的共享下载应完成") }
        owner.leave()
    }.start()
    Thread.sleep(forTimeInterval: 0.15)
    gate.signal()
    owner.wait(); waiter.wait()
    check(net.callCount("14/12/12") == 1, "有等待者时共享下载只执行一次")
} catch { check(false, "段2/3异常: \(error)") }

// ---------- 4. 429 Retry-After 与冷却清理 ----------
do {
    let net = FakeNet()
    let clock = Clock()
    net.on("https://tiles.openfreemap.org/planet", planetOK("https://t.example/20261101/{z}/{x}/{y}"))
    var served = false
    net.on("https://t.example/20261101/14/20/") { req in
        if !served { served = true; return net.http(req.url!.absoluteString, 429, headers: ["Retry-After": "30"]) }
        return okTile(req)
    }
    net.on("https://t.example/") { req in okTile(req) }
    let c = VectorTileClient(maxConcurrent: 1, timeout: 15)
    c.fetch = net.route
    c.now = { clock.now }
    try c.loadTileJSON()
    var gotRateLimited = false
    do { _ = try c.fetchTile(z: 14, x: 20, y: 20) } catch { gotRateLimited = true }
    check(gotRateLimited, "429 返回 rateLimited 错误")
    var throttled = false
    do { _ = try c.fetchTile(z: 14, x: 20, y: 20) } catch { throttled = true }
    check(throttled, "冷却期内直接节流")
    check(net.callCount("14/20/20") == 1, "冷却期内不重发网络")
    clock.now.addTimeInterval(31) // 越过 Retry-After
    let d = try c.fetchTile(z: 14, x: 20, y: 20)
    check(d.count == 3, "冷却结束后重试成功")
    check(net.callCount("14/20/20") == 2, "冷却结束后恰好重试一次")
    // 成功后冷却清除：相邻瓦片失败产生冷却，不波及已成功瓦片
    served = false
    net.on("https://t.example/20261101/14/21/") { req in net.http(req.url!.absoluteString, 500) }
    _ = try? c.fetchTile(z: 14, x: 20, y: 21)
    clock.now.addTimeInterval(16)
    _ = try c.fetchTile(z: 14, x: 20, y: 20) // 旧冷却已被成功清除，走缓存
    check(net.callCount("14/20/20") == 2, "成功后同瓦片冷却已清除（命中缓存）")
} catch { check(false, "段4异常: \(error)") }

// ---------- 5/6. 数据代次：同 version 换模板必须换代次并整体失效 ----------
do {
    let net = FakeNet()
    net.on("https://tiles.openfreemap.org/planet", planetOK("https://t.example/20261101/{z}/{x}/{y}"))
    net.on("https://t.example/") { req in okTile(req) }
    let c = VectorTileClient(maxConcurrent: 1, timeout: 15)
    c.fetch = net.route
    try c.loadTileJSON()
    let g1 = c.dataGeneration
    check(!g1.isEmpty, "代次非空")
    _ = try c.fetchTile(z: 14, x: 30, y: 30)
    check(net.callCount("14/30/30") == 1, "首代次下载一次")
    _ = try c.fetchTile(z: 14, x: 30, y: 30)
    check(net.callCount("14/30/30") == 1, "首代次缓存命中")
    // 同 version、换模板（日期目录翻新）：代次必须变化，缓存整体失效
    net.on("https://tiles.openfreemap.org/planet", planetOK("https://t.example/20261108/{z}/{x}/{y}"))
    try c.loadTileJSON()
    check(g1 != c.dataGeneration, "同 version 换模板代次变化")
    _ = try c.fetchTile(z: 14, x: 30, y: 30)
    check(net.callCount("20261108/14/30/30") == 1, "新代次重新下载（旧缓存不串代）")
    check(net.callCount("20261101/14/30/30") == 1, "旧代次模板不再使用")
} catch { check(false, "段5/6异常: \(error)") }

// ---------- 7-10. 持久化引导与 24h 重验 ----------
do {
    let net = FakeNet()
    let clock = Clock()
    net.on("https://tiles.openfreemap.org/planet", planetOK("https://t.example/20261101/{z}/{x}/{y}"))
    net.on("https://t.example/") { req in okTile(req) }
    let dir = tmpRoot.appendingPathComponent("boot-a", isDirectory: true)
    let c = VectorTileClient(maxConcurrent: 1, timeout: 15, bootstrapDirectory: dir)
    c.fetch = net.route
    c.now = { clock.now }
    try c.loadTileJSON()
    check(FileManager.default.fileExists(atPath: dir.appendingPathComponent("openfreemap-bootstrap.json").path),
          "TileJSON 成功后持久化引导")
    // 新客户端同目录：离线可用（不联网即有模板）
    let net2 = FakeNet()
    net2.on("https://t.example/") { req in okTile(req) }
    let c2 = VectorTileClient(maxConcurrent: 1, timeout: 15, bootstrapDirectory: dir)
    c2.fetch = net2.route
    c2.now = { clock.now }
    check(!c2.template.isEmpty, "持久化引导离线加载模板")
    check(net2.calls.isEmpty, "引导加载零联网")
    _ = try c2.fetchTile(z: 14, x: 40, y: 40)
    check(net2.callCount("20261101/14/40/40") == 1, "持久化模板参与瓦片 URL")
    // 新鲜验证期内 ensureReady 不重验
    c2.ensureReady()
    check(net2.callCount("planet") == 0, "24h 内不重验")
    // 过期后 ensureReady 联网重验；失败保留旧模板
    clock.now.addTimeInterval(24 * 3600 + 60)
    net2.on("https://tiles.openfreemap.org/planet") { req in net2.http(req.url!.absoluteString, 503) }
    c2.ensureReady() // 刷新失败：不抛错、保留模板
    check(!c2.template.isEmpty, "刷新失败保留最后有效模板")
    check(net2.callCount("planet") == 1, "过期后触发联网重验")
    _ = try? c2.fetchTile(z: 14, x: 41, y: 41)
    check(net2.callCount("20261101/14/41/41") == 1, "刷新失败后仍按旧模板补图")
    // 恢复网络：过期重验成功
    net2.on("https://tiles.openfreemap.org/planet", planetOK("https://t.example/20261101/{z}/{x}/{y}"))
    clock.now.addTimeInterval(24 * 3600 + 60)
    c2.ensureReady()
    check(net2.callCount("planet") == 2, "网络恢复后重验成功")
    // 损坏引导：丢弃走联网
    let dirBad = tmpRoot.appendingPathComponent("boot-bad", isDirectory: true)
    try? FileManager.default.createDirectory(at: dirBad, withIntermediateDirectories: true)
    try? Data("not-json".utf8).write(to: dirBad.appendingPathComponent("openfreemap-bootstrap.json"))
    let net3 = FakeNet()
    net3.on("https://tiles.openfreemap.org/planet", planetOK("https://t.example/20261101/{z}/{x}/{y}"))
    let c3 = VectorTileClient(maxConcurrent: 1, timeout: 15, bootstrapDirectory: dirBad)
    c3.fetch = net3.route
    check(c3.template.isEmpty, "损坏引导被丢弃")
    try c3.loadTileJSON()
    check(!c3.template.isEmpty, "损坏引导后走联网引导")
} catch { check(false, "段7-10异常: \(error)") }

// ---------- 11. 事件出口：瓦片/失败事件字段（匿名散列，无坐标/URL） ----------
do {
    let net = FakeNet()
    net.on("https://tiles.openfreemap.org/planet", planetOK("https://t.example/20261101/{z}/{x}/{y}"))
    net.on("https://t.example/") { req in okTile(req) }
    let c = VectorTileClient(maxConcurrent: 1, timeout: 15)
    c.fetch = net.route
    try c.loadTileJSON()
    var events: [(String, [String: Any])] = []
    let elock = NSLock()
    c.onEvent = { name, fields in
        elock.lock(); events.append((name, fields)); elock.unlock()
    }
    _ = try c.fetchTile(z: 14, x: 50, y: 50)
    _ = try c.fetchTile(z: 14, x: 50, y: 50) // memory 命中
    net.on("https://t.example/20261101/14/51/") { req in net.http(req.url!.absoluteString, 500) }
    _ = try? c.fetchTile(z: 14, x: 51, y: 51)
    elock.lock(); defer { elock.unlock() }
    check(events.contains { $0.0 == "vector-tile" && $0.1["origin"] as? String == "network" }, "网络命中事件存在")
    check(events.contains { $0.0 == "vector-tile" && $0.1["origin"] as? String == "memory" }, "内存命中事件存在")
    check(events.contains { $0.0 == "vector-tile-fail" && $0.1["reason"] as? String == "http" && $0.1["code"] as? Int == 500 },
          "失败事件带原因与状态码")
    if let netHit = events.first(where: { $0.0 == "vector-tile" && $0.1["origin"] as? String == "network" }) {
        check(netHit.1["bytes"] as? Int == 3, "网络命中事件带字节数")
        check(netHit.1["generation"] as? String == c.dataGeneration, "瓦片事件绑定当前代次")
        let tile = netHit.1["tile"] as? String ?? ""
        check(tile.count == 8 && !tile.contains("/"), "瓦片以 8 位匿名散列出现")
    }
    // 事件负载不得含 URL 或坐标串（reason="http" 这类白名单字面量允许）
    var whitelistOk = true
    for (_, f) in events {
        for (k, v) in f {
            if let s = v as? String, s.contains("://") || s.contains("/14/") {
                whitelistOk = false
                print("leak field: \(k)=\(s)")
            }
        }
    }
    check(whitelistOk, "事件字段白名单（无 URL/坐标）")
} catch { check(false, "段11异常: \(error)") }

// ---------- 12. 原始大小上限 ----------
do {
    let net = FakeNet()
    net.on("https://tiles.openfreemap.org/planet", planetOK("https://t.example/20261101/{z}/{x}/{y}"))
    net.on("https://t.example/20261101/14/60/") { req in
        (Data(repeating: 7, count: 4 * 1024 * 1024 + 1),
         HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: [:])!, ["network"])
    }
    let c = VectorTileClient(maxConcurrent: 1, timeout: 15)
    c.fetch = net.route
    try c.loadTileJSON()
    var tooLarge = false
    do { _ = try c.fetchTile(z: 14, x: 60, y: 60) } catch { tooLarge = true }
    check(tooLarge, "原始响应超 4 MiB 拒绝")
} catch { check(false, "段12异常: \(error)") }

// ---------- 13. 原始瓦片磁盘层：重启复用 / disk 来源事件 / 损坏清除 ----------
do {
    let net = FakeNet()
    net.on("https://tiles.openfreemap.org/planet", planetOK("https://t.example/20261101/{z}/{x}/{y}"))
    net.on("https://t.example/") { req in okTile(req) }
    let dir = tmpRoot.appendingPathComponent("tiles-a", isDirectory: true)
    let c = VectorTileClient(maxConcurrent: 1, timeout: 15, tileDiskDirectory: dir)
    c.fetch = net.route
    try c.loadTileJSON()
    _ = try c.fetchTile(z: 14, x: 70, y: 70)          // 网络 → 落盘
    check(net.callCount("14/70/70") == 1, "瓦片首次网络下载")
    _ = try c.fetchTile(z: 14, x: 70, y: 70)          // 内存命中
    check(net.callCount("14/70/70") == 1, "内存命中不再下载")
    // 新客户端（模拟重启）：内存空，磁盘命中（零网络）并回填内存
    var sawDiskOrigin = false
    _ = try c.fetchTile(z: 14, x: 70, y: 70)          // 网络 → 落盘
    check(net.callCount("14/70/70") == 1, "瓦片首次网络下载")
    _ = try c.fetchTile(z: 14, x: 70, y: 70)          // 内存命中
    check(net.callCount("14/70/70") == 1, "内存命中不再下载")
    // 新客户端（模拟重启）：内存空，磁盘命中（零网络）并回填内存
    let net2 = FakeNet()
    net2.on("https://tiles.openfreemap.org/planet", planetOK("https://t.example/20261101/{z}/{x}/{y}"))
    net2.on("https://t.example/") { req in okTile(req) }
    let c2 = VectorTileClient(maxConcurrent: 1, timeout: 15, tileDiskDirectory: dir)
    c2.fetch = net2.route
    try c2.loadTileJSON()
    c2.onEvent = { name, f in
        if name == "vector-tile", f["origin"] as? String == "disk" { sawDiskOrigin = true }
    }
    let d = try c2.fetchTile(z: 14, x: 70, y: 70)
    check(d.count == 3, "重启后磁盘瓦片可用")
    check(net2.callCount("14/70/70") == 0, "重启后瓦片零网络")
    check(sawDiskOrigin, "disk 来源事件存在")
    // 损坏磁盘瓦片：删除后走网络
    let files = (try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil))
    try Data("junk".utf8).write(to: files[0])
    let net3 = FakeNet()
    net3.on("https://tiles.openfreemap.org/planet", planetOK("https://t.example/20261101/{z}/{x}/{y}"))
    net3.on("https://t.example/") { req in okTile(req) }
    let c3 = VectorTileClient(maxConcurrent: 1, timeout: 15, tileDiskDirectory: dir)
    c3.fetch = net3.route
    try c3.loadTileJSON()
    _ = try c3.fetchTile(z: 14, x: 70, y: 70)
    check(net3.callCount("14/70/70") == 1, "损坏磁盘瓦片被拒后重新下载")
} catch { check(false, "段13异常: \(error)") }

// ---------- 14. 磁盘瓦片 LRU 预算修剪 ----------
do {
    let net = FakeNet()
    net.on("https://tiles.openfreemap.org/planet", planetOK("https://t.example/20261101/{z}/{x}/{y}"))
    net.on("https://t.example/") { req in
        (Data(repeating: 3, count: 300_000),
         HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: [:])!, ["network"])
    }
    let dir = tmpRoot.appendingPathComponent("tiles-b", isDirectory: true)
    let c = VectorTileClient(maxConcurrent: 1, timeout: 15, tileDiskDirectory: dir)
    c.fetch = net.route
    try c.loadTileJSON()
    // 注意：300KB 非压缩 → 内存膨胀也 300KB；写盘的是原始响应
    for x in 80..<260 { _ = try c.fetchTile(z: 14, x: x, y: 80) }
    guard let disk = c.tileDisk else { check(false, "磁盘层存在"); throw NSError(domain: "t", code: 1) }
    let s = disk.stats()
    check(s.bytes <= VectorTileDiskStore.budget + 400_000, "磁盘瓦片预算受限（\(s.bytes)）")
    check(s.count < 180, "最旧磁盘瓦片被修剪（\(s.count)）")
} catch { check(false, "段14异常: \(error)") }

print("vector reliability: \(passed) checks passed")
