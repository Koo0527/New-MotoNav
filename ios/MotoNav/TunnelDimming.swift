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
        let isTunnel: Bool?
    }

    private let segments: [[Link]]

    init(segments: [[Link]]) { self.segments = segments }

    func evidence(segment: Int, link: Int, metresToEndOfLink: Double?) -> TunnelEvidence {
        guard segments.indices.contains(segment), segments[segment].indices.contains(link) else { return .unknown }
        let current = segments[segment][link]
        guard current.metres.isFinite, current.metres >= 0, let isTunnel = current.isTunnel else { return .unknown }
        if isTunnel { return .inside }
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
            guard next.metres.isFinite, next.metres >= 0, let isTunnel = next.isTunnel else { return .unknown }
            if isTunnel { return .approaching }
            distance += next.metres
            linkIndex += 1
        }
        return .unknown
    }
}

/// Physical BOOT revisions arbitrate reconnects; acknowledged duplicates never replay a phone target.
struct DeviceTunnelSync {
    private(set) var revision: UInt16?
    private var lastCommand: String?
    private var physicalPending = false
    private var physicalTunnel = false
    mutating func receive(_ fields: [String]) -> Bool? {
        guard fields.count == 6, fields[0] == "CTL", fields[1].count == 4,
              let revision = UInt16(fields[1], radix: 16),
              fields[2...5].allSatisfy({ $0 == "0" || $0 == "1" }) else { return nil }
        if let current = self.revision, revision != current, revision &- current > 32767 { return nil }
        let adopt = self.revision != revision
        if adopt { physicalPending = fields[5] == "1"; physicalTunnel = fields[2] == "1" }
        else if fields[5] == "0" { physicalPending = false }
        self.revision = revision
        return adopt ? fields[2] == "1" : nil
    }
    mutating func command(normal: Int, dim: Int, night: Bool, tunnel: Bool) -> String? {
        guard let revision else { return nil }
        // Acknowledge the physical state before a later phone target can replace its queued command.
        let target = physicalPending ? physicalTunnel : tunnel
        let text = String(format: "#TM,%04X,%d,%d,%d,%d", Int(revision),
                          min(255, max(5, normal)), min(255, max(5, dim)), night ? 1 : 0, target ? 1 : 0)
        guard text != lastCommand else { return nil }
        lastCommand = text
        return text
    }
}
