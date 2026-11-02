import Foundation
import UIKit

/// Download one packet at a time; foreground requests take priority between packets.
/// Lifecycle/control state lives on main; worker cancellation is synchronized.
final class MapWorkToken {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
}

final class RouteOfflineMaps {
    let style: Int
    let frame: MapGeo.Frame, plan: RouteMapPlan, source: Int, buildings: Bool
    private let worker = DispatchQueue(label: "motonav.route-offline", qos: .utility)
    private let token = MapWorkToken()
    private var jobToken: MapWorkToken?
    private let foregroundBusy: () -> Bool
    private let currentSpeed: () -> Int
    private let currentView: () -> BuildingView?
    private let onReady: (RouteMapPlan.Node) -> Void
    private let onStatus: (String) -> Void
    private var ready: [Bool], baseReady: [Bool]
    private var partialReady: [Bool]
    private var target = 0, display = 0, busy = false
    private var retryAt:[Date]
    private var renderingAvailable=true
    private var timer: Timer?
    init(frame: MapGeo.Frame, plan: RouteMapPlan, source: Int, buildings: Bool,
         foregroundBusy: @escaping () -> Bool, currentSpeed:@escaping ()->Int = {0}, currentView:@escaping ()->BuildingView? = {nil}, onReady: @escaping (RouteMapPlan.Node) -> Void, onStatus: @escaping (String) -> Void) {
        self.style = Settings.shared.theme
        self.frame = frame; self.plan = plan; self.source = source; self.buildings = buildings
        self.foregroundBusy = foregroundBusy; self.currentSpeed=currentSpeed; self.currentView=currentView; self.onReady = onReady; self.onStatus = onStatus
        ready = [Bool](repeating: false, count: plan.nodes.count); baseReady = ready; partialReady = ready
        retryAt=[Date](repeating:.distantPast,count:plan.nodes.count)
    }
    func reuseStyle(_ style: Int, source: Int, buildings: Bool) -> Bool {
        guard [1,2,3].contains(self.style), [1,2,3].contains(style), self.source == source, self.buildings == buildings else { return false }
        return true
    }
    func readUpdate(_ node: RouteMapPlan.Node) -> BuildingUpdate? {
        guard buildings else { return nil }
        return RouteMapCache.shared.buildingUpdate(frame: frame, source: source, node: node, style: style)
    }
    func read(_ node: RouteMapPlan.Node) -> Data? {
        readUpdate(node)?.bytes ?? RouteMapCache.shared.read(frame: frame, source: source, buildings: false, node: node, style: style)
    }
    func update(_ index: Int, display:Int) { target = max(0, min(plan.nodes.count - 1, index));self.display=max(0,min(plan.nodes.count-1,display)) }
    func suspendCapture() {renderingAvailable=false;jobToken?.cancel()}
    func resumeCapture() {renderingAvailable=true;retryAt=retryAt.map {_ in .distantPast}}
    func start() {
        busy = true; onStatus("沿线离线地图：检查已有地图包…")
        worker.async {
            var done = [Bool](repeating: false, count: self.plan.nodes.count), base = done, partial = done
            for (i, node) in self.plan.nodes.enumerated() {
                if self.token.isCancelled { return }
                let update=self.readUpdate(node)
                done[i] = self.buildings ? (update?.coverage.isComplete ?? false) : (self.read(node) != nil)
                partial[i] = update.map { RasterPacket.isBuilding($0.bytes) || $0.coverage.isComplete } ?? false
                base[i] = update != nil || done[i] || RouteMapCache.shared.read(frame: self.frame, source: self.source, buildings: false, node: node, style: self.style) != nil
            }
            DispatchQueue.main.async {
                guard !self.token.isCancelled else { return }
                self.ready = done; self.baseReady = base
                self.partialReady = partial
                self.busy = false
                let timer=Timer(timeInterval:0.5,repeats:true){[weak self] _ in self?.pump()}
                self.timer=timer;RunLoop.main.add(timer,forMode:.common)
                self.onReady(self.plan.nodes[self.target]); self.pump()
            }
        }
    }
    private func pump() {
        // Active screenshot pairs finish before yielding to foreground work.
        guard !token.isCancelled, !busy else { return }
        let count = ready.filter { $0 }.count, baseCount = baseReady.filter { $0 }.count
        if count == ready.count {
            onStatus("沿线底图已全部离线：\(count)/\(ready.count) 块（2 米/像素）")
            timer?.invalidate(); timer = nil; return
        }
        guard renderingAvailable,UIApplication.shared.applicationState == .active else {
            onStatus("沿线离线地图：\(baseCount)/\(ready.count) 块可用；回到 App 前台继续下载"); return
        }
        guard !foregroundBusy() else { return }
        let now=Date()
        // Preparation is independent of BLE throughput. Nearby roads still win
        // in RouteMapPreparationPolicy; cache roofs ahead even at highway speed.
        let prepareRoofs=buildings
        guard let next=RouteMapPreparationPolicy.next(base:baseReady,complete:ready,display:display,target:target,
            buildings:prepareRoofs,kmh:currentSpeed(),available:retryAt.map{now >= $0},partialReady:partialReady) else {
                return
        }
        let i=next.index,includeBuildings=next.buildings
        busy = true
        let node = plan.nodes[i]
        onStatus("沿线离线地图：\(baseCount)/\(ready.count) 块可用，下载第 \(i + 1) 块\(includeBuildings ? "（补齐建筑）" : "（普通底图优先）")")
        let job = MapWorkToken(); jobToken = job
        let view = currentView()
        worker.async {
            let result = Result { () throws -> Data in
                if self.token.isCancelled { throw MapProcessingError.cancelled }
                let packet: Data
                if self.source == MapFeeder.SRC_AMAP {
                    packet = try AmapSdkRaster.build(self.frame, cx: node.x, cy: node.y, includeBuildings: includeBuildings,
                        shouldCancel: { self.token.isCancelled || job.isCancelled }, onBaseReady: { base in
                            guard !self.token.isCancelled, !job.isCancelled else { return }
                            do {
                                try RouteMapCache.shared.store(base, frame: self.frame, source: self.source, node: node, style: self.style)
                                DispatchQueue.main.async { if !self.token.isCancelled, !job.isCancelled { self.baseReady[i] = true; self.onReady(node) } }
                            } catch { /* The final store reports storage errors in onStatus. */ }
                        }, onBuildingStatus: { message in
                            DispatchQueue.main.async { if !self.token.isCancelled, !job.isCancelled { self.onStatus(message) } }
                        }, style: self.style, preparedBase: includeBuildings ? RouteMapCache.shared.read(frame:self.frame,source:self.source,buildings:false,node:node,style:self.style,allowLegacy:false) : nil, buildingView: view, onBuildingReady: { update in
                            guard !self.token.isCancelled, !job.isCancelled else { return }
                            try? RouteMapCache.shared.storeBuildingUpdate(update, frame:self.frame, source:self.source, node:node)
                            DispatchQueue.main.async {
                                guard !self.token.isCancelled, !job.isCancelled else { return }
                                self.baseReady[i] = true
                                self.partialReady[i] = true
                                self.ready[i] = update.coverage.isComplete
                                self.onReady(node)
                            }
                        }, shouldYield: {
                            DispatchQueue.main.sync {
                                if self.foregroundBusy() {return true}
                                let next = RouteMapPreparationPolicy.next(base:self.baseReady,complete:self.ready,display:self.display,target:self.target,buildings:self.buildings,kmh:self.currentSpeed(),available:self.retryAt.map {Date() >= $0},partialReady:self.partialReady)
                                return next.map { $0.index != i && (!$0.buildings || ($0.index == self.display && !self.partialReady[self.display])) } ?? false
                            }
                        }).bytes
                } else {
                    throw MapProcessingError.invalid("沿线预下载仅支持高德底图")
                }
                if self.token.isCancelled { throw MapProcessingError.cancelled }
                // Building captures persist bytes together with coverage in the shared cache.
                if !includeBuildings {
                    try RouteMapCache.shared.store(packet, frame: self.frame, source: self.source, node: node, style: self.style)
                }
                return packet
            }
            DispatchQueue.main.async {
                guard !self.token.isCancelled else { return }
                self.busy = false
                if job.isCancelled {self.retryAt[i] = .distantPast;return}
                switch result {
                case .success:
                    self.baseReady[i] = true
                    self.ready[i] = !self.buildings || (self.readUpdate(node)?.coverage.isComplete ?? false)
                    self.retryAt[i] = self.ready[i] || !includeBuildings ? .distantPast : Date().addingTimeInterval(15)
                    self.onReady(node)
                    if !self.ready[i] && includeBuildings { self.onStatus("沿线普通底图已保存；建筑未完成，稍后重试") }
                case .failure(MapProcessingError.cancelled):
                    self.retryAt[i] = .distantPast
                case .failure(let error):
                    self.retryAt[i] = Date().addingTimeInterval(15)
                    self.onStatus("沿线离线地图：\(error.localizedDescription)，保留已保存地图")
                }
            }
        }
    }
    func close() { token.cancel(); jobToken?.cancel(); timer?.invalidate(); timer = nil }
}
