import Foundation
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    precondition(condition(), message)
}
func fix(age: Double = 0, accuracy: Double = 20, speed: Double = 0.3, speedAccuracy: Double = 0.5) -> GMotionFix {
    GMotionFix(timestamp: 100-age, horizontalAccuracy: accuracy, speed: speed, speedAccuracy: speedAccuracy)
}
check(fix().status(now: 100) == 0, "inclusive stopped and accuracy boundaries")
check(fix(age: 2, speed: 1).status(now: 100) == 1, "inclusive moving and age boundaries")
check(fix(accuracy: 0, speed: 0, speedAccuracy: 0).status(now: 100) == 0, "zero is valid")
for speed in [0.30001, 0.99999] { check(fix(speed: speed).status(now: 100) == 2, "ambiguous speed unknown") }
for sample in [fix(age: 2.00001), fix(age: -0.001), fix(age: .nan), fix(age: .infinity),
               fix(accuracy: -1), fix(accuracy: 20.00001), fix(accuracy: .nan), fix(accuracy: .infinity),
               fix(speed: -1), fix(speed: .nan), fix(speed: .infinity),
               fix(speedAccuracy: -1), fix(speedAccuracy: 0.50001), fix(speedAccuracy: .nan), fix(speedAccuracy: .infinity)] {
    check(sample.status(now: 100) == 2, "untrusted fix unknown")
}
check(fix().status(now: .nan) == 2, "invalid clock unknown")
var now=100.0, sample: GMotionFix?=fix(), messages:[String]=[]
let reporter=GMotionReporter(active: true, sample: { sample }, now: { now }, send: { messages.append($0) })
reporter.refresh()
check(messages.isEmpty, "old firmware never receives GM")
reporter.setCapability()
check(messages == ["#GM,0"] && reporter.running, "capability immediately starts stopped heartbeat")
reporter.refresh();check(messages.last == "#GM,0", "stopped status is renewed")
now=103;check(reporter.message == "#GM,2", "queued write revalidates a previously stopped sample");reporter.refresh();check(messages.last == "#GM,2", "stale sample cannot renew stopped")
sample=fix(age: -3, speed: 2);reporter.refresh();check(messages.last == "#GM,1", "fresh raw speed moves")
reporter.setActive(false)
check(messages.last == "#GM,2" && !reporter.running && reporter.message == "#GM,2", "inactive sends unknown and replaces queued stop")
let inactiveCount=messages.count
reporter.refresh();check(messages.count == inactiveCount, "inactive never renews stopped")
now=104;reporter.setActive(true)
check(messages.last == "#GM,2" && reporter.running, "foreground rejects pre-resume sample")
sample=fix(age: -4);reporter.refresh();check(messages.last == "#GM,0", "new foreground location restores stopped")
reporter.reset()
check(!reporter.running && reporter.message == nil, "disconnect stops timer and discards pending status")
let resetCount=messages.count
reporter.refresh();reporter.setActive(false);reporter.setActive(true)
check(messages.count == resetCount, "reconnect requires new capability")
sample=nil;reporter.setCapability();check(messages.last == "#GM,2", "no location unknown")
// Exercise the actual repeating timer and its cancellation, not only manual ticks.
sample=GMotionFix(timestamp:now,horizontalAccuracy:1,speed:0,speedAccuracy:0.1)
let timerCount=messages.count
RunLoop.current.run(until:Date().addingTimeInterval(1.1))
check(messages.count > timerCount && messages.last == "#GM,0", "one-second timer emits current status")
reporter.reset();let stoppedCount=messages.count
RunLoop.current.run(until:Date().addingTimeInterval(1.1))
check(messages.count == stoppedCount, "disconnect cancels scheduled writes")
print("PASS G motion: trust boundaries, raw status, capability, timer, disconnect and foreground freshness")
