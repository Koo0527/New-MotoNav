import Foundation

var checks = 0
func check(_ value: @autoclosure () -> Bool, _ label: String) { precondition(value(), label); checks += 1 }

// 1. 前台：恒快心跳，tick 永不断开
var fg = BleIdlePolicy(idleAfter: 180)
for t in stride(from: 0.0, through: 1000, by: 25) {
    check(!fg.tick(now: t, background: false, linkActive: false), "Foreground never disconnects")
}
check(fg.interval(background: false, linkActive: false) == 2.0, "Foreground uses the fast tick")
check(fg.interval(background: false, linkActive: true) == 2.0, "Foreground busy also uses the fast tick")

// 2. 后台 + 忙碌：快心跳、不断开，且空闲计时被刷新
var busy = BleIdlePolicy(idleAfter: 180)
check(busy.interval(background: true, linkActive: true) == 2.0, "Background navigation keeps the fast tick")
for t in stride(from: 0.0, through: 400, by: 25) {
    check(!busy.tick(now: t, background: true, linkActive: true), "Busy link never disconnects")
}
check(busy.idleSince == 400.0, "Busy ticks keep refreshing the idle origin")

// 3. 后台 + 空闲：慢心跳；满 180 秒（179 还没到）后返回断开
var idle = BleIdlePolicy(idleAfter: 180)
check(idle.interval(background: true, linkActive: false) == 25.0, "Idle background uses the slow tick")
check(!idle.tick(now: 100, background: true, linkActive: false), "Idle clock starts on the first idle tick")
check(idle.idleSince == 100.0, "Idle origin recorded from the first idle tick")
check(!idle.tick(now: 279, background: true, linkActive: false), "179s idle is not yet disconnect time")
check(idle.tick(now: 280, background: true, linkActive: false), "180s idle requests the disconnect")
check(idle.tick(now: 305, background: true, linkActive: false), "Later idle ticks keep requesting the disconnect")

// 4. 开关关闭（idleAfter = 0）：只降频，永不断开
var off = BleIdlePolicy(idleAfter: 0)
check(off.interval(background: true, linkActive: false) == 25.0, "Disabled switch still slows the heartbeat")
for t in stride(from: 0.0, through: 5000, by: 25) {
    check(!off.tick(now: t, background: true, linkActive: false), "idleAfter 0 never disconnects")
}

// 5. 锁屏骑行结束后：计时从新的空闲起点重新算（不是从进后台起算）
var ride = BleIdlePolicy(idleAfter: 180)
check(!ride.tick(now: 0, background: true, linkActive: true), "Navigation in background stays connected")
check(!ride.tick(now: 100, background: true, linkActive: true), "Navigation still running at 100s")
check(!ride.tick(now: 101, background: true, linkActive: false), "Arrival keeps the link for now")
check(!ride.tick(now: 279, background: true, linkActive: false), "179s after the last busy tick is not yet 180")
check(ride.tick(now: 280, background: true, linkActive: false), "180s from the last busy tick requests the disconnect")

// 6. onForeground 清零；再次进后台重新计时
var again = BleIdlePolicy(idleAfter: 180)
_ = again.tick(now: 0, background: true, linkActive: false)
check(again.tick(now: 180, background: true, linkActive: false), "Second idle period reaches the threshold")
again.onForeground()
check(again.idleSince == nil, "Foreground clears the idle origin")
check(!again.tick(now: 10_000, background: true, linkActive: false), "Re-entering background restarts the clock from now")
check(!again.tick(now: 10_179, background: true, linkActive: false), "Restarted clock needs a full 180s again")
check(again.tick(now: 10_180, background: true, linkActive: false), "Full idle period after restart disconnects")

// 7. 前台 tick 本身也会清零（不依赖显式 onForeground）
var mixed = BleIdlePolicy(idleAfter: 180)
_ = mixed.tick(now: 0, background: true, linkActive: false)
check(mixed.tick(now: 179, background: false, linkActive: false) == false && mixed.idleSince == nil,
      "A foreground tick resets the idle clock")

print("BLE idle policy: \(checks) checks passed")
