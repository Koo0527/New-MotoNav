import Foundation

enum TunnelEvidence { case unknown, outside, approaching, inside }

struct TunnelDimmingPolicy {
    private(set) var isDimmed = false
    private var lastObservation: TimeInterval?
    private var pendingEvidence: TunnelEvidence?
    private var pendingSince: TimeInterval?

    mutating func update(_ evidence: TunnelEvidence, now: TimeInterval) -> Bool {
        guard now.isFinite else {
            pendingEvidence = nil
            pendingSince = nil
            lastObservation = nil
            return isDimmed
        }
        if let lastObservation, now < lastObservation {
            pendingEvidence = nil
            pendingSince = nil
            self.lastObservation = now
            return isDimmed
        }
        if let lastObservation, now - lastObservation > 2.5 {
            pendingEvidence = nil
            pendingSince = nil
        }
        lastObservation = now

        switch evidence {
        case .inside:
            isDimmed = true
            pendingEvidence = nil
            pendingSince = nil
        case .unknown:
            pendingEvidence = nil
            pendingSince = nil
        case .approaching, .outside:
            let shouldDim = evidence == .approaching
            guard shouldDim != isDimmed else {
                pendingEvidence = nil
                pendingSince = nil
                return isDimmed
            }
            if pendingEvidence != evidence {
                pendingEvidence = evidence
                pendingSince = now
            }
            if let pendingSince, now >= pendingSince + (shouldDim ? 0.8 : 3) {
                isDimmed = shouldDim
                pendingEvidence = nil
                self.pendingSince = nil
            }
        }
        return isDimmed
    }

    mutating func reset() { self = TunnelDimmingPolicy() }

    static func targetBrightness(normal: Int, night: Int, dimmed: Bool) -> Int {
        min(255, max(5, dimmed ? min(normal, night) : normal))
    }

    static func nextBrightness(current: Int, target: Int) -> Int {
        let current = min(255, max(5, current))
        let target = min(255, max(5, target))
        return current + min(32, max(-32, target - current))
    }
}

struct TunnelRoute {
    struct Link {
        let metres: Double
        let isTunnel: Bool
    }

    private let segments: [[Link]]

    init(segments: [[Link]]) { self.segments = segments }

    func evidence(segment: Int, link: Int, metresToEndOfLink: Double?) -> TunnelEvidence {
        guard segments.indices.contains(segment), segments[segment].indices.contains(link) else { return .unknown }
        let current = segments[segment][link]
        guard current.metres.isFinite, current.metres >= 0 else { return .unknown }
        if current.isTunnel { return .inside }
        guard let remaining = metresToEndOfLink, remaining.isFinite,
              remaining >= 0, remaining <= current.metres else { return .unknown }

        var distance = remaining
        var segmentIndex = segment
        var linkIndex = link + 1
        // Count segment boundaries too, so long runs of empty segments stay bounded.
        for _ in 0..<256 {
            if distance > 80 { return .outside }
            if linkIndex >= segments[segmentIndex].count {
                segmentIndex += 1
                if segmentIndex >= segments.count { return .outside }
                linkIndex = 0
                continue
            }
            let next = segments[segmentIndex][linkIndex]
            guard next.metres.isFinite, next.metres >= 0 else { return .unknown }
            if next.isTunnel { return .approaching }
            distance += next.metres
            linkIndex += 1
        }
        return .unknown
    }
}
