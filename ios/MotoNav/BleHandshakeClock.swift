import Foundation

/// Only connection setup is timed. A ready link is never cancelled by this clock.
struct BleHandshakeClock {
    enum Stage { case idle, connecting, services, notifications, ready }
    private(set) var stage: Stage = .idle
    private var deadline=Double.infinity
    mutating func begin(_ stage: Stage, now: Double) {
        self.stage=stage
        switch stage {
        case .connecting: deadline=now+45
        case .services,.notifications: deadline=now+20
        case .idle,.ready: deadline = .infinity
        }
    }
    mutating func expired(now: Double) -> Bool {
        guard now>=deadline else { return false }
        deadline = .infinity
        return true
    }
}

/// Firmware keeps ticking offline; only fresh phone time is sent after authentication.
struct BlePhoneClock {
    private var previous: (wall: TimeInterval, uptime: TimeInterval, offset: Int)?
    mutating func message(wall: TimeInterval, uptime: TimeInterval, offset: Int, force: Bool = false) -> String? {
        guard wall.isFinite, uptime.isFinite, uptime >= 0,
              wall >= 1577836800, wall < 4102444800, (-50400...50400).contains(offset) else { return nil }
        if !force, let last = previous {
            let elapsed = uptime - last.uptime
            if elapsed >= 0, elapsed < 60, offset == last.offset,
               abs((wall - last.wall) - elapsed) < 2 { return nil }
        }
        previous = (wall, uptime, offset)
        return "#TIME,\(Int64(wall)),\(offset)"
    }
}
