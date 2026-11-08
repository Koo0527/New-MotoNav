# 道路分色 App pipeline / cache / BLE 回归（2026-11-03）

本记录覆盖生产 `AmapSdkRaster`、`RouteMapCache`、`RouteOfflineMaps`、`MapFeeder` 和能力协商接线；不代表手机/圆屏实测。

- 仅高德 source 3、游戏主题 1/2/3 生成 RoadPalette；其他主题沿用原处理。
- `materials-v3` / `fast4m-v3` 写入新包；v2 materials、旧 styles、fast4m v1/v2 完整包只读回退。普通 store 拒绝将旧格式写成当前处理结果。v2 掩码经过尺寸、二值内容、checksum 校验直接复用；v1 掩码沿用既有 clean 升级流程。
- `buildingUpdate(currentOnly: true)` 用于处理进度。最终复审修正后，同位置当前代 base／partial 优先于旧代 full；没有当前代时，旧完整包继续作回退。旧完整包不能让新处理任务结束。新代完整空建筑包仍可完成。
- 当前区域原地刷新、普通无建筑模式版本刷新、沿线路线同节点回调均可接入新包。跨代建筑包先发送当前代紧凑道路底图，ACK 后再补屋顶；固件按现有规则延续可用旧屋顶，8／9／10 受保护。旧代迟到回调不能覆盖当前代。
- `roadPaletteSupported` 在连接失败、断开、attach、蓝牙不可用、isReady 失效和主动断开时清零。MPAL 沿用原 BLD 的恢复认证证据规则，只有处理已认证通知后开启能力。
- 发送统一走 `RoadPalette.forWire`。能力缺失时转换为真正旧格式，8/9/10 不暴露给旧端；迟到能力等待 bulk/地图 receipt 结束，按新的 ID 重发当前包，实际 wire 不变则不重发。
- 不清缓存、不新增后台轮询；512 MB 配额、锁屏 cache-only、道路优先、首批/尾批 ACK、覆盖率单调保护保留。

## 已运行

1. `python3 ios/tests/screenoff-maps/run.py`：PASS，生产 feeder/cache/route 69 checks；附带 map-delivery 回归全部通过。新增同位置旧完整包升级、新旧处理进度区分、无建筑模式只刷新一次、旧文件字节不变、高速等待建筑时不重复调度已刷新 base、旧 full 遵守已有建筑重试冷却、MPAL 首批/尾批 ACK 后重发、重复能力不重发。保留 unchanged position/rate 下已准入建筑传输不立即撤回、真正失去窗口时撤回的生产回归。
2. `python3 ios/tests/building-capture/check.py`：PASS。真实 AmapSdkRaster 配确定性截图边界；旧 full 不结束新处理；v2 四片 mask 复用时仅新截一次 1200 底图、零次 600 近景；旧 preparedBase 拒用；伪装 v3 的旧完整包不能阻塞新 partial 存储；首次/完整回调、空建筑完成、取消、失败恢复、yield、串行 lease 保留。
3. `python3 ios/tests/building-offline/check.py`：PASS，生产离线调度、渐进完成、暂停恢复、样式复用、迟到回调及前台优先。
4. `python3 ios/tests/building-delivery/check.py`：PASS，含生产 acceptChunk 慢链路回归。
5. `swiftc -module-cache-path /private/tmp/motonav-pipeline-modules ios/MotoNav/MapGeo.swift ios/MotoNav/RasterProcessing.swift ios/MotoNav/RoadPalette.swift ios/MotoNav/RouteMapPlan.swift ios/tests/building-progress/main.swift -o /private/tmp/motonav-building-progress && /private/tmp/motonav-building-progress`：PASS，含 checksum 损坏、配额、坐标、跨主题共享及 coverage 单调性。
6. `swiftc -module-cache-path /private/tmp/motonav-pipeline-modules ios/MotoNav/BleHandshakeClock.swift ios/MotoNav/BleCapabilityProbe.swift ios/tests/ble-capability/main.swift -o /private/tmp/motonav-capability && /private/tmp/motonav-capability`：PASS，20 checks。

测试使用真实生产处理/调度/缓存代码，替身仅位于 SDK、UIKit、BLE IO 等环境边界。Swift 回归保留原有闭包 weak capture 编译 warning；不是新增编译错误。相关修改文件的 `git diff --check` 通过。

## 边界

未做本分工的版本递增、完整 Xcode 构建、手机安装、固件刷写、真机 CPU/内存/ACK/圆屏耗时测量；由主任务统一验证。离线截图和模拟 BLE 成功不能替代这些测量。
