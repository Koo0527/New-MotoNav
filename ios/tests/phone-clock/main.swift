import Foundation

func check(_ value: Bool, _ message: String) {
    if !value { print("FAIL: \(message)"); exit(1) }
}
var clock = BlePhoneClock()
check(clock.message(wall:1793419200,uptime:0,offset:28800)=="#TIME,1793419200,28800","first authenticated connection syncs the current phone time")
check(clock.message(wall:1793419259,uptime:59,offset:28800)==nil,"ordinary heartbeat does not flood clock packets")
check(clock.message(wall:1793419260,uptime:60,offset:28800)=="#TIME,1793419260,28800","resync at the minute boundary")
check(clock.message(wall:1793419261,uptime:61,offset:20700)=="#TIME,1793419261,20700","timezone changes include non-hour offsets")
check(clock.message(wall:1793419272,uptime:62,offset:20700)=="#TIME,1793419272,20700","manual wall-clock jumps bypass the interval")
check(clock.message(wall:1793419273,uptime:63,offset:20700,force:true)=="#TIME,1793419273,20700","reconnect uses fresh time rather than replaying an old packet")
check(clock.message(wall:1793419274,uptime:1,offset:-18000)=="#TIME,1793419274,-18000","clock restart and negative timezone offsets resync")
for wall in [1577836799.0,4102444800.0,Double.nan,Double.infinity] {
    check(clock.message(wall:wall,uptime:2,offset:0,force:true)==nil,"invalid wall clock must not reach firmware")
}
check(clock.message(wall:1793419275,uptime:.nan,offset:0,force:true)==nil,"invalid monotonic clock is rejected")
check(clock.message(wall:1793419275,uptime:2,offset:50401,force:true)==nil,"out-of-range timezone is rejected")
check(clock.message(wall:1577836800,uptime:2,offset:-50400,force:true)=="#TIME,1577836800,-50400","firmware lower time and timezone bounds are inclusive")
print("PASS phone clock: fresh reconnect, pacing, clock jumps, timezones and firmware bounds")
