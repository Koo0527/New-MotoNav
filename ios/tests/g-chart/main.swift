import Foundation
func point(_ t: Double, _ x: Double = 0, _ y: Double = 0, valid: Bool = true) -> GPlotPoint {
    GPlotPoint(time: t, lateral: x, longitudinal: y, valid: valid)
}
let clip = GChartGeometry.clipped(lateral: 3, longitudinal: 4, range: 1)
assert(abs(clip.0 - 0.6) < 0.0001 && abs(clip.1 + 0.8) < 0.0001)
assert(GChartGeometry.window(end: 1000, duration: 10, bounds: 0...100) == 90...100)
assert(GChartGeometry.window(end: -20, duration: 10, bounds: 0...100) == 0...10)
assert(GChartGeometry.segments([point(0), point(0.1), point(0.2, valid: false), point(0.3), point(1)]).map(\.count) == [2,1,1])
assert(GChartGeometry.segments([point(0), GPlotPoint(time: 0.1, lateral: 1, longitudinal: 0, valid: true, gap: true)]).map(\.count) == [1,1])
var trace = (0..<1000).map { point(Double($0) / 100) }
trace[123] = point(1.23, 1.9, -1.8); trace[124] = point(1.24, -1.7, 1.6)
let reduced = GChartGeometry.decimate(trace, pixels: 20)
assert(reduced.count <= 120 && reduced.contains(trace[123]) && reduced.contains(trace[124]))
assert(GChartGeometry.selected([point(0), point(1)], at: 0.5) == nil)
assert(GChartGeometry.selected([point(1, valid: false)], at: 1) == nil)
assert(GChartGeometry.selected([point(0), GPlotPoint(time: 10, lateral: 1, longitudinal: 0, valid: true, gap: true)], at: 5, maxDistance: .infinity) == nil)
print("PASS: radial clipping, bounded windows, invalid/time gaps, peak preserving decimation, gap selection")
