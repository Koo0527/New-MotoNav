import Foundation

struct GPlotPoint: Equatable {
    let time: Double
    let lateral: Double
    let longitudinal: Double
    let valid: Bool
    var gap = false
}

/// Shared by both charts; invalid samples and transport gaps split the path.
enum GChartGeometry {
    static func clipped(lateral: Double, longitudinal: Double, range: Double) -> (Double, Double) {
        guard lateral.isFinite, longitudinal.isFinite, range > 0 else { return (0, 0) }
        let magnitude = hypot(lateral, longitudinal)
        let divisor = max(range, magnitude)
        return (lateral / divisor, -longitudinal / divisor)
    }
    static func window(end: Double, duration: Double, bounds: ClosedRange<Double>) -> ClosedRange<Double> {
        let width = min(max(1, duration), max(1, bounds.upperBound - bounds.lowerBound))
        let upper = min(bounds.upperBound, max(bounds.lowerBound + width, end))
        return max(bounds.lowerBound, upper - width)...upper
    }
    static func segments(_ points: [GPlotPoint], maxGap: Double = 0.35) -> [[GPlotPoint]] {
        var result: [[GPlotPoint]] = [], current: [GPlotPoint] = []
        for point in points {
            guard point.valid, point.lateral.isFinite, point.longitudinal.isFinite else {
                if !current.isEmpty { result.append(current); current = [] }; continue
            }
            if let last = current.last, point.gap || point.time - last.time > maxGap || point.time <= last.time {
                result.append(current); current = []
            }
            current.append(point)
        }
        if !current.isEmpty { result.append(current) }
        return result
    }
    /// Keep each pixel bucket's first/last and both channels' extrema in time order.
    static func decimate(_ points: [GPlotPoint], pixels: Int) -> [GPlotPoint] {
        guard pixels > 0, points.count > pixels * 6, let first = points.first, let last = points.last,
              last.time > first.time else { return points }
        let span = last.time - first.time
        var output: [GPlotPoint] = [], bucket: [GPlotPoint] = [], key = -1
        func flush() {
            guard !bucket.isEmpty else { return }
            if bucket.contains(where: { !$0.valid }) { output += bucket; return }
            var indices = Set([0, bucket.count - 1])
            for axis in 0..<2 {
                let values = bucket.map { axis == 0 ? $0.lateral : $0.longitudinal }
                if let lo = values.indices.min(by: { values[$0] < values[$1] }) { indices.insert(lo) }
                if let hi = values.indices.max(by: { values[$0] < values[$1] }) { indices.insert(hi) }
            }
            output += indices.sorted().map { bucket[$0] }
        }
        for point in points {
            let next = min(pixels - 1, Int((point.time - first.time) / span * Double(pixels)))
            if next != key { flush(); bucket = []; key = next }
            bucket.append(point)
        }
        flush(); return output
    }
    static func selected(_ points: [GPlotPoint], at time: Double, maxDistance: Double = 0.3) -> GPlotPoint? {
        if let after = points.first(where: { $0.time > time }), after.gap,
           let before = points.last(where: { $0.time < time }), time > before.time { return nil }
        guard let point = points.min(by: { abs($0.time - time) < abs($1.time - time) }),
              abs(point.time - time) <= maxDistance, point.valid else { return nil }
        return point
    }
}
