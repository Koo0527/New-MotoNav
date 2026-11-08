import Foundation

/// 圆屏底图图源策略（纯逻辑，供 Settings、MapFeeder 和宿主回归共用）。
///
/// 只控制圆屏底图与地图预下载；算路、路线线条、定位、转向和车道提示
/// 始终由原导航链路提供。卫星图(10)和龙珠雷达(11)仍走各自现有路径。
enum MapSourceMode {
    static let amap = 3
    static let vector = 4

    /// 普通主题 1-9：巡航用 OpenFreeMap，导航用高德；其他主题保持高德图源。
    static func source(theme: Int, navigating: Bool) -> Int {
        (1...9).contains(theme) && !navigating ? vector : amap
    }
}
