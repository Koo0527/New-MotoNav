import Foundation

func check(_ value: Bool, _ message: String) {
    if !value { print("FAIL: \(message)"); exit(1) }
}
var clock = PhoneClockSync()
check(clock.message(wall:1793419200,uptime:0,offset:28800)=="#TIME,1793419200,28800","first authenticated connection syncs the current phone time")
check(clock.message(wall:1793419201,uptime:1,offset:28800)==nil,"retry waits for the next heartbeat")
check(clock.message(wall:1793419202,uptime:2,offset:28800)=="#TIME,1793419202,28800","first retry uses fresh time")
check(clock.message(wall:1793419204,uptime:4,offset:28800)=="#TIME,1793419204,28800","second retry uses fresh time")
check(clock.message(wall:1793419263,uptime:63,offset:28800)==nil,"ordinary heartbeat does not flood clock packets")
check(clock.message(wall:1793419264,uptime:64,offset:28800)=="#TIME,1793419264,28800","resync at the minute boundary")
check(clock.message(wall:1793419261,uptime:61,offset:20700)=="#TIME,1793419261,20700","timezone changes include non-hour offsets")
check(clock.message(wall:1793419272,uptime:62,offset:20700)=="#TIME,1793419272,20700","manual wall-clock jumps bypass the interval")
check(clock.message(wall:1793419273,uptime:63,offset:20700,force:true)=="#TIME,1793419273,20700","reconnect uses fresh time rather than replaying an old packet")
check(clock.message(wall:1793419274,uptime:1,offset:-18000)=="#TIME,1793419274,-18000","clock restart and negative timezone offsets resync")
for wall in [1577836799.0,4102444800.0,Double.nan,Double.infinity] {
    check(clock.message(wall:wall,uptime:2,offset:0,force:true)==nil,"invalid wall clock must not reach firmware")
}
check(clock.message(wall:1793419275,uptime:.nan,offset:0,force:true)==nil,"invalid monotonic clock is rejected")
check(clock.message(wall:1793419275,uptime:-1,offset:0,force:true)==nil,"negative uptime is rejected")
check(clock.message(wall:1793419275,uptime:2,offset:Int.min,force:true)==nil,"timezone validation cannot overflow")
check(clock.message(wall:1793419275,uptime:2,offset:50401,force:true)==nil,"out-of-range timezone is rejected")
check(clock.message(wall:1577836800,uptime:2,offset:-50400,force:true)=="#TIME,1577836800,-50400","firmware lower time and timezone bounds are inclusive")
print("PASS phone clock: fresh reconnect, pacing, clock jumps, timezones and firmware bounds")
