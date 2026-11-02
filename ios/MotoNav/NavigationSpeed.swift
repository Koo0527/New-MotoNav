import Foundation

/// 模拟导航速度策略：按出行方式管理档位、默认值、非法值回退和循环调速。
/// 自行车 10 / 20 / 30 km/h（默认 20）；驾车、摩托车 60 / 100 / 120 km/h（默认 60）。
/// 开始模拟和途中循环调速都走这里，保证界面速度、SDK 设置和兼容导航的推进速度一致。
/// 以「是否自行车」而非具体出行方式作键：驾车与摩托车共用机动车档位，
/// 官方骑行、兼容骑行和分享导入的自行车路线统一传 `bicycle: true`。
enum NavigationSpeed {
    /// 机动车档位（驾车、摩托车共用，均在 SDK 驾车模拟速度范围内）
    static let motorValues = [60, 100, 120]
    static let motorDefault = 60
    /// 自行车档位（低速模拟骑行；SDK 骑行模拟速度范围 [10,120]）
    static let bicycleValues = [10, 20, 30]
    static let bicycleDefault = 20

    static func values(bicycle: Bool) -> [Int] { bicycle ? bicycleValues : motorValues }
    static func defaultSpeed(bicycle: Bool) -> Int { bicycle ? bicycleDefault : motorDefault }

    /// 非法值（不在该方式档位里）回退到默认档，例如机动车档不用于自行车
    static func normalized(_ value: Int, bicycle: Bool) -> Int {
        values(bicycle: bicycle).contains(value) ? value : defaultSpeed(bicycle: bicycle)
    }

    /// 循环调速：自行车 10 → 20 → 30 → 10，机动车 60 → 100 → 120 → 60。
    /// 非法值先回退到默认档再循环（next(x) 恒等于 next(normalized(x))）。
    static func next(_ value: Int, bicycle: Bool) -> Int {
        let gears = values(bicycle: bicycle)
        let index = gears.firstIndex(of: normalized(value, bicycle: bicycle)) ?? 0
        return gears[(index + 1) % gears.count]
    }
}
