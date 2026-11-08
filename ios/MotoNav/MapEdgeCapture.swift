#if DEBUG
import Foundation
import CryptoKit

struct MapEdgeLifecycle {
    private(set) var lastStatus = ""
    private(set) var finished = false
    mutating func update(_ text: String) -> Bool {
        guard !finished else { return false }
        lastStatus = text
        finished = text.hasPrefix("complete:") || text.hasPrefix("partial:") || text.hasPrefix("failed:") || text.hasPrefix("cancelled-")
        return true
    }
}

/// Getter true records the SDK request flag, not proof that rendered pixels changed.
struct MapEdgeStyleState {
    var initialized = false
    private(set) var configuredFrame: Int?
    mutating func configure(frame: Int) -> Bool {
        guard initialized, configuredFrame != frame else { return false }
        configuredFrame = frame
        return true
    }
    func ready(frame: Int, enabled: Bool) -> Bool {
        initialized && configuredFrame == frame && enabled
    }
}

/// Only allow known static failure text into portable evidence; SDK messages may contain credentials/paths.
struct MapEdgeDiagnostics {
    var tiles = ["base": "pending", "building-0": "pending", "building-1": "pending",
                 "building-2": "pending", "building-3": "pending"]
    var buildingStatus: [String] = []
    var failures: [String] = []
    var checkedMask: UInt8?
    var rasterCaptureCount: Int?
    var baseExported = false
    var outputExported = false
    var exportFailed = false
    var captureCount: Int { tiles.values.filter { $0 == "exported" }.count }
    var complete: Bool {
        captureCount == 5 && checkedMask == 15 && baseExported && outputExported && !exportFailed && failures.isEmpty
    }
    func summary(_ scene: String) -> String {
        "\(scene) captures=\(captureCount)/5 checkedMask=\(checkedMask.map(String.init) ?? "unknown") base=\(baseExported) output=\(outputExported) exportFailed=\(exportFailed) failures=[\(failures.joined(separator: "; "))]"
    }
    func write(to folder: URL) throws {
        let mask: Any = checkedMask.map { Int($0) } ?? (NSNull() as Any)
        let json: [String: Any] = ["tiles": tiles, "buildingStatus": buildingStatus, "failures": failures,
            "coverage": ["checkedMask": mask], "captureCount": captureCount, "expectedCaptureCount": 5,
            "rasterCaptureCount": rasterCaptureCount.map { $0 as Any } ?? NSNull(),
            "baseExported": baseExported, "outputExported": outputExported,
            "exportFailed": exportFailed, "complete": complete]
        try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
            .write(to: folder.appendingPathComponent("diagnostics.json"), options: .atomic)
    }
    static func safeReason(_ text: String) -> String {
        let known: Set<String> = ["诊断样式等待地图初始化或启用超时", "高德截图超时", "高德取图超时，保留已有地图", "高德截图未完成",
            "高德截图尺寸或方向异常", "建筑取图缩放级别不足", "高德截图投影未对齐或精度不足",
            "高德截图像素解码失败", "建筑两次截图尺寸或相机发生变化", "截图没有完整覆盖地图范围",
            "截图采样越界", "截图仍有透明区域", "楼块截图尺寸发生变化", "楼块截图含透明区域",
            "楼块图尺寸不一致", "建筑图层覆盖异常", "建筑连通区域异常", "高德截图正在处理上一块",
            "高德返回纯色底图", "底图尚未准备完整，保留已有地图", "高德普通底图编码不完整",
            "高德截图需保持 App 在前台；后台使用已离线的地图", "地图任务已取消", "请先填写高德 iOS Key"]
        if known.contains(text) { return text }
        if text.hasPrefix("高德地图加载失败："), let code = text.split(separator: " ").last.flatMap({ Int32($0) }) {
            return "SDK map load failure code=\(code)"
        }
        let digest = SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
        return "redacted error sha256=\(digest)"
    }
    static func safeError(_ error: Error) -> String {
        let ns = error as NSError
        let domain = [NSCocoaErrorDomain, NSPOSIXErrorDomain, NSURLErrorDomain].contains(ns.domain) ? ns.domain : "redacted"
        return safeReason(error.localizedDescription) + "; domain=\(domain) code=\(ns.code)"
    }
    mutating func noteBuildingStatus(_ text: String) {
        let prefix = "建筑提取未完成："
        if text.hasPrefix(prefix) {
            let reason = Self.safeReason(String(text.dropFirst(prefix.count)))
            buildingStatus.append("incomplete: " + reason); failures.append(reason)
        } else if text == "正在从高德近景截图提取建筑轮廓…" {
            buildingStatus.append("building extraction started")
        } else { buildingStatus.append(Self.safeReason(text)) }
    }
}

enum MapEdgeSamples {
    typealias Sample = (folder: String, query: String, city: String, category: String, names: Set<String>)
    static let all: [Sample] = [
        ("01-dense", "人民广场", "上海", "dense buildings", ["人民广场", "上海人民广场"]),
        ("02-low-density", "嘉定孔庙", "上海", "low density buildings", ["嘉定孔庙", "上海嘉定孔庙"]),
        ("03-diagonal", "武康大楼", "上海", "diagonal streets", ["武康大楼", "诺曼底公寓"]),
        ("04-interchange", "延安东路立交", "上海", "elevated interchange", ["延安东路立交", "延安东路立交桥"]),
        ("05-waterfront", "外滩", "上海", "waterfront", ["外滩", "上海外滩"])
    ]
    static func selected(arguments: [String]) -> [Sample] {
        if arguments.contains("--edge-capture-check") && arguments.contains("--edge-capture-mingbo") {
            return [("06-mingbo", "明波立交桥", "昆明", "elevated interchange", ["明波立交桥", "明波立交"])]
        }
        return all
    }
    static func matches(name: String?, at index: Int, in samples: [Sample] = all) -> Bool {
        guard let name = name else { return false }
        return samples[index].names.contains(name)
    }
    static func contains(latitude: Double, longitude: Double, city: String) -> Bool {
        guard latitude.isFinite, longitude.isFinite else { return false }
        switch city {
        case "上海": return (30...32).contains(latitude) && (120...123).contains(longitude)
        case "昆明": return (24...26).contains(latitude) && (101...104).contains(longitude)
        default: return false
        }
    }
    static func completion(count: Int, partial: [String]) -> String {
        partial.isEmpty ? "complete: \(count) scenes" : "partial: \(count) scenes; " + partial.joined(separator: " | ")
    }
}

enum MapEdgeStyle {
    static let verifiedAssetSHA = "69b20d2eee6e2503e294aab4cf46108819ef1b95690f3258daa97c1e35a72d4f"
    static func load(requested: Bool, from url: URL) throws -> Data? {
        guard requested else { return nil }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let length = attributes[.size] as? NSNumber, (1...2*1024*1024).contains(length.intValue) else {
            throw MapProcessingError.invalid("诊断样式必须为非空且不超过2MiB")
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: 2*1024*1024+1) ?? Data()
        guard (1...2*1024*1024).contains(data.count) else { throw MapProcessingError.invalid("诊断样式大小无效") }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard digest == verifiedAssetSHA else { throw MapProcessingError.invalid("诊断样式不是已验证官方样本") }
        return data
    }
}

/// Projection is exported as source-pixel indices so offline analysis needs no absolute coordinates.
enum MapEdgeArchive {
    struct Projection: Codable {
        let width: Int, height: Int, size: Int
        let left: Double, top: Double, right: Double, bottom: Double
        let columns: [Int], rows: [Int]
    }
    @discardableResult
    static func write(_ pixels: [UInt32], width: Int, height: Int, left: Double, top: Double,
                      right: Double, bottom: Double, north: Double, south: Double, size: Int,
                      to folder: URL, name: String) throws -> Projection {
        // Reuse production validation before writing any artifact.
        _ = try AmapSampleGrid.resample(pixels, width: width, height: height, left: left, top: top,
                                       right: right, bottom: bottom, north: north, south: south, size: size)
        func mercator(_ lat: Double) -> Double { log(tan(.pi / 4 + lat * .pi / 360)) }
        let mn = mercator(north), ms = mercator(south)
        let columns = (0..<size).map { Int(floor(left + (Double($0) + 0.5) / Double(size) * (right - left))) }
        let rows = (0..<size).map { i -> Int in
            let u = (Double(i) + 0.5) / Double(size)
            return Int(floor(top + (mn - mercator(north + (south - north) * u)) / (mn - ms) * (bottom - top)))
        }
        let info = Projection(width: width, height: height, size: size, left: left, top: top,
                              right: right, bottom: bottom, columns: columns, rows: rows)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(info).write(to: folder.appendingPathComponent(name + ".json"), options: .atomic)
        return info
    }
    static func writePixels(_ pixels: [UInt32], to url: URL) throws {
        let littleEndian = pixels.map { $0.littleEndian }
        try littleEndian.withUnsafeBytes { try Data($0).write(to: url, options: .atomic) }
    }
}

#if canImport(UIKit)
import UIKit
import ObjectiveC

/// Explicit foreground developer diagnostic. Own POI delegate, cache and output; no navigation/settings writes.
final class MapEdgeCapture: NSObject {
    static let shared = MapEdgeCapture()
    static var styleRequested: Bool { requested && ProcessInfo.processInfo.arguments.contains("--edge-capture-style") }
    static var requested: Bool { ProcessInfo.processInfo.arguments.contains("--edge-capture-check") }
    private let scenes = MapEdgeSamples.selected(arguments: ProcessInfo.processInfo.arguments)
    private var lifecycle = MapEdgeLifecycle()
    private var styleData: Data?
    private var previousIdleTimerDisabled: Bool?
    private var started = false
    private var index = 0
    private var api: AMapSearchAPI?
    private var request: AMapPOIKeywordsSearchRequest?
    private var folder: URL?
    private var frameID: Int?
    private var diagnostics = MapEdgeDiagnostics()
    private var partialScenes: [String] = []
    private var timer: Timer?
    private var observer: NSObjectProtocol?
    private var cancelled = false
    private let lock = NSLock()
    private func shouldCancel() -> Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    private func cancel() { lock.lock(); cancelled = true; lock.unlock() }

    func startIfRequested() {
        guard Self.requested, !started else { return }
        started = true
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("edge-capture-check/\(UUID().uuidString)")
        folder = root
        do { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
        catch { return }
        do {
            styleData = try MapEdgeStyle.load(requested: Self.styleRequested,
                from: root.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("edge-capture-style.data"))
        } catch { status("failed: missing, unreadable or invalid explicit custom style"); return }
        previousIdleTimerDisabled = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        observer = NotificationCenter.default.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self = self, !self.lifecycle.finished else { return }
            self.cancel(); self.status("cancelled-background")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.next() }
    }
    private func status(_ text: String) {
        guard lifecycle.update(text) else { return }
        if lifecycle.finished {
            if let previous = previousIdleTimerDisabled {
                UIApplication.shared.isIdleTimerDisabled = previous; previousIdleTimerDisabled = nil
            }
            timer?.invalidate(); request = nil; api?.delegate = nil
            if let observer = observer { NotificationCenter.default.removeObserver(observer); self.observer = nil }
        }
        guard let folder = folder else { return }
        try? text.write(to: folder.appendingPathComponent("status.txt"), atomically: true, encoding: .utf8)
    }
    private func next() {
        guard !shouldCancel(), !lifecycle.finished else { return }
        guard UIApplication.shared.applicationState == .active else { cancel(); status("cancelled-background"); return }
        guard index < scenes.count else {
            status(MapEdgeSamples.completion(count: scenes.count, partial: partialScenes))
            api?.delegate = nil; return
        }
        guard !Settings.shared.amapKeyInUse.isEmpty else { status("failed: configure iOS SDK key in Settings"); return }
        status("query: \(scenes[index].folder)")
        class_addProtocol(MapEdgeCapture.self, AMapSearchDelegate.self)
        api = AMapSearchAPI(); api?.delegate = (self as AnyObject) as? AMapSearchDelegate
        let req = AMapPOIKeywordsSearchRequest()
        req.keywords = scenes[index].query; req.city = scenes[index].city; req.cityLimit = true; req.offset = 10
        request = req
        api?.aMapPOIKeywordsSearch(req)
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: false) { [weak self] _ in
            self?.request = nil; self?.status("failed: POI timeout")
        }
    }
    @objc(onPOISearchDone:response:)
    func searchDone(_ req: AMapPOISearchBaseRequest?, response: AMapPOISearchResponse?) {
        guard let req = req, req === request, !shouldCancel() else { return }
        request = nil; timer?.invalidate()
        guard let root = folder else { return }
        let candidates = response?.pois ?? []
        guard let poi = candidates.first(where: { MapEdgeSamples.matches(name: $0.name, at: index, in: scenes) && $0.location != nil }),
              let point = poi.location else {
            do {
                let destination = root.appendingPathComponent(scenes[index].folder)
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
                let names = candidates.map { ["name": $0.name ?? "", "type": $0.type ?? "", "adname": $0.district ?? ""] }
                try JSONSerialization.data(withJSONObject: names, options: [.prettyPrinted, .sortedKeys])
                    .write(to: destination.appendingPathComponent("poi-candidates.json"), options: .atomic)
                status("failed: exact public POI not found; review poi-candidates.json")
            } catch { status("failed: exact public POI not found; candidate export failed") }
            return
        }
        let lat = Double(point.latitude), lng = Double(point.longitude)
        guard MapEdgeSamples.contains(latitude: lat, longitude: lng, city: scenes[index].city) else { status("failed: POI outside sample city"); return }
        let scene = scenes[index], id = 60000 + index
        frameID = id; diagnostics = MapEdgeDiagnostics()
        let destination = root.appendingPathComponent(scene.folder)
        do {
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            let metadata: [String: Any] = ["query": scene.query, "city": scene.city, "poiName": poi.name ?? "", "category": scene.category,
                "coordinateSource": "AMap iOS POI keywords, GCJ-02 (not exported)", "metresPerPixel": 2,
                "styleRequested": Self.styleRequested ? "official-demo-style" : "default",
                "verifiedAssetSHA": Self.styleRequested ? MapEdgeStyle.verifiedAssetSHA : "",
                "style": 1, "qualityVersion": FastBuildings.qualityVersion, "rawFormat": "lossless PNG", "sampledFormat": "ARGB uint32 little endian",
                "appVersion": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""]
            try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys])
                .write(to: destination.appendingPathComponent("scene.json"), options: .atomic)
        } catch { status("failed: metadata export"); return }
        persistDiagnostics(to: destination)
        status("capture: \(scene.folder)")
        // Cache filenames contain coordinates: keep scratch separate from the export and remove only our own scratch.
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("edge-capture-cache-\(UUID().uuidString)")
        DispatchQueue.global(qos: .userInitiated).async {
            defer { try? FileManager.default.removeItem(at: scratch) }
            let result = Result {
                try AmapSdkRaster.build(MapGeo.Frame(refLat: lat, refLng: lng, id: id), cx: 0, cy: 0,
                    includeBuildings: true, shouldCancel: { self.shouldCancel() },
                    onBaseReady: { bytes in
                        guard !self.shouldCancel() else { return }
                        let exported = Result { try bytes.write(to: destination.appendingPathComponent("production-base.bin"), options: .atomic) }
                        DispatchQueue.main.async {
                            guard self.frameID == id, !self.lifecycle.finished else { return }
                            switch exported {
                            case .success: self.diagnostics.baseExported = true
                            case .failure(let error):
                                self.diagnostics.exportFailed = true
                                self.diagnostics.failures.append("base export failed: " + MapEdgeDiagnostics.safeError(error))
                            }
                            self.persistDiagnostics(to: destination)
                        }
                    },
                    onBuildingStatus: { message in
                        DispatchQueue.main.async {
                            guard self.frameID == id, !self.lifecycle.finished else { return }
                            self.diagnostics.noteBuildingStatus(message)
                            self.persistDiagnostics(to: destination)
                        }
                    },
                    onBuildingReady: { update in
                        DispatchQueue.main.async {
                            guard self.frameID == id, !self.lifecycle.finished else { return }
                            self.diagnostics.checkedMask = update.coverage.checkedMask
                            self.persistDiagnostics(to: destination)
                        }
                    },
                    cache: RouteMapCache(root: scratch))
            }
            DispatchQueue.main.async {
                guard self.frameID == id, !self.shouldCancel(), !self.lifecycle.finished else { return }
                self.frameID = nil
                do {
                    let output = try result.get()
                    self.diagnostics.checkedMask = output.coverage?.checkedMask
                    self.diagnostics.rasterCaptureCount = output.tiles
                    do {
                        try output.bytes.write(to: destination.appendingPathComponent("production-building.bin"), options: .atomic)
                        self.diagnostics.outputExported = true
                    } catch {
                        self.diagnostics.exportFailed = true
                        self.diagnostics.failures.append("building output export failed: " + MapEdgeDiagnostics.safeError(error))
                    }
                } catch {
                    self.diagnostics.failures.append(MapEdgeDiagnostics.safeError(error))
                }
                for name in Array(self.diagnostics.tiles.keys) where self.diagnostics.tiles[name] == "pending" {
                    self.diagnostics.tiles[name] = "not-recorded"
                }
                self.persistDiagnostics(to: destination)
                if !self.diagnostics.complete { self.partialScenes.append(self.diagnostics.summary(scene.folder)) }
                self.index += 1; self.next()
            }
        }
    }
    private func persistDiagnostics(to destination: URL) {
        do { try diagnostics.write(to: destination) }
        catch {
            diagnostics.exportFailed = true
            diagnostics.failures.append("diagnostic export failed: " + MapEdgeDiagnostics.safeError(error))
        }
    }

    @objc(AMapSearchRequest:didFailWithError:)
    func searchFailed(_ req: Any?, error: NSError?) {
        guard let req = req as? NSObject, req === request else { return }
        request = nil; timer?.invalidate(); status("failed: POI SDK error \(error?.code ?? 0)")
    }

    func customStyleData(frame: Int) -> Data? {
        frame == frameID && !lifecycle.finished && !shouldCancel() ? styleData : nil
    }
    func recordStyleStatus(frame: Int, evidence: [String: Any]) throws {
        guard Self.styleRequested, frame == frameID, !lifecycle.finished, !shouldCancel(), let root = folder else { return }
        try JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys])
            .write(to: root.appendingPathComponent(scenes[index].folder).appendingPathComponent("style-status.json"), options: .atomic)
    }
    func styleAuthFailed(code: Int32) {
        guard Self.styleRequested, !shouldCancel() else { return }
        cancel(); status("failed: custom style SDK error \(code)")
    }

    func record(_ shot: AmapCaptureHost.Shot, frame: MapGeo.Frame, x: Int, y: Int, size: Int, originalProjection: [Double]?, map: MAMapView) throws {
        guard frame.id == frameID, !lifecycle.finished, !shouldCancel(), let root = folder else { return }
        let destination = root.appendingPathComponent(scenes[index].folder)
        let name = size == 1200 ? "base" : "building-\((y == 1200 ? 0 : 2) + (x == -1200 ? 0 : 1))"
        diagnostics.tiles[name] = "exporting"
        persistDiagnostics(to: destination)
        do {
            let pixels = shot.pixels
            try MapEdgeArchive.write(pixels, width: shot.width, height: shot.height, left: shot.left, top: shot.top,
                                     right: shot.right, bottom: shot.bottom, north: shot.north, south: shot.south,
                                     size: size, to: destination, name: name + (size == 600 ? "-on" : ""))
            try png(pixels, width: shot.width, height: shot.height).write(to: destination.appendingPathComponent(name + (size == 600 ? "-on.png" : ".png")), options: .atomic)
            if let off = shot.withoutBuildings {
                try png(off, width: shot.width, height: shot.height).write(to: destination.appendingPathComponent(name + "-off.png"), options: .atomic)
            }
            let sampled = try AmapSampleGrid.sample(pixels, withoutBuildings: shot.withoutBuildings, width: shot.width,
                height: shot.height, left: shot.left, top: shot.top, right: shot.right, bottom: shot.bottom,
                north: shot.north, south: shot.south, size: size)
            try MapEdgeArchive.writePixels(sampled, to: destination.appendingPathComponent(name + "-sampled-2m.argb32le"))
            let camera: [String: Any] = ["zoom": map.zoomLevel, "camera": map.cameraDegree, "rotation": map.rotationDegree,
                                       "relativeX": x, "relativeY": y, "size": size,
                                       "offProjection": originalProjection ?? [],
                                       "onProjection": [shot.left, shot.top, shot.right, shot.bottom],
                                       "customStyle": AmapCaptureHost.shared.styleEvidence(map: map, frame: frame.id)]
            try JSONSerialization.data(withJSONObject: camera, options: [.prettyPrinted, .sortedKeys])
                .write(to: destination.appendingPathComponent(name + "-camera.json"), options: .atomic)
            diagnostics.tiles[name] = "exported"
            persistDiagnostics(to: destination)
        } catch {
            diagnostics.tiles[name] = "export-failed"; diagnostics.exportFailed = true
            diagnostics.failures.append("\(name) export failed: " + MapEdgeDiagnostics.safeError(error))
            persistDiagnostics(to: destination)
            throw error
        }
    }
    private func png(_ pixels: [UInt32], width: Int, height: Int) throws -> Data {
        var data = pixels
        let png = data.withUnsafeMutableBytes { buffer -> Data? in
            guard let image = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)?.makeImage() else { return nil }
            return UIImage(cgImage: image).pngData()
        }
        guard let png = png else { throw MapProcessingError.invalid("诊断图片导出失败") }
        return png
    }
}
#endif
#endif
