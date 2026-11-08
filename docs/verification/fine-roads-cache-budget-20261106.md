# 宽图缓存后继续补路与 ACK 后增强包预算修复（2026-11-06）

本报告只覆盖独立验收发现的两条路径；巡航普通主题仍用 OpenFreeMap，导航底图仍用高德，2 米网格、包上限、BLE 协议、固件兼容和用户缓存身份不变。

## 技能

- 修改前调用 `swift-concurrency-pro`：检查 `MapFeeder` 取图 worker→主线程回调、取消、ACK 顺序；回调只携带不可变结果。
- 交付前调用 `verification-before-completion`：以本轮测试和构建的实际退出结果为准。
- 未调用 `esp32-test-plan` / `esp32-ble-gatt`：本轮没有设备/串口操作；真机验收 agent 负责。

## 一、宽图缓存命中后继续补路

新增 `triggerFineForDisplay(f, node)`：

- 只在 AMap 导航、主题 1–3、前台可取图、建筑关闭、车速 <60、`handoff.pending == nil` 且当前没有取图任务时启动。
- 先检查 `readFine` 和 `fineAttempted`：已有增强缓存或本块已尝试则不启动；只有实际进入 `fetchChunk(.display)` 才由 `fetchChunk` 记录尝试。
- `onLocation` 在 `useCachedMap` 成功交付缓存宽图后调用该 helper；`covering` 附近缓存命中路径也调用。
- `prepareRoute.onReady` 在预取宽图后来成为当前显示块时调用该 helper。
- `fetchChunk(.display)` 读到宽图缓存时不会因“当前块已可用”提前返回；它把宽图作为 `preparedBase`，只拍一次近景。
- `useCachedMap` 和 `fetchChunk` 缓存路径识别 `readFine`：已有增强包作为首包可以直接交付；同块宽图已交付后再次读到增强包时，以 `fineRoads: true` 进入统一准入，而不是普通无预算发送。
- 冷缓存仍先宽图再近景；近景失败/取消保留宽图；沿线预下载和 `.prepare` 仍只取宽图。

## 二、两种 ACK 顺序共用一套准入

- `acceptChunk` 顶部对所有 `fineRoads: true` 的包统一处理：宽图未上屏/不同块只落缓存；同块则写入 `deferredFine`（含 `chunkId`、`requestSerial`、`fineEpoch`）。
- 宽图未 ACK：等待。
- 宽图已 ACK：立即调用同一个 `flushFineRoads`，不再落入普通发送分支。
- `flushFineRoads` 通过检查后调用 `acceptChunk(..., fineRoads: false)`，交给普通发送逻辑，避免再次进入增强包暂存分支。
- 准入检查：会话/主题/图源/块、宽图 ACK、`handoff.pending == nil`、`BleLink.isReady`、无 bulk pending、包 valid/content/style、剩余覆盖时间；`roofsFit` 的 `nextBaseBytes` 使用当前宽图 `chunkRoadBytes`。
- 预算不足/前方道路忙：本次等待项消费，宽图和 fine 缓存保留；重复 ACK 不二次发送。
- 路线替换、换区、切主题/图源、会话结束：清空等待项并递增 `fineEpoch`；旧宽图 ACK 不触发旧增强包。

## 三、回归与红绿

### 新增验收场景（`ios/tests/map-source-mode/main.swift`）

1. **预存宽图 + 生产 `onLocation` 沿路线进入低速导航**：
   - 首包等于缓存宽图；
   - 恰好发起一次近景请求；
   - `preparedBase` 等于缓存宽图；
   - 连续第二次 `onLocation` 不再取图。
2. **宽图先 ACK、增强后到、链路 1 B/s**：
   - 增强包未发送，记录 `fine-budget-deferred`；
   - 预算恢复后发送一次。
3. 保留并复跑：增强先到/宽图 ACK 后、两档预算、前方道路抢占、重算旧 ACK、冷缓存、已有增强缓存、建筑开启跳过、`.prepare` 跳过。

### 红绿

- 仅禁用 `triggerFineForDisplay` 的旧副本失败：
  `Fatal error: cached wide display should request fine roads`
- 仅恢复“ACK 后增强包落入普通发送”的旧副本失败：
  `Fatal error: fine after ACK must respect a 1 B/s budget`
- 当前实现通过：
  `PASS map source mode, cache isolation, stale callback and fine ACK staging`

### 其他回归

| 检查 | 结果 |
| --- | --- |
| `map-source-mode/run.py` | PASS |
| `fine-roads/run.py` + `cache.py` | PASS |
| `screenoff-maps/run.py` | PASS 96 |
| `vector-feeder/run.py` | PASS 15 |
| `reroute-recovery/run.py` | PASS 1301 |
| `map-delivery` | PASS |
| `map-smoothing/check.py` | PASS |
| `maps` | 689 checks passed |
| `four-styles` | PASS |
| `vector-map/check.py` | PASS 27/27 |

## 四、构建

`xcodebuild -scheme MotoNav -configuration Release -sdk iphoneos -derivedDataPath ... CODE_SIGNING_ALLOWED=NO` 退出 **65**，仍卡在既有 SwiftUI 文件：

```
RideMapViews.swift:160:
SwiftUIMacros.StateMacro ... swift-plugin-server produced malformed response
```

本轮 `MapFeeder.swift`、`RouteMapPlan.swift` 等已进入 Release `SwiftCompile`，无本轮地图文件错误；未生成 IPA，不能声称构建成功。日志：`output/map-edge-bridge/fine-roads-20261106/release-build.log`。

## 五、性能与待验证

宿主同场景增量仍约 **7.11 ms**、峰值 RSS 约 **+3.0 MB**；两次发送有效载荷 **118,691 B**（58,597 + 60,094）。手机 CPU/峰值内存、圆屏绘制、宽图与增强包各自 ACK、实际累计字节未测，10% 目标未证明。

真机待验收：锁屏巡航跨入未缓存区域、导航命中宽图后细路上屏、重算后的地图交接、连续定位不重复补图。
