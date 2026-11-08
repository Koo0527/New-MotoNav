# 缓存类型交付与当前块补路复评（2026-11-06）

本轮只修两条路径；巡航普通主题仍用 OpenFreeMap，导航底图仍用高德，2 米网格、包上限、BLE 协议、固件兼容和用户缓存不变。

## 技能

- 修改前 `swift-concurrency-pro`：检查 `MapFeeder` 取图 worker→主线程回调、取消、ACK 时序。
- 交付前 `verification-before-completion`：以实际测试和构建退出结果为准。
- 未调用 `esp32-test-plan` / `esp32-ble-gatt`：本轮没有设备/串口操作；真机验收 agent 另行调用。

## 一、缓存增强包统一经过交付检查

`RouteMapCache` 新增：

```swift
struct CachedPacket { let bytes: Data; let isFine: Bool }
func readPacket(...) -> CachedPacket?   // 复用原查找顺序和文件校验
func readWide(...) -> Data?             // 明确只读宽图，不返回 fine 文件
```

- `read` 保留为 `readPacket(...).bytes` 的兼容包装，既有测试不变。
- `readPacket` 先 fine 版本、再普通/旧材料版本；文件大小、包校验、风格、当前代次、内容检查与原来一致。
- `readWide` 只读当前普通宽图，供 `AmapSdkRaster.preparedBase` 使用，防止把增强包当宽图。
- 传类型的位置：
  - `MapFeeder.useCachedMap`：按 `packet.isFine` 决定是否走增强准入。
  - `MapFeeder.fetchChunk` 缓存回退：按 `cachedPacket.isFine` 决定首包/增强。
  - `MapFeeder.onLocation` 的 `covering` 附近缓存：`Hit.isFine`。
  - `RouteOfflineMaps.readPacket`：沿线 `onReady` 使用同一个 `CachedPacket`。
  - `MapFeeder.triggerFineForDisplay`：用 `readPacket` 判断已有缓存类型，不再单独 `readFine` + 比较字节。
- 已有 fine 缓存可作为新块首包；同块宽图已交付时，缓存增强包和新生成增强包都写入 `deferredFine`，宽图未 ACK 等待、已 ACK 立即 `flushFineRoads`。
- `fineSubmitted` 记录同块/同一宽图传输 ID 的提交；预算拒绝或前方道路忙后不因每次定位反复提交。宽图/路线/会话变化时清空。
- 保留 `chunkId`、`requestSerial`、`fineEpoch` 检查；`flushFineRoads` 通过后以 `fineRoads:false` 走普通发送，避免二次暂存。
- 预算使用当前 `chunkRoadBytes` 为下一块道路预留；前端道路 `handoff.pending` 优先。

## 二、当前块稳定后重新评估补路

`onLocation` 末尾新增 `evaluateFineForCurrentBlock(f, displayNode:)`，独立于 `needsMap` 和 `servedCache`：

- 要求 `haveChunk`、当前块为 RASTER、主题/图源匹配、当前包有效、仍覆盖视野；
- 有显示节点时必须与当前块中心一致，避免把预取目标当当前块；
- `triggerFineForDisplay` 再检查 AMap 导航主题 1–3、前台、建筑关闭、<60 km/h、`handoff.pending == nil`、`!fetching`；
- 锁屏或前方道路忙时直接返回，不消耗 `fineAttempted`；恢复前台/前方道路让出/预取块成为当前块后，下一次定位重新评估；
- 当前块已有 fine 缓存时尝试一次准入（`fineSubmitted` 去重）；只有宽图时把宽图作为 `preparedBase`，实际启动才记 `fineAttempted`，每块每会话最多一次近景；
- 冷缓存仍先宽图再近景；失败/取消保留宽图；`.prepare`/沿线预下载只取宽图。

## 三、回归与红绿

新增/更新 `ios/tests/map-source-mode/main.swift`：

| 场景 | 结果 |
| --- | --- |
| 锁屏复用宽图、解锁仍在同块 | 锁屏零截图；前台连续定位只触发一次近景，复用宽图 |
| 预存宽图 + 生产 `onLocation` 路线 | 首包缓存宽图；恰好一次近景；`preparedBase` 为缓存宽图；重复定位不再取图 |
| 沿线 `RouteOfflineMaps.readPacket` | 读到 fine 文件时 `isFine == true`，onReady 可走同一准入 |
| 宽图先 ACK、增强后到、1 B/s | 增强零发送，记录 `fine-budget-deferred` |
| 独立预算充足场景 | 恰好发送一次 |
| 增强先到/宽图 ACK 后 | 原有两档预算通过 |
| 前方道路、重算旧 ACK、模式切换 | 不发送过期增强包 |
| 冷缓存、已有 fine 缓存、建筑开启、`.prepare` | 符合预期 |

红绿：

- 旧缓存补路副本失败：`Fatal error: cached wide display should request fine roads`
- 旧 ACK 后预算副本失败：`Fatal error: fine after ACK must respect a 1 B/s budget`
- 当前实现：`PASS map source mode, cache isolation, stale callback and fine ACK staging`

其他回归：

| 检查 | 结果 |
| --- | --- |
| `fine-roads/run.py` + `cache.py` | PASS |
| `screenoff-maps/run.py` | PASS 96 |
| `vector-feeder/run.py` | PASS 15 |
| `reroute-recovery/run.py` | PASS 1301 |
| `map-delivery` | PASS |
| `maps` | 689 checks passed |
| `map-smoothing/check.py` | PASS |
| `four-styles` | PASS |
| `vector-map/check.py` | PASS 27/27 |

## 四、构建

`xcodebuild -scheme MotoNav -configuration Release -sdk iphoneos -derivedDataPath ... CODE_SIGNING_ALLOWED=NO` 退出 **65**，仍是既有 SwiftUI 文件：

```
RideMapViews.swift:160:
SwiftUIMacros.StateMacro ... swift-plugin-server produced malformed response
```

`MapFeeder.swift` 等本轮地图文件已进入 `SwiftCompile`，无本轮地图文件错误；未生成 IPA，不能声称构建成功。日志：`output/map-edge-bridge/fine-roads-20261106/release-build.log`。

## 五、性能与待验证

宿主同场景增量约 **7.11 ms**、峰值 RSS 约 **+3.0 MB**；两次发送有效载荷 **118,691 B**。手机 CPU/峰值内存、圆屏绘制、宽图/增强包各自 ACK、实际累计字节未测，10% 目标未证明。

真机待验收：锁屏巡航跨入未缓存区域、导航命中宽图后细路上屏、预取块成为当前块、重算后的地图交接，以及连续定位不重复补图。
