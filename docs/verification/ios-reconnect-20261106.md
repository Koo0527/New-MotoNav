# iOS 重连底图能力协商修复 — 2026-11-06

## 范围

修复圆屏重连后手机在 MPAL 能力确定前以 `paletteVersion=0` 提交底图的问题，并给同一底图的全量重发设一次上限。沿用现有 BLE 帧格式、旧固件 v0 兼容和 6 秒 `NO DATA` 门槛；不改变路线、位置、转向的既有优先级。

## 实现

`ios/MotoNav/BleLink.swift`

- `onLinkReady` 不再调用 `MapFeeder.resendAll()`，改调 `MapFeeder.onLinkReady()`；认证回执改调 `onAuthenticated()`。
- 解析 `N,3,id`：清理地图回执/计时器并通知 `MapFeeder.onReject`。
- 地图回执最终超时时通知 `MapFeeder.onReceiptTimeout`。
- 能力通知仍只提升 `roadPaletteVersion` 并调用 `onRoadPaletteCapability`。

`ios/MotoNav/MapFeeder.swift`

- 新增 `reconnectMapPending` / `reconnectMapAt`：重连后先保留当前底图；认证后等 1 秒能力协商，到期按当前最高能力发送；无 MPAL 的旧固件走 v0。
- `sendChunk()` 在能力窗口内不提交底图；窗口内的新块只保留最新负载。
- `onRoadPaletteCapability()`：窗口内收到 v2 立即发送；窗口外若格式确实变化，保留在途 ATT 回调槽，取消旧地图分片/回执等待，换新 ID 重发一次；重复能力不重发。
- `mapRetryUsed`：`checkResend`、`N,3,id` 和最终回执超时共用同一预算；同一底图最多完整重试一次，连续定位不会重开预算；新块/新连接/显式 `resendAll` 重置。
- 建筑包在途或 `bulkPending` 时仍走原有 `flushPaletteCapability` 等待路径，不打断首个建筑包。

## 红灯与宿主回归

| 测试 | 结果 |
| --- | --- |
| `python3 ios/tests/ble-palette-lifecycle/run.py`（修复前） | FAIL：`auth must not resend the map before capability settles` |
| `python3 ios/tests/ble-palette-lifecycle/run.py`（修复后） | PASS：首个 `CAP,MPAL,2` 认证不提前重发；K/N 解析与生命周期重置 |
| `python3 ios/tests/map-source-mode/run.py` | PASS：新增 17（窗口内不发、v2 到达发一次、重复不重发）、17b（1 秒后旧固件 v0）、18（迟到 v2 换新 ID/取消旧包/只重发一次）、19（N/超时共用一次预算） |
| `python3 ios/tests/screenoff-maps/run.py` | PASS：96 checks 等 5 组，含建筑包在途不被能力取消 |
| `swiftc ios/MotoNav/BleBulkWriteQueue.swift ios/MotoNav/BleWritePacer.swift ios/tests/ble-bulk/main.swift` | PASS 27 checks |
| `python3 ios/tests/reroute-recovery/run.py` | 未在本轮改动路径上，未复跑 |

## 未完成

- 未做真机组合验收；需等设备恢复后先完成 CPU0 诊断/固件候选，再用同一 Build 28 测试受控重连。
- 未提交为独立 commit：`MapFeeder.swift` / `BleLink.swift` 与当前地图 WIP 交织，且测试运行器依赖未提交的 `screenoff-maps/Stubs.swift`；代码保留在共享工作树，等待与地图分支一起整理。

## 关键文件

- `ios/MotoNav/BleLink.swift`
- `ios/MotoNav/MapFeeder.swift`
- `ios/tests/ble-palette-lifecycle/run.py`
- `ios/tests/map-source-mode/main.swift`、`run.py`
