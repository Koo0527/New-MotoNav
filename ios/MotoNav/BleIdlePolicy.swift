import Foundation

/// 后台省电策略（纯逻辑，无 UIKit 依赖）：BleLink 每次心跳时查询，全部状态只在主线程访问。
/// - 前台或链路忙碌（导航 / 巡航 / G 录制 / 圆屏音乐模式 / 地图数据未传完）→ 2 秒快心跳，绝不空闲断开；
///   导航中 "P" 心跳照旧每 2 秒一次，圆屏 "数据中断"（STALE_MS）提示行为不变。
/// - 后台且空闲 → 25 秒慢心跳；开着空闲断开（idleAfter > 0）且空闲持续满 idleAfter 秒 → tick 返回 true，
///   由 BleLink 断开圆屏连接，系统随后可挂起 App。
/// 空闲时长从"链路在后台最后一次确认忙碌"起算（锁屏骑行到站后重新计时），回前台即清零。
struct BleIdlePolicy {
    static let fastTick: TimeInterval = 2.0
    static let slowTick: TimeInterval = 25.0

    /// 空闲多少秒后断开；0 = 只降频不断开（设置开关关闭时用）
    let idleAfter: TimeInterval
    /// 后台里最后一次确认"忙碌"的时刻（systemUptime 秒）；nil = 前台或刚清零，还没开始空闲计时
    private(set) var idleSince: Double?

    init(idleAfter: TimeInterval) { self.idleAfter = idleAfter }

    mutating func onForeground() { idleSince = nil }

    /// 每次心跳调用。返回 true = 空闲已持续满 idleAfter，应当断开（前台一律返回 false）。
    mutating func tick(now: Double, background: Bool, linkActive: Bool) -> Bool {
        guard background else {
            idleSince = nil
            return false
        }
        if linkActive {
            idleSince = now
            return false
        }
        if idleSince == nil { idleSince = now }
        guard idleAfter > 0, let since = idleSince else { return false }
        return now - since >= idleAfter
    }

    /// 当前应使用的心跳间隔
    func interval(background: Bool, linkActive: Bool) -> TimeInterval {
        background && !linkActive ? Self.slowTick : Self.fastTick
    }
}
