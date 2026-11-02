import Foundation

/// Only raw Core Location measurements belong here; navigation/simulation speed is not evidence of a stop.
struct GMotionFix {
    let timestamp: TimeInterval
    let horizontalAccuracy: Double
    let speed: Double
    let speedAccuracy: Double

    func status(now: TimeInterval) -> Int {
        let age=now-timestamp
        guard age.isFinite, (0...2).contains(age),
              horizontalAccuracy.isFinite, (0...20).contains(horizontalAccuracy),
              speed.isFinite, speed>=0,
              speedAccuracy.isFinite, (0...0.5).contains(speedAccuracy) else { return 2 }
        if speed<=0.3 { return 0 }
        return speed>=1 ? 1 : 2
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
