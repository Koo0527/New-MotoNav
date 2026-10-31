import Foundation

var checks = 0
func check(_ value: @autoclosure () -> Bool, _ message: String) {
    checks += 1
    if !value() { fatalError(message) }
}

// Catch early entry, missed immediate entry, and exit without continuous confirmation.
var policy = TunnelDimmingPolicy()
check(!policy.update(.approaching, now: 0), "approach starts undimmed")
check(!policy.update(.approaching, now: 0.79), "approach waits 0.8 seconds")
check(policy.update(.approaching, now: 0.8), "confirmed approach dims")
for time in [10.0, 11, 12] {
    check(policy.update(.outside, now: time), "exit waits three continuous seconds")
}
check(!policy.update(.outside, now: 13), "confirmed exit restores")
check(policy.update(.inside, now: 14), "inside dims immediately")
policy.reset()
check(!policy.isDimmed, "reset restores normal")

// Catch accumulating approach/exit time across uncertainty, gaps, or jitter.
check(!policy.update(.approaching, now: 0), "new approach")
check(!policy.update(.unknown, now: 0.7), "unknown cancels approach")
check(!policy.update(.approaching, now: 0.8), "approach restarts after unknown")
check(policy.update(.approaching, now: 1.6), "new continuous approach dims")
check(policy.update(.outside, now: 2), "exit starts")
check(policy.update(.unknown, now: 4), "unknown holds dim state")
check(policy.update(.outside, now: 4.1), "exit restarts")
check(policy.update(.outside, now: 6.1), "exit still pending")
check(policy.update(.approaching, now: 6.2), "near adjacent tunnel cancels exit")
check(policy.update(.outside, now: 7), "exit restarts after approach")
check(policy.update(.outside, now: 10), "long gap cancels exit")
check(policy.update(.outside, now: 12), "new exit still pending")
check(!policy.update(.outside, now: 13), "new continuous exit completes")
policy.reset()
check(!policy.update(.approaching, now: 0), "gap approach starts")
check(!policy.update(.approaching, now: 3), "long gap cancels approach")
check(policy.update(.approaching, now: 3.8), "approach after gap confirms")

// Catch invalid clocks being used as positive evidence or advancing a transition.
for badTime in [Double.nan, .infinity, -.infinity, 9] {
    policy.reset()
    check(policy.update(.inside, now: 10), "inside before clock fault")
    check(policy.update(.outside, now: 11), "outside before clock fault")
    check(policy.update(.outside, now: badTime), "bad clock cannot brighten")
    check(policy.update(.outside, now: 12), "clock fault cancels pending exit")
    check(policy.update(.outside, now: 14), "exit waits after clock fault")
    check(!policy.update(.outside, now: 15), "exit completes after valid observations")
}
policy.reset()
check(!policy.update(.approaching, now: 1), "approach before rollback")
check(!policy.update(.approaching, now: 0), "rollback cancels approach")
check(!policy.update(.approaching, now: 0.5), "rollback starts fresh confirmation")
check(policy.update(.approaching, now: 1.3), "fresh confirmation after rollback")

// Catch brightening a low baseline, missing clamps, overshoot and unsafe integer math.
for (normal, night, dimmed, expected) in [
    (20, 80, true, 20), (200, 40, true, 40), (200, 40, false, 200),
    (-1, 300, true, 5), (300, 400, true, 255), (Int.max, 20, false, 255)
] {
    check(TunnelDimmingPolicy.targetBrightness(normal: normal, night: night, dimmed: dimmed) == expected,
          "target clamps without raising low baseline")
}
for (current, target, expected) in [
    (100, 200, 132), (100, 20, 68), (100, 115, 115), (100, 100, 100),
    (5, 0, 5), (255, 300, 255), (Int.min, Int.max, 37), (Int.max, Int.min, 223)
] {
    check(TunnelDimmingPolicy.nextBrightness(current: current, target: target) == expected,
          "fade clamps and steps at most 32")
}

typealias Link = TunnelRoute.Link
let route = TunnelRoute(segments: [
    [Link(metres: 100, isTunnel: false)], [],
    [Link(metres: 20, isTunnel: false), Link(metres: 1, isTunnel: true),
     Link(metres: 10, isTunnel: false), Link(metres: 2, isTunnel: true)]
])
check(route.evidence(segment: 0, link: 0, metresToEndOfLink: 60) == .approaching, "80m inclusive across segments")
check(route.evidence(segment: 0, link: 0, metresToEndOfLink: 61) == .outside, "more than 80m outside")
check(route.evidence(segment: 2, link: 1, metresToEndOfLink: nil) == .inside, "short current tunnel needs no distance")
check(route.evidence(segment: 2, link: 2, metresToEndOfLink: 10) == .approaching, "adjacent tunnel keeps dimming evidence")
check(route.evidence(segment: 2, link: 4, metresToEndOfLink: 1) == .unknown, "bad link")
for (segment, link) in [(-1, 0), (3, 0), (1, 0), (0, -1)] {
    check(route.evidence(segment: segment, link: link, metresToEndOfLink: 0) == .unknown, "invalid indices")
}
for distance: Double? in [nil, .nan, .infinity, -.infinity, -1, 101] {
    check(route.evidence(segment: 0, link: 0, metresToEndOfLink: distance) == .unknown, "invalid remaining distance")
}
for length in [Double.nan, .infinity, -.infinity, -1] {
    let invalidCurrent = TunnelRoute(segments: [[Link(metres: length, isTunnel: true)]])
    check(invalidCurrent.evidence(segment: 0, link: 0, metresToEndOfLink: nil) == .unknown, "invalid tunnel length")
    let invalidNext = TunnelRoute(segments: [[Link(metres: 10, isTunnel: false), Link(metres: length, isTunnel: true)]])
    check(invalidNext.evidence(segment: 0, link: 0, metresToEndOfLink: 5) == .unknown, "invalid future length")
}
for unknownRoute in [
    TunnelRoute(segments: [[Link(metres: 10, isTunnel: nil)]]),
    TunnelRoute(segments: [[Link(metres: 10, isTunnel: false), Link(metres: 10, isTunnel: nil)]])
] {
    policy.reset()
    check(policy.update(.inside, now: 0), "dim before unknown link type")
    check(policy.update(.outside, now: 1), "pending exit before unknown link type")
    for time in 2...6 {
        let evidence = unknownRoute.evidence(segment: 0, link: 0, metresToEndOfLink: 5)
        check(evidence == .unknown, "unknown current or lookahead type cannot imply outside")
        check(policy.update(evidence, now: Double(time)), "unknown link holds dim beyond exit delay")
    }
    for time in 7...10 {
        check(policy.update(.outside, now: Double(time)) == (time < 10), "unknown resets pending exit confirmation")
    }
}
let noTunnel = TunnelRoute(segments: [[Link(metres: 10, isTunnel: false)]])
check(noTunnel.evidence(segment: 0, link: 0, metresToEndOfLink: 0) == .outside, "route ends outside")
let longRoute = TunnelRoute(segments: [Array(repeating: Link(metres: 0, isTunnel: false), count: 300) + [Link(metres: 1, isTunnel: true)]])
check(longRoute.evidence(segment: 0, link: 0, metresToEndOfLink: 0) == .unknown, "bounded lookahead cannot claim exit")
print("tunnel-dimming: \(checks) checks passed")
