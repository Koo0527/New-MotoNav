import Foundation

/// 版本：跟随 App 版本（见 Config.swift）
///
/// 轻量的 SDK 实例协调器（不引入通用插件框架）。
/// 高德导航 SDK 10.1.600 里 AMapNaviDriveManager 和 AMapNaviRideManager 是互斥单例
/// （拿了一个必须先 destroyInstance 才能拿另一个），所以由这里集中管理引擎所有权：
///
/// - 引擎归属：none / drive / ride，任何代码创建引擎前必须先在这里认领。
/// - 切换顺序固定为：失效旧回调 → 停止导航和相关任务 → 解绑地图、delegate 和数据代表 →
///   释放引用 → 确认销毁成功 → 创建目标引擎。前四步由所属桥接层按协调器的调用顺序执行，
///   后两步（destroyInstance 确认与创建）只在这里发生。
/// - 销毁失败时不创建另一个 SDK 实例：activate 返回失败说明，由调用方提示重试或使用兼容导航。
/// - 会话代次：每次引擎变更 session + 1，供诊断与测试观察；迟到回调由各桥接层自己的
///   ArrivalPolicy 代次隔离，引擎销毁后旧单例本身也不复存在。
/// - “正在导航”统一判断（navigationActive）覆盖驾车、官方骑行和独立导航，
///   防止更换目的地、巡航或导入分享抢占当前导航。
///
/// 注意：所有方法都在主线程调用（和 NaviBridge / RideBridge 一致）。
final class NavigationCoordinator {
    static let shared = NavigationCoordinator()

    /// 当前拥有 SDK 引擎的一方；.none 表示还没有任何引擎（应用启动后不再无条件创建驾车引擎）
    enum Engine: String, Equatable { case none, drive, ride }

    private(set) var active: Engine = .none
    /// 引擎变更代次：从 1 开始，每次 activate / deactivateAll 都会前进
    private(set) var session: UInt64 = 0
    /// 最近一次切换失败的说明（销毁失败时给用户看重试或兼容导航的提示）
    private(set) var lastFailure: String?

    private init() {}

    // MARK: - 引擎切换（固定顺序）

    /// 确认 `target` 引擎可用。返回 nil = 已就绪；返回失败说明 = 旧引擎没能销毁，
    /// 此时绝不创建目标引擎实例，调用方应提示重试或改用兼容导航。
    @discardableResult
    func activate(_ target: Engine) -> String? {
        dispatchPrecondition(condition: .onQueue(.main))
        let previous = active
        if previous == target {
            lastFailure = nil
            return nil
        }
        if let failure = teardown(active: previous) {
            lastFailure = failure
            return failure
        }
        create(target)
        if active != previous { session += 1 }
        return nil
    }

    /// 销毁当前引擎后回到 .none（换高德 key 时用）：下一次使用时再按需创建，避免提前实例化。
    @discardableResult
    func deactivateAll() -> String? {
        dispatchPrecondition(condition: .onQueue(.main))
        let previous = active
        if let failure = teardown(active: previous) {
            lastFailure = failure
            return failure
        }
        if active != previous { session += 1 }
        return nil
    }

    /// 按固定顺序释放 `engine`：失效回调 → 停止任务 → 解绑并释放引用 → 确认销毁。
    /// 销毁失败时返回失败说明，且 active 保持原值（单例仍被 SDK 持有）。
    private func teardown(active engine: Engine) -> String? {
        switch engine {
        case .none:
            return nil
        case .drive:
            let bridge = NaviBridge.shared
            if bridge.navigating || bridge.cruising {
                return "驾车导航或巡航正在进行，请先结束再切换出行方式"
            }
            bridge.stopForEngineSwitch()      // 1 失效旧回调（取消会话代次）+ 2 停止导航和相关任务
            bridge.unbindForEngineSwitch()    // 3 解绑 delegate 和数据代表 + 4 释放引用
            guard AMapNaviDriveManager.destroyInstance() else {      // 5 确认销毁成功
                return "驾车引擎没能释放，请重试；多次失败可改用兼容导航"
            }
        case .ride:
            let bridge = RideBridge.shared
            if bridge.navigating {
                return "骑行导航正在进行，请先结束再切换出行方式"
            }
            bridge.stopForEngineSwitch()
            bridge.unbindForEngineSwitch()
            guard AMapNaviRideManager.destroyInstance() else {
                return "骑行引擎没能释放，请重试；多次失败可改用驾车或兼容导航"
            }
        }
        active = .none
        return nil
    }

    /// 第 6 步：创建目标引擎（互斥单例，销毁旧引擎之后才允许碰 sharedInstance）
    private func create(_ engine: Engine) {
        switch engine {
        case .none: break
        case .drive: _ = AMapNaviDriveManager.sharedInstance()
        case .ride: _ = AMapNaviRideManager.sharedInstance()
        }
        if engine != .none { active = engine }
        lastFailure = nil
    }

    // MARK: - 统一状态判断

    /// 任何一种导航正在进行：驾车、官方骑行或独立（网页）导航。
    /// 更换目的地、开始巡航、导入分享等入口都必须先检查这里，防止抢占当前导航。
    var navigationActive: Bool {
        NaviBridge.shared.navigating || RideBridge.shared.navigating || WebMotorSession.shared.running
    }

    /// 只有驾车引擎是当前所有者时才返回实例；否则返回 nil，
    /// 保证迟到回调或地图销毁操作不会重建已被销毁的旧单例。
    func driveManagerIfActive() -> AMapNaviDriveManager? {
        active == .drive ? AMapNaviDriveManager.sharedInstance() : nil
    }

    /// 只有骑行引擎是当前所有者时才返回实例（同上）。
    func rideManagerIfActive() -> AMapNaviRideManager? {
        active == .ride ? AMapNaviRideManager.sharedInstance() : nil
    }

    // MARK: - 驾车导航地图视图的数据代表（NaviScreen 的 AMapNaviDriveView）

    /// 绑定地图视图：驾车引擎必须是当前所有者（NaviScreen 只在驾车导航中出现）
    func attachDriveMap(_ view: AMapNaviDriveView) {
        guard let m = driveManagerIfActive() else { return }
        m.addDataRepresentative(view)
    }

    /// 解绑地图视图：地图销毁时引擎可能已被切换销毁，绝不能为了解绑而重建旧单例
    func detachDriveMap(_ view: AMapNaviDriveView) {
        guard let m = driveManagerIfActive() else { return }
        m.removeDataRepresentative(view)
    }

    // MARK: - 官方骑行导航地图视图的数据代表（RideNaviScreen 的 AMapNaviRideView）

    /// 绑定骑行地图视图：骑行引擎必须是当前所有者（与驾车地图同一套属主门禁）
    func attachRideMap(_ view: AMapNaviRideView) {
        guard let m = rideManagerIfActive() else { return }
        m.addDataRepresentative(view)
    }

    /// 解绑骑行地图视图：地图销毁时引擎可能已被切换销毁，不得重建旧单例
    func detachRideMap(_ view: AMapNaviRideView) {
        guard let m = rideManagerIfActive() else { return }
        m.removeDataRepresentative(view)
    }
}
