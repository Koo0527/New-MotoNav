import Foundation

/// Monotonic, accuracy-aware confirmation and a bounded lease for one recalculation.
struct MotorReroutePolicy {
    static let requestTimeout: TimeInterval = 12
    static func threshold(accuracy: Double) -> Double { max(25, min(80, accuracy * 1.6)) }
    private(set) var pending: UUID?
    private var startedAt = 0.0, nextAllowed = -Double.infinity
    private var firstOff: Double?, lastFix: Double?, count = 0

    mutating func reset() { self = MotorReroutePolicy() }
    mutating func observe(offset: Double, accuracy: Double, now: Double) -> Bool {
        guard offset.isFinite, offset >= 0, accuracy.isFinite, (0...50).contains(accuracy), now.isFinite else {
            firstOff = nil; count = 0; return false
        }
        if let previous = lastFix {
            if now <= previous { return false }
            if now - previous > 3 { firstOff = nil; count = 0 }
        }
        lastFix = now
        guard pending == nil else { return false }
        guard offset > Self.threshold(accuracy: accuracy) else { firstOff = nil; count = 0; return false }
        if firstOff == nil { firstOff = now }
        count += 1
        return count >= 2 && now - (firstOff ?? now) >= 0.8 && now >= nextAllowed
    }
    mutating func begin(now: Double) -> UUID? {
        guard pending == nil, now.isFinite, now >= nextAllowed else { return nil }
        let id = UUID(); pending = id; startedAt = now; firstOff = nil; count = 0
        return id
    }
    func expired(now: Double) -> UUID? {
        guard let id = pending, now.isFinite, now - startedAt >= Self.requestTimeout else { return nil }
        return id
    }
    @discardableResult mutating func finish(_ id: UUID, now: Double, success: Bool) -> Bool {
        guard pending == id else { return false }
        pending = nil; firstOff = nil; count = 0
        nextAllowed = now + (success ? 6 : 8)
        return true
    }
}
