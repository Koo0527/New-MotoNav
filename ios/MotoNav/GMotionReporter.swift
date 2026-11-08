import Foundation

/// Only raw Core Location measurements belong here; navigation/simulation speed is not evidence of a stop.
enum GMotionClassification: Equatable {
    case stopped, moving
    case unknown(String)
}
struct GMotionFix {
    let timestamp: TimeInterval
    let horizontalAccuracy: Double
    let speed: Double
    let speedAccuracy: Double

    func classification(now: TimeInterval) -> GMotionClassification {
        let age=now-timestamp
        guard age.isFinite, (0...2).contains(age) else { return .unknown("定位年龄超出 0–2 秒") }
        guard horizontalAccuracy.isFinite, (0...20).contains(horizontalAccuracy) else { return .unknown("水平精度超出 20 米") }
        guard speed.isFinite, speed>=0 else { return .unknown("速度无效") }
        guard speedAccuracy.isFinite, (0...0.5).contains(speedAccuracy) else { return .unknown("速度精度超出 0.5 m/s") }
        if speed<=0.3 { return .stopped }
        return speed>=1 ? .moving : .unknown("速度介于 0.3–1 m/s")
    }
    func status(now: TimeInterval) -> Int {
        switch classification(now: now) {
        case .stopped: return 0
        case .moving: return 1
        case .unknown: return 2
        }
    }
}

/// Motion is an expiring observation, never a reconnectable cached setting.
final class GMotionReporter {
    private var supported=false
    private var active: Bool
    private var resumedAt = -Double.infinity
    private var timer: Timer?
    private let sample: () -> GMotionFix?
    private let now: () -> TimeInterval
    private let send: (String) -> Void
    var running: Bool { timer != nil }

    init(active: Bool, sample: @escaping () -> GMotionFix?,
         now: @escaping () -> TimeInterval = { Date().timeIntervalSince1970 }, send: @escaping (String) -> Void) {
        self.active=active; self.sample=sample; self.now=now; self.send=send
    }
    deinit { timer?.invalidate() }

    /// Re-evaluate at the BLE write boundary too: a congested queue must not extend a stale stop.
    var message: String? {
        guard supported else { return nil }
        let fix=sample()
        let status = active && (fix?.timestamp ?? -Double.infinity)>=resumedAt ? fix?.status(now:now()) ?? 2 : 2
        return "#GM,\(status)"
    }
    /// Raw fields behind the current #GM status, for on-device diagnosis without changing thresholds.
    var diagnosis: String {
        guard supported else { return "旧固件未协商 GM 能力" }
        guard active else { return "App 非前台：不发送停车依据" }
        guard let fix=sample() else { return "无原始定位：检查定位权限、系统开关和模拟源" }
        let stamp=now(), age=stamp-fix.timestamp
        let detail=String(format:"年龄 %.2fs · 水平 ±%.1fm · 速度 %.2f±%.2fm/s", age, fix.horizontalAccuracy, fix.speed, fix.speedAccuracy)
        guard fix.timestamp>=resumedAt else { return "未知：定位早于本次前台 · \(detail)" }
        switch fix.classification(now: stamp) {
        case .stopped: return "可信停车 · \(detail)"
        case .moving: return "可信行驶 · \(detail)"
        case .unknown(let reason): return "未知：\(reason) · \(detail)"
        }
    }
    func setCapability() {
        supported=true
        if active { start() } else if let message { send(message) }
    }
    func reset() {
        supported=false
        timer?.invalidate();timer=nil
    }
    func setActive(_ value: Bool) {
        guard active != value else { return }
        active=value
        timer?.invalidate();timer=nil
        if value { resumedAt=now(); if supported { start() } }
        else if let message { send(message) }
    }
    func refresh() {
        guard active, let message else { return }
        send(message)
    }
    private func start() {
        refresh()
        guard timer == nil else { return }
        let timer=Timer(timeInterval:1, repeats:true) { [weak self] _ in self?.refresh() }
        self.timer=timer
        RunLoop.main.add(timer,forMode:.common)
    }
}
