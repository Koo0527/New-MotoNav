
var checks=0
func check(_ value:@autoclosure ()->Bool,_ message:String){precondition(value(),message);checks+=1}
func spin(_ seconds:Double){let end=Date().addingTimeInterval(seconds);while Date()<end{_ = RunLoop.main.run(mode:.default,before:Date().addingTimeInterval(0.01))}}
func busy(_ s:WebMotorSession)->Bool{Mirror(reflecting:s).children.first{$0.label=="rerouting"}!.value as! Bool}
func makeRoute(_ lat:Double=30)->MotorRoute {
    let points=[MotorPoint(lat:lat,lng:104),MotorPoint(lat:lat+0.02,lng:104)]
    return MotorRoute(request:MotorRequest(start:points[0],end:points[1]),points:points,steps:[MotorStep(instruction:"continue",road:"A",action:"",end:1)],seconds:200)
}
func fix(_ lat:Double,_ lng:Double)->CLLocation {
    CLLocation(coordinate:CLLocationCoordinate2D(latitude:lat,longitude:lng),altitude:0,horizontalAccuracy:5,verticalAccuracy:5,course:90,speed:8,timestamp:Date())
}
func trigger(_ session:WebMotorSession){
    session.onFix(fix(30.005,104));spin(0.5)
    session.onFix(fix(30.005,104.0004));spin(1.05)
    session.onFix(fix(30.005,104.00045));spin(0.1)
}

// Trigger times use the actual new Swift policy and physical 90-degree fixtures.
for (kmh,expected) in [(20,6.0),(30,5.0),(60,3.0)] {
    var policy=MotorReroutePolicy();var triggered:Double?
    for i in 0...30 where triggered==nil {
        if policy.observe(offset:Double(i)*Double(kmh)/3.6,accuracy:5,now:Double(i)){triggered=Double(i)}
    }
    check(triggered==expected,"adaptive confirmation timing")
    print("TRIGGER \(kmh)km/h = \(triggered!) seconds, excluding server")
}
var jitter=MotorReroutePolicy()
for i in 0..<30 {check(!jitter.observe(offset:i%2==0 ? 35:10,accuracy:5,now:Double(i)),"one-frame GPS jumps cannot replan")}
var inaccurate=MotorReroutePolicy()
for i in 0..<10 {check(!inaccurate.observe(offset:45,accuracy:30,now:Double(i)),"uncertain positioning must raise threshold")}
check(!inaccurate.observe(offset:100,accuracy:55,now:20),"invalid accuracy rejected")
var gap=MotorReroutePolicy();_ = gap.observe(offset:40,accuracy:5,now:0)
check(!gap.observe(offset:40,accuracy:5,now:4),"GPS gap resets confirmation")
check(gap.observe(offset:40,accuracy:5,now:5),"confirmation resumes with new valid fixes")
let first=gap.begin(now:5)!
check(gap.begin(now:6)==nil,"one calculation at a time")
check(gap.expired(now:16.99)==nil && gap.expired(now:17)==first,"12-second deadline")
check(gap.finish(first,now:17,success:false),"failure releases lease")
check(gap.begin(now:24.9)==nil,"failure backoff is bounded")
let second=gap.begin(now:25)!
check(!gap.finish(first,now:26,success:true) && gap.pending==second,"late old result cannot close new request")
gap.reset();check(gap.begin(now:26) != nil,"new journey resets old cooldown")

check(MotorReroutePolicy.threshold(accuracy:0)==25 && MotorReroutePolicy.threshold(accuracy:20)==32 && MotorReroutePolicy.threshold(accuracy:50)==80,"accuracy threshold bounds")
var rapid=MotorReroutePolicy()
check(!rapid.observe(offset:40,accuracy:5,now:0),"first deviation alone cannot replan")
check(!rapid.observe(offset:40,accuracy:5,now:0.79),"confirmation requires 0.8 seconds")
check(rapid.observe(offset:40,accuracy:5,now:0.8),"confirmed deviation can replan at 0.8 seconds")
let rapidID=rapid.begin(now:0.8)!
check(rapid.finish(rapidID,now:1,success:true),"success releases lease")
check(rapid.begin(now:6.99)==nil && rapid.begin(now:7) != nil,"success cooldown is six seconds")

let session=WebMotorSession.shared,original=makeRoute(),newRoute=makeRoute(30.001)
MotorRoutes.answer=newRoute

// Accepted reroutes must interrupt existing speech, not merely suppress future announcements.
MotorRoutes.mode = .empty;session.start(original,simulate:false)
Speech.shared.speak("old turn playing");Speech.shared.speak("old turn queued")
check(Speech.shared.queued.count==2,"speech fixture carries playing and queued old guidance")
session.replan(MotorPoint(lat:30.005,lng:104.001))
check(busy(session) && Speech.shared.queued.isEmpty,"accepted reroute must immediately clear playing and queued old turns")
spin(0.2)
check(!busy(session),"empty answer completes failed reroute before cooldown check")
Speech.shared.speak("current guidance during cooldown")
session.replan(MotorPoint(lat:30.005,lng:104.001))
check(!busy(session) && Speech.shared.queued==["current guidance during cooldown"],"reroute rejected during failure cooldown must preserve current speech")
session.stop()

MotorRoutes.mode = .empty;session.start(original,simulate:false);BleLink.shared.messages=[];trigger(session)
check(!busy(session) && session.running && session.route?.id==original.id,"empty route restores running state and retains original route")
check(BleLink.shared.messages.contains("#y,1") && BleLink.shared.messages.last=="#y,0","every early failure clears small-screen rerouting")
session.stop()

MotorRoutes.mode = .failure;session.start(original,simulate:false);trigger(session)
check(!busy(session) && session.running && session.status.contains("重算失败"),"network failure keeps old navigation usable")
session.stop()

MotorRoutes.mode = .cancelled;session.start(original,simulate:false);trigger(session)
check(!busy(session) && session.route?.id==original.id,"cancelled calculation releases its lease and keeps old route")
session.stop()

MotorRoutes.mode = .success;session.start(original,simulate:false);trigger(session)
check(!busy(session) && session.running && session.route?.id==newRoute.id,"success installs new route and releases lease")
check(WebRouteMetadata.shared.current==newRoute.id && MapFeeder.shared.keys.last==newRoute.id.uuidString,"successful route replaces map and metadata")
check(Mirror(reflecting:session).children.first{$0.label=="announced"}!.value as! String == "","new route resets voice deduplication")
BleLink.shared.images=[]
spin(0.5);session.onFix(fix(30.005,104))
check(BleLink.shared.images.contains(0) && BleLink.shared.images.contains(1),"new route refreshes instruction and footer images")
session.stop()

// Real session watchdog: suspend I/O without honoring cancellation, keep GPS callbacks active.
MotorRoutes.mode = .suspend;session.start(original,simulate:false);BleLink.shared.messages=[];trigger(session)
check(busy(session),"suspended I/O enters bounded recalculation")
BleLink.shared.messages=[];Speech.shared.spoken=[]
spin(0.5);session.onFix(fix(30.005,104))
check(!BleLink.shared.messages.contains{["L,","R,","S,","U,","SL,","SR,"].contains(where:$0.hasPrefix)} && Speech.shared.spoken.isEmpty,"pending recalculation suppresses stale turn packets and speech even back on route")
let pendingAt=ProcessInfo.processInfo.systemUptime
while ProcessInfo.processInfo.systemUptime-pendingAt<13.3 {spin(0.5);session.onFix(fix(30.005,104.00045))}
check(!busy(session) && session.running && session.route?.id==original.id,"watchdog recovers even when I/O never resumes")
check(session.status.contains("重算失败"),"timeout remains visible instead of being instantly overwritten by GPS")
let held=session.route!.id
let late=MotorRoutes.waiting.removeFirst();late.resume(returning:[newRoute]);spin(0.2)
check(session.route?.id==held && !busy(session),"late timed-out response cannot replace displayed route")
session.stop()

// Stop/start cannot be undone by the old asynchronous result.
session.start(original,simulate:false);trigger(session);check(busy(session),"new session has no inherited backoff")
let old=MotorRoutes.waiting.removeFirst();session.stop();session.start(newRoute,simulate:false)
old.resume(returning:[original]);spin(0.2)
check(session.running && session.route?.id==newRoute.id && !busy(session),"old response cannot revive cancelled journey")
session.stop()

let endedCalls=MotorRoutes.calls
session.replan(MotorPoint(lat:30.02,lng:104));spin(0.1)
check(MotorRoutes.calls==endedCalls && !busy(session),"an arrival/stop cannot launch a leftover recalculation")

session.start(original,simulate:false)
let queuedCalls=MotorRoutes.calls
session.replan(MotorPoint(lat:30.005,lng:104.001));session.stop();spin(0.2)
check(MotorRoutes.calls==queuedCalls && !busy(session),"stopping a queued request prevents its network operation from starting")

// Matcher correctness against baseline for loops, boundaries and movement.
let line=(0...1200).map{MotorPoint(lat:30+Double($0)/111320,lng:104)}
var current=MotorRouteTracker(line),legacy=LegacyMotorRouteTracker(line)
for i in 0...600 {
    let p=MotorPoint(lat:30+Double(i)/111320,lng:104+(i%19==0 ? 0.0003:0))
    let a=current.update(p,accuracy:5,now:Double(i)),b=legacy.update(p,accuracy:5,now:Double(i))
    check((a==nil)==(b==nil),"matcher acceptance parity")
    if let a=a,let b=b {check(abs(a.progress-b.progress)<1e-8 && abs(a.offset-b.offset)<1e-8 && a.arrived==b.arrived,"optimized matcher preserves progress and arrival")}
}
for fixture in [
    [MotorPoint(lat:30,lng:104),MotorPoint(lat:30,lng:104),MotorPoint(lat:30.001,lng:104),MotorPoint(lat:30.001,lng:104.001),MotorPoint(lat:30,lng:104.001),MotorPoint(lat:30,lng:104)],
    [MotorPoint(lat:30,lng:104),MotorPoint(lat:30.001,lng:104),MotorPoint(lat:30.001,lng:104),MotorPoint(lat:30.002,lng:104)]
] {
    var a=MotorRouteTracker(fixture),b=LegacyMotorRouteTracker(fixture)
    for (i,p) in fixture.enumerated() {
        let x=a.update(p,accuracy:5,now:Double(i)*2),y=b.update(p,accuracy:5,now:Double(i)*2)
        check((x==nil)==(y==nil),"loop and duplicate boundary acceptance parity")
        if let x=x,let y=y {check(abs(x.progress-y.progress)<1e-8 && abs(x.offset-y.offset)<1e-8 && x.arrived==y.arrived,"loop and duplicate boundary matcher output parity")}
    }
}
let long=(0...149999).map{MotorPoint(lat:30+Double($0)/111320,lng:104)}
var fast=MotorRouteTracker(long),slow=LegacyMotorRouteTracker(long)
let begun=ProcessInfo.processInfo.systemUptime
for i in 0..<1000 {_ = fast.update(long[i],accuracy:5,now:Double(i))}
let fastSeconds=ProcessInfo.processInfo.systemUptime-begun,oldAt=ProcessInfo.processInfo.systemUptime
for i in 0..<1000 {_ = slow.update(long[i],accuracy:5,now:Double(i))}
let slowSeconds=ProcessInfo.processInfo.systemUptime-oldAt
print("MATCHER macOS host (not iPhone): optimized=\(fastSeconds)s baseline=\(slowSeconds)s for 1000 fixes / 150000 points")
print("PASS production Swift session, timeout/empty/failure/cancellation/late results, geometry parity: \(checks) checks")
