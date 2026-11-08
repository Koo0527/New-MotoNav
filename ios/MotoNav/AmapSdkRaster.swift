import Foundation

/// Serial leases prevent foreground and route-prefetch jobs changing the same screenshot camera.
enum AmapSdkRaster {
    private static let lease = NSLock()
    static func build(_ f: MapGeo.Frame, cx: Double, cy: Double, includeBuildings: Bool,
                      shouldCancel: @escaping () -> Bool, onBaseReady: ((Data) -> Void)? = nil, onBuildingStatus: ((String) -> Void)? = nil, satellite: Bool = false, style: Int = 1, preparedBase:Data? = nil, buildingView: BuildingView? = nil, onBuildingReady: ((BuildingUpdate) -> Void)? = nil, shouldYield: (() -> Bool)? = nil, cache: RouteMapCache = .shared, fineRoads: Bool = false, fineQuadrant: Int? = nil) throws -> RasterResult {
        precondition(!Thread.isMainThread)
        func check() throws { if shouldCancel() { throw MapProcessingError.cancelled } }
        let job = Int.random(in: 1...Int(Int32.max))
        MapPipelineTrace.event("capture-start", ["job": job, "buildings": includeBuildings])
        func take(x: Int, y: Int, n: Int) throws -> [UInt32] {
            while !lease.try() { try check(); Thread.sleep(forTimeInterval: 0.1) }
            defer { lease.unlock() }
            try check()
            let started = Date()
            MapPipelineTrace.event("tile-start", ["job": job, "size": n])
            let box = CaptureResultBox(), sem = DispatchSemaphore(value: 0)
            DispatchQueue.main.async {
                if shouldCancel() { box.set(.failure(MapProcessingError.cancelled)); sem.signal(); return }
                AmapCaptureHost.shared.capture(f, x: x, y: y, size: n, satellite: satellite, style: style) { result in box.set(result); sem.signal() }
            }
            var elapsed = 0.0
            do {
                while sem.wait(timeout: .now() + 0.15) == .timedOut {
                    try check(); elapsed += 0.15
                    if elapsed > 45 { throw MapProcessingError.invalid("高德截图超时") }
                }
                try check()
                let shot = try box.get().get()
                let sampled = try AmapSampleGrid.sample(shot.pixels, withoutBuildings: shot.withoutBuildings,
                                                       width: shot.width, height: shot.height, left: shot.left,
                                                       top: shot.top, right: shot.right, bottom: shot.bottom,
                                                       north: shot.north, south: shot.south, size: n)
                MapPipelineTrace.event("tile-ready", ["job": job, "size": n, "seconds": Date().timeIntervalSince(started)])
                return sampled
            } catch {
                MapPipelineTrace.event("tile-failed", ["job": job, "size": n, "seconds": Date().timeIntervalSince(started), "error": error.localizedDescription])
                // Enqueue cancellation before releasing the lease; a stale job never cancels the next one.
                DispatchQueue.main.async { AmapCaptureHost.shared.cancel() }
                throw error
            }
        }
        /// 一次 600² 无建筑近景，只取第一张；与建筑路径共用同一截图租约和取消门。
        func takeFine(x: Int, y: Int) throws -> [UInt32] {
            while !lease.try() { try check(); Thread.sleep(forTimeInterval: 0.1) }
            defer { lease.unlock() }
            try check()
            let started = Date()
            MapPipelineTrace.event("fine-tile-start", ["job": job, "size": 600])
            let box = CaptureResultBox(), sem = DispatchSemaphore(value: 0)
            DispatchQueue.main.async {
                if shouldCancel() { box.set(.failure(MapProcessingError.cancelled)); sem.signal(); return }
                AmapCaptureHost.shared.capture(f, x: x, y: y, size: 600, style: style, pairBuildings: false) { result in
                    box.set(result); sem.signal()
                }
            }
            var elapsed = 0.0
            do {
                while sem.wait(timeout: .now() + 0.15) == .timedOut {
                    try check(); elapsed += 0.15
                    if elapsed > 45 { throw MapProcessingError.invalid("高德近景截图超时") }
                }
                try check()
                let shot = try box.get().get()
                let sampled = try AmapSampleGrid.sample(shot.pixels, withoutBuildings: nil,
                                                       width: shot.width, height: shot.height, left: shot.left,
                                                       top: shot.top, right: shot.right, bottom: shot.bottom,
                                                       north: shot.north, south: shot.south, size: 600)
                MapPipelineTrace.event("fine-tile-ready", ["job": job, "seconds": Date().timeIntervalSince(started)])
                return sampled
            } catch {
                MapPipelineTrace.event("fine-tile-failed", ["job": job, "seconds": Date().timeIntervalSince(started), "error": error.localizedDescription])
                DispatchQueue.main.async { AmapCaptureHost.shared.cancel() }
                throw error
            }
        }
        let half = satellite ? 700.0 : 1200.0
        let n = satellite ? 400 : 1200, x = Int((cx - half).rounded()), y = Int((cy + half).rounded())
        let node = RouteMapPlan.Node(x: cx, y: cy, distance: 0)
        let cachedUpdate = includeBuildings && !satellite && AmapCapturePolicy.supportsBuildings(style)
            ? cache.buildingUpdate(frame:f,source:3,node:node,style:style,currentOnly:true) : nil
        try check()
        if let cached = cachedUpdate, cached.coverage.isComplete, RouteMapCache.isCurrent(cached,source:3,style:style) {
            MapPipelineTrace.event("buildings-cache-hit", ["job":job,"checked":cached.coverage.checkedMask,"bytes":cached.bytes.count])
            onBaseReady?(MapDeliveryPolicy.compactBase(cached.bytes))
            onBuildingReady?(cached)
            return RasterResult(bytes:cached.bytes,tiles:0,fromCache:1,coverage:cached.coverage)
        }
        let availableBase = preparedBase ?? cachedUpdate.flatMap {
            $0.coverage.qualityVersion == FastBuildings.qualityVersion ? MapDeliveryPolicy.compactBase($0.bytes) : nil
        }
        var roads: [UInt8]
        var base: Data
        var fineApplied = false
        if !satellite,AmapCapturePolicy.supportsBuildings(style),let cached=availableBase,
           RoadPalette.isCurrentPacket(cached),
           RasterPacket.valid(cached,frame:f.id,x:x,y:y),!RasterPacket.isBuilding(cached),
           MapStyleTransfer.matches(cached,style:style),let decoded=RasterPacket.decode(cached) {
            roads=decoded;base=cached
        } else {
        let raw = try take(x: x, y: y, n: n)
        guard stride(from: 0, to: raw.count, by: 7).contains(where: { raw[$0] != raw[0] }) else { throw MapProcessingError.invalid("高德返回纯色底图") }
        if satellite { return try SatelliteRaster.encode(f,cx: cx,cy: cy,half: half,raw: raw,shouldCancel: shouldCancel) }
        if style == 0 {
            let q = MapStyles.original(raw)
            let packet = MapGeo.encodeRaster(frameId: f.id, x0: x, y0: y, w: n, h: n, mmPerPx: 2000, idx: q.indices, pal: q.palette)
            MapSampleReport.shared.capture(raw:raw,indices:q.indices,palette:q.palette,packet:packet,w:n,h:n,style:style)
            guard packet.count <= 480000, RasterPacket.valid(packet) else { throw MapProcessingError.invalid("高德原版底图过大") }
            onBaseReady?(packet); return RasterResult(bytes: packet, tiles: 1, fromCache: 0)
        }
        if style == 5 {
            let minimal=MapStyles.minimal(raw,size:n)
            let packet = MapGeo.encodeRaster(frameId: f.id, x0: x, y0: y, w: n, h: n, mmPerPx: 2000, idx: minimal)
            MapSampleReport.shared.capture(raw:raw,indices:minimal,packet:packet,w:n,h:n,style:style)
            guard RasterPacket.valid(packet) else { throw MapProcessingError.invalid("黑白道路数据无效") }
            onBaseReady?(packet); return RasterResult(bytes: packet, tiles: 1, fromCache: 0)
        }
        if AmapCapturePolicy.supportsBuildings(style) {
            roads=RoadPalette.classify(raw,w:n,h:n)
            base=RoadPalette.encode(frameId:f.id,x0:x,y0:y,w:n,h:n,indices:roads)
        } else {
            roads=MapGeo.classifyAmapBase(raw,w:n,h:n,style:style)
            base=MapGeo.encodeRaster(frameId:f.id,x0:x,y0:y,w:n,h:n,mmPerPx:2000,idx:roads)
        }
        MapSampleReport.shared.capture(raw:raw,indices:roads,packet:base,w:n,h:n,style:style)
        guard MapGeo.materialPixelCount(roads)>=MapGeo.minMaterialPixels(w:n,h:n) else {
            throw MapProcessingError.invalid("底图尚未准备完整，保留已有地图")
        }
        try check()
        guard RasterPacket.valid(base) else { throw MapProcessingError.invalid("高德普通底图编码不完整") }
        try check()
        }
        MapPipelineTrace.event("base-ready", ["job": job, "bytes": base.count])
        onBaseReady?(base)
        // 局部近景补路在宽底图已上屏后执行：失败/取消/超时都沿用已可用的宽底图。
        var fineUpdate: FineRoads.Update?
        if fineRoads, !satellite, !includeBuildings, (1...3).contains(style), !shouldCancel(),
           let quadrant = fineQuadrant ?? FineRoads.quadrant(view: buildingView, cx: cx, cy: cy) as Int? {
            let digest = FineRoads.baseDigest(base)
            let cached = cache.readFineState(frame: f, source: 3, node: node, style: style, baseDigest: digest)
            var coverage = FineRoads.FineRoadCoverage(
                qualityVersion: cached?.qualityVersion ?? FineRoads.version,
                checkedMask: cached?.checkedMask ?? 0)
            var masks = cached?.masks ?? [:]
            if !coverage.contains(quadrant) {
                do {
                    let sampled = try takeFine(x: x + (quadrant % 2) * 1200,
                                               y: y - (quadrant / 2) * 1200)
                    let near = MapGeo.classifyFineRoads(sampled, w: FineRoads.nearSize, h: FineRoads.nearSize)
                    masks[quadrant] = FineRoads.candidateMask(near: near, colors: sampled)
                    let merged = FineRoads.mergeAll(base: roads, candidates: masks)
                    coverage.mark(quadrant)
                    let revision = (cached?.revision ?? 0) + 1
                    if merged.added > 0,
                       let packet = FineRoads.encode(merged.pixels, like: base, frameId: f.id, x0: x, y0: y) {
                        base = packet
                        fineApplied = true
                        MapPipelineTrace.event("fine-roads-ready", ["job": job, "quadrant": quadrant,
                            "added": merged.added, "rejected": merged.rejected, "bytes": packet.count])
                    } else {
                        MapPipelineTrace.event("fine-roads-empty", ["job": job, "quadrant": quadrant,
                            "added": merged.added, "rejected": merged.rejected])
                    }
                    try? cache.storeFineState(RouteMapCache.FineState(
                        qualityVersion: coverage.qualityVersion, checkedMask: coverage.checkedMask,
                        masks: masks, revision: revision, baseDigest: digest),
                        frame: f, source: 3, node: node, style: style)
                    fineUpdate = FineRoads.Update(coverage: coverage, pixels: merged.pixels,
                        added: merged.added, rejected: merged.rejected, revision: revision)
                } catch {
                    MapPipelineTrace.event("fine-roads-failed", ["job": job, "quadrant": quadrant,
                        "error": error.localizedDescription])
                }
            }
        }
        guard includeBuildings else { return RasterResult(bytes: base, tiles: 1, fromCache: 0,
            fineRoads: fineApplied, fineUpdate: fineUpdate) }
        onBuildingStatus?("正在从高德近景截图提取建筑轮廓…")
        var checkpoint = cache.buildingCheckpoint(frame: f, source: 3, node: node)
        var captures = 0
        var publishedFirst = false
        func current() -> BuildingUpdate {
            BuildingUpdate(bytes: FastBuildings.packet(base: base, patches: checkpoint.patches), coverage: checkpoint.coverage)
        }
        do {
            if checkpoint.patches.values.contains(where: { $0.contains(1) }) {
                let update = current()
                if RasterPacket.isBuilding(update.bytes) {
                    onBuildingReady?(update)
                    publishedFirst = true
                    MapPipelineTrace.event("buildings-cache-hit", ["job":job,"checked":update.coverage.checkedMask,"bytes":update.bytes.count])
                }
            }
            for index in FastBuildings.order(cx: cx, cy: cy, view: buildingView) {
                try check()
                if checkpoint.coverage.checkedMask & (1 << index) != 0 { continue }
                if shouldYield?() == true {
                    MapPipelineTrace.event("buildings-yield", ["job": job, "checked": checkpoint.coverage.checkedMask])
                    let update = current()
                    try cache.storeBuildingUpdate(update,frame:f,source:3,node:node)
                    return RasterResult(bytes: update.bytes, tiles: captures + 1, fromCache: 0, coverage: update.coverage)
                }
                let tile = try take(x: x + (index % 2) * 1200, y: y - (index / 2) * 1200, n: 600)
                captures += 1
                try check()
                let extractionStart = ProcessInfo.processInfo.systemUptime
                let patch = try FastBuildings.simplify(tile)
                MapPipelineTrace.event("building-patch-ready", ["job":job,"index":index,"seconds":ProcessInfo.processInfo.systemUptime-extractionStart])
                try cache.storeBuildingPatch(patch, index: index, frame: f, source: 3, node: node)
                checkpoint = cache.buildingCheckpoint(frame: f, source: 3, node: node)
                if !publishedFirst && !checkpoint.coverage.isComplete && patch.contains(1) {
                    let update = current()
                    if RasterPacket.isBuilding(update.bytes) {
                        try cache.storeBuildingUpdate(update, frame: f, source: 3, node: node)
                        try check()
                        onBuildingReady?(update)
                        publishedFirst = true
                        MapPipelineTrace.event("buildings-first-ready", ["job": job, "bytes": update.bytes.count])
                    }
                }
            }
            try check()
            let update = current()
            try cache.storeBuildingUpdate(update, frame: f, source: 3, node: node)
            try check()
            onBuildingReady?(update)
            MapPipelineTrace.event("buildings-full-ready", ["job": job, "bytes": update.bytes.count])
            return RasterResult(bytes: update.bytes, tiles: captures + 1, fromCache: 0, coverage: update.coverage)
        } catch MapProcessingError.cancelled {
            MapPipelineTrace.event("buildings-cancel", ["job": job])
            throw MapProcessingError.cancelled
        } catch {
            onBuildingStatus?("建筑提取未完成：\(error.localizedDescription)")
            let update = current()
            try? cache.storeBuildingUpdate(update,frame:f,source:3,node:node)
            return RasterResult(bytes: update.bytes, tiles: captures + 1, fromCache: 0, coverage: update.coverage)
        }
    }
}

private final class CaptureResultBox {
    private let lock = NSLock()
    private var result: Result<AmapCaptureHost.Shot, Error>?
    func set(_ value: Result<AmapCaptureHost.Shot, Error>) { lock.lock(); result = value; lock.unlock() }
    func get() -> Result<AmapCaptureHost.Shot, Error> {
        lock.lock(); defer { lock.unlock() }
        return result ?? .failure(MapProcessingError.invalid("高德截图未完成"))
    }
}
