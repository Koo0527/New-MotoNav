import Foundation

/// Match the round display's speed-dependent raster viewport (including its displaced arrow).
enum MapCoveragePolicy {
    /// Existing building packets remain usable; extra screenshot passes yield at highway speeds.
    static func mayCaptureBuildings(kmh:Int)->Bool {kmh<60}
    static func radius(kmh: Int) -> Double {
        let scale = min(0.6, max(0.38, 0.85 - Double(max(0, kmh)) * 0.006))
        return 292 / scale
    }
    static func covers(x: Double, y: Double, cx: Double, cy: Double, kmh: Int, half: Double = 1200, margin: Double = 0) -> Bool {
        max(abs(x - cx), abs(y - cy)) + radius(kmh: kmh) + margin <= half
    }
    static func lookahead(kmh: Int, half: Double = 1200, preferred: Double = 450) -> Double {
        max(0, min(preferred, half - radius(kmh: kmh) - 180))
    }
    /// Time until the current raster ceases to cover the viewport. Follow the
    /// actual route through bends; do not assume the present heading is permanent.
    static func remainingSeconds(x:Double,y:Double,cx:Double,cy:Double,kmh:Int,bearing:Double?,plan:RouteMapPlan?=nil,progress:Double = -1)->Double {
        let speed=max(120,kmh)
        guard covers(x:x,y:y,cx:cx,cy:cy,kmh:speed,margin:50) else {return 0}
        if kmh<6 {return 60}
        let velocity=Double(kmh)/3.6
        let point=plan.map{$0.at(progress)}
        let follow=progress>=0 && point.map{hypot(x-$0.x,y-$0.y)<100} == true
        for tick in 1...120 {
            let seconds=Double(tick)/2,delta=velocity*seconds
            let px:Double,py:Double
            if follow,let plan=plan,let point=point {
                let future=plan.at(progress+delta)
                px=future.x+(x-point.x);py=future.y+(y-point.y)
            } else if let bearing=bearing {
                let radians=bearing * .pi/180
                px=x+sin(radians)*delta;py=y+cos(radians)*delta
            } else {
                // With no trustworthy trajectory, use the closest edge.
                if max(abs(x-cx),abs(y-cy))+delta+radius(kmh:speed)+50>1200 {return max(0,seconds-0.5)}
                continue
            }
            if !covers(x:px,y:py,cx:cx,cy:cy,kmh:speed,margin:50) {return max(0,seconds-0.5)}
        }
        return 60
    }
    static func needsRefresh(x: Double, y: Double, cx: Double, cy: Double, bearing: Double, kmh: Int,
                             preparationSeconds: Double = 12) -> Bool {
        // Leave time for rendering, processing and BLE delivery before the current map expires.
        let distance = Double(max(0, kmh)) / 3.6 * max(1, min(30, preparationSeconds))
        let angle = bearing * .pi / 180
        let viewSpeed = max(120, kmh) // Firmware zoom recovers gradually after slowing down.
        return !covers(x: x, y: y, cx: cx, cy: cy, kmh: viewSpeed, margin: 100) ||
            !covers(x: x + sin(angle) * distance, y: y + cos(angle) * distance,
                    cx: cx, cy: cy, kmh: viewSpeed, margin: 100)
    }
}

/// Samples the actual route every 600 m, with 800 m lookahead and overlapping 2.4 km blocks.
struct RouteMapPlan {
    struct Node: Equatable { let x: Double, y: Double, distance: Double }
    static let step = 600.0, half = 1200.0
    let points: [(x: Double, y: Double)], cumulative: [Double], length: Double
    private(set) var nodes: [Node] = []
    init(_ points: [(x: Double, y: Double)]) throws {
        guard points.count >= 2, points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { throw MapProcessingError.invalid("路线坐标无效") }
        self.points = points
        var cumulative = [Double](repeating: 0, count: points.count)
        for i in 1..<points.count { cumulative[i] = cumulative[i-1] + hypot(points[i].x - points[i-1].x, points[i].y - points[i-1].y) }
        self.cumulative = cumulative; length = cumulative.last!
        guard length.isFinite, length / Self.step <= 20000 else { throw MapProcessingError.invalid("路线过长") }
        var s = 0.0
        while s < length { nodes.append(at(s)); s += Self.step }
        nodes.append(at(length))
    }
    func at(_ distance: Double) -> Node {
        let s = min(length, max(0, distance))
        var lo = 1, hi = cumulative.count - 1
        while lo < hi { let mid = (lo + hi) / 2; if cumulative[mid] < s { lo = mid + 1 } else { hi = mid } }
        let span = cumulative[lo] - cumulative[lo-1], t = span == 0 ? 0 : (s - cumulative[lo-1]) / span
        let x = points[lo-1].x + (points[lo].x - points[lo-1].x) * t, y = points[lo-1].y + (points[lo].y - points[lo-1].y) * t
        return Node(x: (x / 2).rounded(.toNearestOrEven) * 2, y: (y / 2).rounded(.toNearestOrEven) * 2, distance: s)
    }
    func progress(x: Double, y: Double, previous: Double) -> Double {
        var best = Double.infinity, result = previous
        for i in 1..<points.count {
            if previous >= 0 && (cumulative[i] < previous - 150 || cumulative[i-1] > previous + 5000) { continue }
            let a = points[i-1], dx = points[i].x - a.x, dy = points[i].y - a.y, d = dx * dx + dy * dy
            let t = d == 0 ? 0 : min(1, max(0, ((x - a.x) * dx + (y - a.y) * dy) / d))
            let error = hypot(x - a.x - dx * t, y - a.y - dy * t), s = cumulative[i-1] + (cumulative[i] - cumulative[i-1]) * t
            let score = error + (previous < 0 ? s * 1e-9 : abs(s - previous) * 1e-5)
            if score < best { best = score; result = s }
        }
        if best > 400, previous >= 0 { return progress(x: x, y: y, previous: -1) }
        return max(0, result)
    }
    func target(progress: Double, initial: Bool) -> Int {
        max(0, min(nodes.count - 1, Int(floor((progress + (initial ? Self.step / 2 : 800)) / Self.step))))
    }
    /// Capture a future usable block before it can yet cover the current viewport.
    /// Projection follows the route through turns rather than extending the current heading.
    func preparationTarget(progress: Double, kmh: Int) -> Int {
        let predicted = min(length, max(0, progress) + Double(max(0,kmh))/3.6*12)
        let point = at(predicted)
        return displayTarget(progress:predicted,x:point.x,y:point.y,kmh:kmh)
    }
    func displayTarget(progress: Double, x: Double, y: Double, kmh: Int) -> Int {
        let nearest = target(progress: progress, initial: true), next = min(nodes.count - 1, nearest + 1)
        // Switch to the next overlapping block as soon as it contains the full viewport.
        // Download lookahead alone must never choose a block that leaves the screen uncovered.
        if kmh > 5, next != nearest,
           MapCoveragePolicy.covers(x: x, y: y, cx: nodes[next].x, cy: nodes[next].y, kmh: max(120, kmh), margin: 50) {
            return next
        }
        return nearest
    }
}

/// Atomic, size-limited persistent packets. Invalid/truncated/wrong-coordinate packets are ignored.
final class RouteMapCache {
    /// 与 FineRoads.version 同步；新版补路算法必须同时递增两处，旧增强文件不再读取。
    static let fineVersion = 2
    static let fineQuadrantSize = 600
    private let root: URL
    private let lock = NSLock()
    private struct Center:Hashable {let x:Double,y:Double}
    private var known:[String:Set<Center>]=[:]
    struct Hit {let bytes:Data,node:RouteMapPlan.Node,coverage:BuildingCoverage?,isFine:Bool}
    struct CachedPacket {let bytes:Data,isFine:Bool}
    static let shared = RouteMapCache()
    init(root: URL? = nil) {
        self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("route_maps")
    }
    private func file(frame: MapGeo.Frame, source: Int, buildings: Bool, node: RouteMapPlan.Node, style: Int, legacy:Bool=false, materialsVersion:Int?=nil, fine:Int=0) -> URL {
        let suffix = fine > 0 ? "-fine\(fine)" : ""
        if !legacy,AmapCapturePolicy.supportsBuildings(style) {
            let version=materialsVersion ?? (source == 3 ? 4 : 2)
            return root.appendingPathComponent("materials-v\(version)-\(source == 3 && version == 4 ? "game" : String(style))/\(buildings && source == 3 ? "v2" : "v1")-\(source)-\(buildings ? "buildings" : "base")/\(frame.refLat)_\(frame.refLng)/\(Int(node.x))_\(Int(node.y))\(suffix).bin")
        }
        let generation = style == 1 ? 3 : (style == 0 ? 2 : 1)
        return root.appendingPathComponent("styles-v\(generation)-\(style)/\(buildings && source == 3 ? "v2" : "v1")-\(source)-\(buildings ? "buildings" : "base")/\(frame.refLat)_\(frame.refLng)/\(Int(node.x))_\(Int(node.y))\(suffix).bin")
    }
    static func isCurrent(_ bytes:Data,source:Int,style:Int)->Bool {
        source != 3 || !AmapCapturePolicy.supportsBuildings(style) || RoadPalette.isCurrentPacket(bytes)
    }
    static func isCurrent(_ update:BuildingUpdate,source:Int,style:Int)->Bool {
        update.coverage.qualityVersion == FastBuildings.qualityVersion && isCurrent(update.bytes,source:source,style:style)
    }
    private func catalogKey(_ frame:MapGeo.Frame,_ source:Int,_ style:Int)->String {
        "\(frame.id):\(frame.refLat):\(frame.refLng):\(source):\(source == 3 && AmapCapturePolicy.supportsBuildings(style) ? 1 : style)"
    }
    private func remember(_ node:RouteMapPlan.Node,frame:MapGeo.Frame,source:Int,style:Int) {
        known[catalogKey(frame,source,style),default:[]].insert(Center(x:node.x,y:node.y))
    }
    func read(frame: MapGeo.Frame, source: Int, buildings: Bool, node: RouteMapPlan.Node, style: Int = 1, allowLegacy:Bool=true) -> Data? {
        readPacket(frame: frame, source: source, buildings: buildings, node: node, style: style, allowLegacy: allowLegacy)?.bytes
    }
    /// Return bytes together with whether they came from the versioned fine file.
    /// Uses the existing lookup order and file validation; callers no longer need
    /// a second readFine/byte comparison to identify an enhancement packet.
    func readPacket(frame: MapGeo.Frame, source: Int, buildings: Bool, node: RouteMapPlan.Node, style: Int = 1, allowLegacy:Bool=true) -> CachedPacket? {
        lock.lock(); defer { lock.unlock() }
        var urls:[(URL,Bool)] = []
        if !buildings {
            urls.append((file(frame:frame,source:source,buildings:false,node:node,style:style,fine:Self.fineVersion), true))
            // fine1 is a display fallback only; its coverage is unknown and it
            // must not be treated as an input wide base.
            urls.append((file(frame:frame,source:source,buildings:false,node:node,style:style,fine:1), true))
        }
        urls.append((file(frame:frame,source:source,buildings:buildings,node:node,style:style), false))
        if allowLegacy {
            if source == 3 { urls.append((file(frame:frame,source:source,buildings:buildings,node:node,style:style,materialsVersion:3), false)) }
            urls.append((file(frame:frame,source:source,buildings:buildings,node:node,style:style,materialsVersion:2), false))
            urls.append((file(frame:frame,source:source,buildings:buildings,node:node,style:style,legacy:true), false))
        }
        for (url,isFine) in urls {
            if let data = validated(url, frame: frame, source: source, buildings: buildings, node: node, style: style, allowLegacy: allowLegacy) {
                remember(node,frame:frame,source:source,style:style)
                return CachedPacket(bytes: data, isFine: isFine)
            }
        }
        return nil
    }
    /// Explicit wide-base read for AMap capture inputs; never returns the fine file.
    func readWide(frame: MapGeo.Frame, source: Int, node: RouteMapPlan.Node, style: Int = 1) -> Data? {
        lock.lock(); defer { lock.unlock() }
        let url = file(frame: frame, source: source, buildings: false, node: node, style: style)
        guard let data = validated(url, frame: frame, source: source, buildings: false, node: node, style: style, allowLegacy: false) else { return nil }
        remember(node,frame:frame,source:source,style:style)
        return data
    }
    private func validated(_ url: URL, frame: MapGeo.Frame, source: Int, buildings: Bool,
                           node: RouteMapPlan.Node, style: Int, allowLegacy: Bool) -> Data? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? NSNumber, (17...480000).contains(size.intValue),
              let data = try? Data(contentsOf: url), RasterPacket.isBuilding(data) == buildings,
              RasterPacket.valid(data, frame: frame.id, x: Int(node.x - 1200), y: Int(node.y + 1200)),
              MapStyleTransfer.matches(data,style:style),
              allowLegacy || Self.isCurrent(data,source:source,style:style),
              !AmapCapturePolicy.supportsBuildings(style) || RasterPacket.hasMapContent(data) else { return nil }
        return data
    }
    /// One block's versioned fine coverage and candidate masks. The masks are
    /// raw 600×600 byte maps (four quadrants, ~180 KB total); the packet stays
    /// in the existing fine cache file.
    struct FineState {
        let qualityVersion: Int
        let checkedMask: UInt8
        let masks: [Int: [UInt8]]
        let revision: Int
        let baseDigest: String
    }
    private struct SavedFineState: Codable {
        let qualityVersion: Int
        let checkedMask: UInt8
        let revision: Int
        let baseDigest: String
        let maskBytes: Int
        let checksum: UInt64
    }
    private func fineStateURL(frame: MapGeo.Frame, source: Int, node: RouteMapPlan.Node,
                             style: Int, ext: String) -> URL {
        file(frame: frame, source: source, buildings: false, node: node, style: style,
             fine: Self.fineVersion).deletingPathExtension().appendingPathExtension(ext)
    }
    /// Read coverage even when a quadrant contains no roads and therefore has
    /// no fine packet. A base digest mismatch (different wide capture) is stale.
    func readFineState(frame: MapGeo.Frame, source: Int, node: RouteMapPlan.Node,
                       style: Int = 1, baseDigest: String? = nil) -> FineState? {
        lock.lock(); defer { lock.unlock() }
        let metaURL = fineStateURL(frame: frame, source: source, node: node, style: style, ext: "state")
        let masksURL = fineStateURL(frame: frame, source: source, node: node, style: style, ext: "masks")
        guard let metaData = try? Data(contentsOf: metaURL),
              let meta = try? JSONDecoder().decode(SavedFineState.self, from: metaData),
              meta.qualityVersion == Self.fineVersion, meta.checkedMask <= 15,
              meta.maskBytes == ((Self.fineQuadrantSize * Self.fineQuadrantSize + 7) / 8) * 4,
              let masksData = try? Data(contentsOf: masksURL),
              masksData.count == meta.maskBytes,
              Self.checksum(masksData) == meta.checksum,
              baseDigest == nil || meta.baseDigest == baseDigest else { return nil }
        let quadrantBits = Self.fineQuadrantSize * Self.fineQuadrantSize
        let bytesPerQuadrant = (quadrantBits + 7) / 8
        let packed = [UInt8](masksData)
        var masks: [Int: [UInt8]] = [:]
        for q in 0..<4 {
            var mask = [UInt8](repeating: 0, count: quadrantBits)
            let base = q * bytesPerQuadrant
            for i in 0..<quadrantBits where packed[base + i / 8] & (1 << UInt8(i % 8)) != 0 {
                mask[i] = 1
            }
            masks[q] = mask
        }
        return FineState(qualityVersion: meta.qualityVersion, checkedMask: meta.checkedMask,
                         masks: masks, revision: meta.revision, baseDigest: meta.baseDigest)
    }
    func storeFineState(_ state: FineState, frame: MapGeo.Frame, source: Int,
                        node: RouteMapPlan.Node, style: Int = 1) throws {
        guard state.qualityVersion == Self.fineVersion, state.checkedMask <= 15,
              !state.baseDigest.isEmpty,
              state.masks.keys.allSatisfy({ (0..<4).contains($0) }),
              state.masks.values.allSatisfy({ $0.count == Self.fineQuadrantSize * Self.fineQuadrantSize }) else {
            throw MapProcessingError.invalid("细路覆盖状态无效")
        }
        lock.lock(); defer { lock.unlock() }
        let metaURL = fineStateURL(frame: frame, source: source, node: node, style: style, ext: "state")
        let masksURL = fineStateURL(frame: frame, source: source, node: node, style: style, ext: "masks")
        if let oldData = try? Data(contentsOf: metaURL),
           let old = try? JSONDecoder().decode(SavedFineState.self, from: oldData),
           old.qualityVersion == state.qualityVersion, old.baseDigest == state.baseDigest,
           old.checkedMask | state.checkedMask != state.checkedMask {
            throw MapProcessingError.invalid("细路覆盖回退被拒绝")
        }
        let quadrantBits = Self.fineQuadrantSize * Self.fineQuadrantSize
        let bytesPerQuadrant = (quadrantBits + 7) / 8
        var packed = [UInt8](repeating: 0, count: bytesPerQuadrant * 4)
        for q in 0..<4 {
            let mask = state.masks[q] ?? [UInt8](repeating: 0, count: quadrantBits)
            let base = q * bytesPerQuadrant
            for i in 0..<quadrantBits where mask[i] != 0 {
                packed[base + i / 8] |= 1 << UInt8(i % 8)
            }
        }
        let masksData = Data(packed)
        let meta = SavedFineState(qualityVersion: state.qualityVersion,
                                  checkedMask: state.checkedMask, revision: state.revision,
                                  baseDigest: state.baseDigest, maskBytes: masksData.count,
                                  checksum: Self.checksum(masksData))
        let metaData = try JSONEncoder().encode(meta)
        let oldBytes = (try? metaURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            + ((try? masksURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        if totalBytesLocked() - Int64(oldBytes) + Int64(metaData.count + masksData.count) > 512 * 1024 * 1024 {
            throw MapProcessingError.invalid("沿线离线缓存已达 512 MB")
        }
        try FileManager.default.createDirectory(at: metaURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try masksData.write(to: masksURL, options: .atomic)
        try metaData.write(to: metaURL, options: .atomic)
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: metaURL.path)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: masksURL.path)
        #endif
    }
    /// Read only the versioned fine-road packet; used to reuse an existing
    /// enhancement without spending a near capture.
    func readFine(frame: MapGeo.Frame, source: Int, node: RouteMapPlan.Node, style: Int = 1) -> Data? {
        lock.lock(); defer { lock.unlock() }
        let url = file(frame: frame, source: source, buildings: false, node: node, style: style, fine: Self.fineVersion)
        guard let data = validated(url, frame: frame, source: source, buildings: false, node: node, style: style, allowLegacy: false) else { return nil }
        remember(node, frame: frame, source: source, style: style)
        return data
    }
    /// Only inspect the in-memory catalog, never enumerate disk on GPS updates.
    func covering(frame:MapGeo.Frame,source:Int,style:Int,x:Double,y:Double,kmh:Int)->Hit? {
        lock.lock()
        let candidates=(known[catalogKey(frame,source,style)] ?? []).filter {
            MapCoveragePolicy.covers(x:x,y:y,cx:Double($0.x),cy:Double($0.y),kmh:max(120,kmh),margin:50)
        }.sorted {hypot(Double($0.x)-x,Double($0.y)-y)<hypot(Double($1.x)-x,Double($1.y)-y)}
        lock.unlock()
        for center in candidates.prefix(8) {
            let node=RouteMapPlan.Node(x:Double(center.x),y:Double(center.y),distance:0)
            let palette=source==3 && AmapCapturePolicy.supportsBuildings(style)
            let currentPacket=palette ? readPacket(frame:frame,source:source,buildings:false,node:node,style:style,allowLegacy:false):nil
            let currentUpdate=palette ? buildingUpdate(frame:frame,source:source,node:node,style:style,currentOnly:true):nil
            let update=currentUpdate ?? (currentPacket == nil ? buildingUpdate(frame:frame,source:source,node:node,style:style):nil)
            let fallback=update == nil && currentPacket == nil
                ? readPacket(frame:frame,source:source,buildings:false,node:node,style:style) : nil
            if let bytes=update?.bytes ?? currentPacket?.bytes ?? fallback?.bytes {
                let packet=currentPacket ?? fallback
                return Hit(bytes:bytes,node:node,coverage:update?.coverage,isFine:update == nil && packet?.isFine == true)
            }
        }
        return nil
    }
    func store(_ data: Data, frame: MapGeo.Frame, source: Int, node: RouteMapPlan.Node, style: Int = 1, fine: Int = 0) throws {
        guard Self.isCurrent(data,source:source,style:style),RasterPacket.valid(data, frame: frame.id, x: Int(node.x - 1200), y: Int(node.y + 1200)),
              MapStyleTransfer.matches(data,style:style),
              !AmapCapturePolicy.supportsBuildings(style) || RasterPacket.hasMapContent(data) else { throw MapProcessingError.invalid("离线底图校验失败") }
        guard !AmapCapturePolicy.supportsBuildings(style) || RasterPacket.hasMapContent(data) else {throw MapProcessingError.invalid("空白底图未写入缓存")}
        lock.lock(); defer { lock.unlock() }
        let file = file(frame: frame, source: source, buildings: RasterPacket.isBuilding(data), node: node, style: style, fine: fine)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        var folder = root
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try folder.setResourceValues(values)
        if let capacity = (try? root.resourceValues(forKeys: [.volumeAvailableCapacityKey]))?.volumeAvailableCapacity,
           capacity < 32 * 1024 * 1024 { throw MapProcessingError.invalid("手机存储空间不足") }
        let existingSize = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        if totalBytesLocked() - Int64(existingSize) + Int64(data.count) > 512 * 1024 * 1024 { throw MapProcessingError.invalid("沿线离线缓存已达 512 MB") }
        try data.write(to: file, options: .atomic)
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: file.path)
        #endif
        remember(node,frame:frame,source:source,style:style)
    }
    private func fastFile(frame: MapGeo.Frame, source: Int, node: RouteMapPlan.Node, name: String, quality:Int=FastBuildings.qualityVersion) -> URL {
        root.appendingPathComponent("fast4m-v\(quality)-\(source)/\(frame.refLat)_\(frame.refLng)/\(Int((node.x-1200).rounded()))_\(Int((node.y+1200).rounded()))/\(name)")
    }
    private func validFastNode(_ node:RouteMapPlan.Node)->Bool {
        node.x.isFinite && node.y.isFinite && abs(node.x)<Double(Int32.max)-1200 && abs(node.y)<Double(Int32.max)-1200
    }
    private func writeFast(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var folder=root,values=URLResourceValues();values.isExcludedFromBackup=true
        try folder.setResourceValues(values)
        if let capacity=(try? root.resourceValues(forKeys:[.volumeAvailableCapacityKey]))?.volumeAvailableCapacity,capacity<32*1024*1024 {throw MapProcessingError.invalid("手机存储空间不足")}
        let old = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        guard totalBytesLocked() - Int64(old) + Int64(data.count) <= 512*1024*1024 else {throw MapProcessingError.invalid("沿线离线缓存已达 512 MB")}
        try data.write(to: url, options: .atomic)
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey:FileProtectionType.completeUntilFirstUserAuthentication],ofItemAtPath:url.path)
        #endif
    }
    private func readFast(_ url:URL,limit:Int)->Data? {
        guard let size=(try? url.resourceValues(forKeys:[.fileSizeKey]))?.fileSize,size>0,size<=limit else {return nil}
        return try? Data(contentsOf:url)
    }
    func buildingCheckpoint(frame: MapGeo.Frame, source: Int, node: RouteMapPlan.Node) -> BuildingCheckpoint {
        lock.lock(); defer {lock.unlock()}
        var patches=[Int:Data](), mask:UInt8=0
        guard validFastNode(node) else {return BuildingCheckpoint(coverage:BuildingCoverage(),patches:[:])}
        func validPatch(_ d:Data?) -> Data? {
            guard let d=d,d.count==90008 else {return nil}
            let patch=Data(d.prefix(90000))
            var digest=Self.checksum(patch).littleEndian
            let suffix=withUnsafeBytes(of:&digest){Data($0)}
            return patch.allSatisfy({$0<=1}) && d.suffix(8)==suffix ? patch:nil
        }
        for i in 0..<4 {
            let path=fastFile(frame:frame,source:source,node:node,name:"patch-\(i)")
            var patch=validPatch(readFast(path,limit:90008))
            if patch == nil {patch=validPatch(readFast(fastFile(frame:frame,source:source,node:node,name:"patch-\(i)",quality:3),limit:90008))}
            if patch == nil {patch=validPatch(readFast(fastFile(frame:frame,source:source,node:node,name:"patch-\(i)",quality:2),limit:90008))}
            if patch == nil, let old=validPatch(readFast(fastFile(frame:frame,source:source,node:node,name:"patch-\(i)",quality:1),limit:90008)) {
                let converted=FastBuildings.clean(old)
                var stored=converted,digest=Self.checksum(converted).littleEndian
                withUnsafeBytes(of:&digest){stored.append(contentsOf:$0)}
                do {try writeFast(stored,to:path);patch=converted} catch {continue}
            }
            if let patch=patch {patches[i]=patch;mask |= UInt8(1<<i)}
        }
        return BuildingCheckpoint(coverage:BuildingCoverage(checkedMask:mask),patches:patches)
    }
    func storeBuildingPatch(_ patch: Data, index: Int, frame: MapGeo.Frame, source: Int, node: RouteMapPlan.Node) throws {
        guard (0..<4).contains(index),patch.count==90000,patch.allSatisfy({$0<=1}),validFastNode(node) else {throw MapProcessingError.invalid("建筑掩码无效")}
        lock.lock();defer {lock.unlock()}
        var stored=patch,digest=Self.checksum(patch).littleEndian
        withUnsafeBytes(of:&digest) {stored.append(contentsOf:$0)}
        try writeFast(stored,to:fastFile(frame:frame,source:source,node:node,name:"patch-\(index)"))
    }
    private static func checksum(_ data:Data)->UInt64 {
        data.reduce(UInt64(14695981039346656037)) { ($0 ^ UInt64($1)) &* 1099511628211 }
    }
    private static func updateChecksum(_ bytes:Data,_ coverage:BuildingCoverage)->UInt64 {
        var data=bytes
        data.append(contentsOf:"/\(coverage.qualityVersion)/\(coverage.checkedMask)".utf8)
        return checksum(data)
    }
    private struct SavedBuilding: Codable {let bytes:Data;let coverage:BuildingCoverage;let checksum:UInt64}
    func buildingUpdate(frame: MapGeo.Frame, source: Int, node: RouteMapPlan.Node, style: Int, currentOnly:Bool=false) -> BuildingUpdate? {
        guard AmapCapturePolicy.supportsBuildings(style),validFastNode(node) else {return nil}
        func load(_ quality:Int)->BuildingUpdate? {
            lock.lock()
            let data=readFast(fastFile(frame:frame,source:source,node:node,name:"update.json",quality:quality),limit:650000)
            lock.unlock()
            guard let data=data,let saved=try? JSONDecoder().decode(SavedBuilding.self,from:data),
                saved.checksum==Self.updateChecksum(saved.bytes,saved.coverage),saved.coverage.qualityVersion==quality,saved.coverage.checkedMask<=15,
                RasterPacket.valid(saved.bytes,frame:frame.id,x:Int((node.x-1200).rounded()),y:Int((node.y+1200).rounded())),MapStyleTransfer.matches(saved.bytes,style:style),
                quality != FastBuildings.qualityVersion || Self.isCurrent(saved.bytes,source:source,style:style) else {return nil}
            return BuildingUpdate(bytes:saved.bytes,coverage:saved.coverage)
        }
        let current=load(FastBuildings.qualityVersion)
        if currentOnly {return current}
        let previous=load(3),old=load(2),older=load(1)
        let legacy=read(frame:frame,source:source,buildings:true,node:node,style:style).map{BuildingUpdate(bytes:$0,coverage:.legacyFull)}
        let selected = current ?? [previous,old,older,legacy].compactMap {$0}.first {$0.coverage.isComplete} ?? previous ?? old ?? older ?? legacy
        if selected != nil {
            lock.lock();for theme in [1,2,3] {remember(node,frame:frame,source:source,style:theme)};lock.unlock()
        }
        return selected
    }
    func storeBuildingUpdate(_ update: BuildingUpdate, frame: MapGeo.Frame, source: Int, node: RouteMapPlan.Node) throws {
        guard validFastNode(node),Self.isCurrent(update.bytes,source:source,style:1),update.coverage.qualityVersion==FastBuildings.qualityVersion,update.coverage.checkedMask<=15,
              RasterPacket.valid(update.bytes,frame:frame.id,x:Int((node.x-1200).rounded()),y:Int((node.y+1200).rounded())),MapStyleTransfer.matches(update.bytes,style:1) else {throw MapProcessingError.invalid("建筑更新无效")}
        let data=try JSONEncoder().encode(SavedBuilding(bytes:update.bytes,coverage:update.coverage,checksum:Self.updateChecksum(update.bytes,update.coverage)))
        lock.lock();defer {lock.unlock()}
        let url=fastFile(frame:frame,source:source,node:node,name:"update.json")
        if let data=readFast(url,limit:650000),let previous=try? JSONDecoder().decode(SavedBuilding.self,from:data),
           previous.checksum==Self.updateChecksum(previous.bytes,previous.coverage),previous.coverage.checkedMask<=15,
           previous.coverage.qualityVersion==update.coverage.qualityVersion,Self.isCurrent(previous.bytes,source:source,style:1),
           RasterPacket.valid(previous.bytes,frame:frame.id,x:Int((node.x-1200).rounded()),y:Int((node.y+1200).rounded())),
           update.coverage.checkedMask | previous.coverage.checkedMask != update.coverage.checkedMask {return}
        try writeFast(data,to:url)
        for theme in [1,2,3] {remember(node,frame:frame,source:source,style:theme)}
    }
    private func totalBytesLocked() -> Int64 {
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey])
        var bytes: Int64 = 0
        while let url = files?.nextObject() as? URL {
            if let v = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]), v.isRegularFile == true { bytes += Int64(v.fileSize ?? 0) }
        }
        return bytes
    }
    func sizeText() -> String {
        lock.lock(); defer { lock.unlock() }
        return "离线缓存 \(totalBytesLocked() / 1024 / 1024) MB / 512 MB"
    }
}


/// Separates capture readiness from display readiness and ATT transfer readiness.
struct MapHandoffBuffer {
    struct Packet {
        let bytes:Data, cx:Double, cy:Double, sat:Bool, type:Int, info:String, source:Int, style:Int
        let roadBytes:Int
        let coverage:BuildingCoverage?
        init(bytes:Data,cx:Double,cy:Double,sat:Bool,type:Int,info:String,source:Int,style:Int,coverage:BuildingCoverage?=nil) {
            self.bytes=bytes;self.cx=cx;self.cy=cy;self.sat=sat;self.type=type;self.info=info;self.source=source;self.style=style;self.coverage=coverage
            roadBytes=MapDeliveryPolicy.compactBase(bytes).count
        }
    }
    private(set) var pending:Packet?
    static func mayPrepare(x:Double,y:Double,cx:Double,cy:Double)->Bool {
        max(abs(x-cx),abs(y-cy)) < 1150
    }
    /// A late packet behind the vehicle must not block the current route's next capture.
    /// Retain early future packets on the actual route, including bends/hairpins.
    mutating func discardObsolete(x:Double,y:Double,kmh:Int,allowed:[(x:Double,y:Double)])->Bool {
        guard let p=pending,!allowed.isEmpty else {return false}
        let usable=MapCoveragePolicy.covers(x:x,y:y,cx:p.cx,cy:p.cy,kmh:max(120,kmh),margin:50)
        let planned=allowed.contains{abs($0.x-p.cx)<1 && abs($0.y-p.cy)<1}
        if !usable && !planned {pending=nil;return true}
        return false
    }
    mutating func clear() { pending=nil }
    mutating func stage(_ packet:Packet) {
        if let old=pending,old.source==packet.source,old.style==packet.style,old.type==packet.type,
           abs(old.cx-packet.cx)<1,abs(old.cy-packet.cy)<1 {
            let oldCurrent=RouteMapCache.isCurrent(old.bytes,source:old.source,style:old.style)
            let newCurrent=RouteMapCache.isCurrent(packet.bytes,source:packet.source,style:packet.style)
            if oldCurrent && !newCurrent {return}
            if !oldCurrent && newCurrent {pending=packet;return}
        }
        if let old=pending,old.source==packet.source,old.style==packet.style,old.type==packet.type,
           abs(old.cx-packet.cx)<1,abs(old.cy-packet.cy)<1,let previous=old.coverage {
            guard let incoming=packet.coverage else {return}
            if previous.qualityVersion > incoming.qualityVersion {return}
            if previous.qualityVersion==incoming.qualityVersion,
               incoming.checkedMask | previous.checkedMask != incoming.checkedMask {return}
        }
        pending=packet
    }
    func contains(cx:Double,cy:Double,style:Int)->Bool {
        guard let p=pending else {return false}
        return p.style==style && abs(p.cx-cx)<1 && abs(p.cy-cy)<1
    }
    mutating func take(x:Double,y:Double,kmh:Int,style:Int,transferPending:Bool)->Packet? {
        guard let p=pending else {return nil}
        guard p.style==style, Self.mayPrepare(x:x,y:y,cx:p.cx,cy:p.cy) else {pending=nil;return nil}
        guard !transferPending, p.sat || MapCoveragePolicy.covers(x:x,y:y,cx:p.cx,cy:p.cy,kmh:max(120,kmh),margin:50) else {return nil}
        pending=nil;return p
    }
}


/// Roads in the near window precede roofs; nearby roofs precede distant road downloads.
/// A long route must not postpone every building until its last base packet is ready.
enum RouteMapPreparationPolicy {
    struct Job {let index:Int, buildings:Bool}
    static func next(base:[Bool],complete:[Bool],display:Int,target:Int,buildings:Bool,kmh:Int,available:[Bool],partialReady:[Bool]?=nil)->Job? {
        guard !base.isEmpty,base.count==complete.count,base.count==available.count else {return nil}
        let d=max(0,min(base.count-1,display)),t=max(d,min(base.count-1,target))
        let near=Array(d...min(base.count-1,t+2))
        if let i=near.first(where:{!base[$0] && available[$0]}) {return Job(index:i,buildings:false)}
        let roadsReady=near.allSatisfy{base[$0]}
        if buildings && roadsReady {
            if let partialReady=partialReady,partialReady.count==base.count,!partialReady[d],!complete[d],available[d] {return Job(index:d,buildings:true)}
            let first=kmh>5 ? t : d
            let order=[first]+near.filter{$0 != first}
            if let i=order.first(where:{!complete[$0] && available[$0]}) {return Job(index:i,buildings:true)}
        }
        let order=Array(t..<base.count)+Array(0..<t)
        if let i=order.first(where:{!base[$0] && available[$0]}) {return Job(index:i,buildings:false)}
        if buildings && roadsReady,let i=order.first(where:{!complete[$0] && available[$0]}) {return Job(index:i,buildings:true)}
        return nil
    }
}
